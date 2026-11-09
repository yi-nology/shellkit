#!/usr/bin/env bash
#
# 命令包装。补 set -e 的盲区：-e 在 if / || / 子 shell 里不生效，
# 而这些位置恰恰是最容易忘记检查的地方。
#
#   run cp "$src" "$dst"                    # 失败即退出，退出码沿用命令自身
#   if run --no-die systemctl restart f; then ... fi
#   run --no-die cmd || notify-failure      # 失败只返回码，不退出
#
# 注意：默认的 run 失败时调 die，而 die 里的 exit 在 if / || 里照样退出整个 shell。
# 想在 if / || 里判断成败，必须加 --no-die —— 这条以前只写在注释里，实际做不到。
#
# SHELLKIT_DRY_RUN=1 时只打印不执行；run --always 可绕过。

# _sk_run_quote ARG... —— 按参数边界引号化，dry-run 打印出来的东西可以直接粘回去跑
_sk_run_quote() {
  local __out="" __sep="" __a
  for __a in "$@"; do
    __out="$__out$__sep$(_sk_shell_quote "$__a")"
    __sep=" "
  done
  printf '%s' "$__out"
}

# run [--always] [--no-die] CMD... —— 执行命令，失败即 die；--no-die 只返回码
run() {
  local __always=0 __die=1 __rc=0 __shown
  while :; do
    case "${1:-}" in
      --always)
        __always=1
        shift
        ;;
      --no-die)
        __die=0
        shift
        ;;
      *) break ;;
    esac
  done
  if [ "$#" -eq 0 ]; then
    log_error "$(_t 'run requires a command')"
    return "$SK_USAGE"
  fi
  __shown="$(_sk_run_quote "$@")"
  if [ "$__always" -eq 0 ] && [ "${SHELLKIT_DRY_RUN:-0}" = "1" ]; then
    printf '[dry-run] %s\n' "$__shown" >&2
    return 0
  fi
  "$@" || __rc=$?
  if [ "$__rc" -ne 0 ]; then
    if [ "$__die" -eq 1 ]; then
      die "$__rc" "$(_t 'command failed'): $__shown (exit $__rc)"
    fi
    log_error "$(_t 'command failed'): $__shown (exit $__rc)"
    return "$__rc"
  fi
  return 0
}

# run_concurrent N [--timeout SEC] -- CMD... —— 把同一条命令并发跑 N 份
#
# 典型用法：对一批目标跑同一个动作（每个实例自己从环境变量读目标）。
#
#   run_concurrent 8 -- ./deploy.sh "$target"
#
# 输出约定（stdout 只给数据）：
#   stdout —— 成功实例的数量，一个整数，便于直接 $(...) 取走
#   stderr —— 每个实例的 stdout/stderr，逐行带 [i/N] 前缀；失败明细也在这里
#
# 返回码：全部成功返回 0；有实例失败则返回第一个失败实例的退出码。
# 注意：这里不用 die —— die 的 exit 在 if / || 里会退出整个 shell。
run_concurrent() {
  if [ "$#" -eq 0 ]; then
    log_error "$(_t 'usage: run_concurrent N [--timeout SEC] -- COMMAND...')"
    return "$SK_USAGE"
  fi
  local __n=$1
  shift
  case "$__n" in
    '' | *[!0-9]*)
      log_error "$(_t 'invalid concurrency'): $__n"
      return "$SK_USAGE"
      ;;
  esac
  if [ "$__n" -lt 1 ]; then
    log_error "$(_t 'invalid concurrency'): $__n"
    return "$SK_USAGE"
  fi

  local __timeout=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --timeout)
        shift
        if [ "$#" -eq 0 ]; then
          log_error "$(_t 'option requires a value'): --timeout"
          return "$SK_USAGE"
        fi
        __timeout=$1
        ;;
      --timeout=*)
        __timeout="${1#*=}"
        ;;
      --)
        shift
        break
        ;;
      -?*)
        log_error "$(_t 'unknown option'): $1"
        return "$SK_USAGE"
        ;;
      *)
        break
        ;;
    esac
    shift
  done
  case "$__timeout" in
    '' | *[!0-9]*)
      log_error "$(_t 'invalid timeout'): $__timeout"
      return "$SK_USAGE"
      ;;
  esac
  if [ "$#" -eq 0 ]; then
    log_error "$(_t 'run_concurrent requires a command')"
    return "$SK_USAGE"
  fi

  local __shown
  __shown="$(_sk_run_quote "$@")"
  if [ "${SHELLKIT_DRY_RUN:-0}" = "1" ]; then
    printf '[dry-run] %s (x%s)\n' "$__shown" "$__n" >&2
    return 0
  fi

  local __tmp
  __tmp=$(mktemp -d "${TMPDIR:-/tmp}/shellkit-concurrent.XXXXXX") || {
    log_error "$(_t 'cannot create a temporary directory')"
    return "$SK_ERR"
  }
  # 脚本中途被杀时临时目录也不会留下
  trap_push "rm -rf '${__tmp}'"

  local __timeout_bin=""
  if [ "$__timeout" -gt 0 ]; then
    if command -v timeout >/dev/null 2>&1; then
      __timeout_bin=timeout
    elif command -v gtimeout >/dev/null 2>&1; then
      __timeout_bin=gtimeout
    else
      log_warn "$(_t 'timeout command not found, running without a timeout')"
    fi
  fi

  local __i=1
  local -a __pids=()
  while [ "$__i" -le "$__n" ]; do
    (
      __rc=0
      if [ -n "$__timeout_bin" ]; then
        "$__timeout_bin" "$__timeout" "$@" >"${__tmp}/${__i}.out" 2>"${__tmp}/${__i}.err" || __rc=$?
      else
        "$@" >"${__tmp}/${__i}.out" 2>"${__tmp}/${__i}.err" || __rc=$?
      fi
      printf '%s\n' "$__rc" >"${__tmp}/${__i}.rc"
      exit 0
    ) &
    __pids[${#__pids[@]}]=$!
    __i=$((__i + 1))
  done

  local __p
  for __p in ${__pids[@]+"${__pids[@]}"}; do
    wait "$__p" 2>/dev/null || true
  done

  local __ok=0 __first_fail=0 __rc=0 __line
  __i=1
  while [ "$__i" -le "$__n" ]; do
    __rc=0
    if [ -f "${__tmp}/${__i}.rc" ]; then
      read -r __rc <"${__tmp}/${__i}.rc" || __rc=0
    fi
    if [ "$__rc" -eq 0 ]; then
      __ok=$((__ok + 1))
    elif [ "$__first_fail" -eq 0 ]; then
      __first_fail=$__rc
    fi
    if [ -s "${__tmp}/${__i}.out" ]; then
      while IFS= read -r __line || [ -n "$__line" ]; do
        printf '[%s/%s] %s\n' "$__i" "$__n" "$__line" >&2
      done <"${__tmp}/${__i}.out"
    fi
    if [ -s "${__tmp}/${__i}.err" ]; then
      while IFS= read -r __line || [ -n "$__line" ]; do
        printf '[%s/%s] %s\n' "$__i" "$__n" "$__line" >&2
      done <"${__tmp}/${__i}.err"
    fi
    __i=$((__i + 1))
  done

  rm -rf "${__tmp:?}"

  if [ "$__first_fail" -ne 0 ]; then
    log_error "$(_t 'concurrent instances failed'): $__ok/$__n succeeded, first failure exit $__first_fail"
    return "$__first_fail"
  fi
  printf '%s\n' "$__ok"
  return 0
}
