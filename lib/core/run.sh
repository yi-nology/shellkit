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

# _sk_run_secret_key KEY —— 这个键名看起来是不是敏感字段
#
# 判断的是「键名」，不是值：值什么样都行，键名像敏感字段就该遮。
# 常见写法：--password、--api-key、API_TOKEN=...、DB_PASSWORD=...
_sk_run_secret_key() {
  local __k=${1:-} __l
  __l=$(printf '%s' "$__k" | tr 'A-Z' 'a-z')
  case "$__l" in
    *password* | *passwd* | *secret* | *token* | *apikey* | *api[_-]key* | \
      *access[_-]key* | *private[_-]key* | *credential* | *authorization*)
      return 0
      ;;
  esac
  return 1
}

# _sk_run_redact_args ARG... —— 打印一条脱敏后的命令行（只给日志用）
#
# 日志里出现完整的命令行，就等于把口令与令牌写进了日志文件 ——
# 而日志常常比代码活得更久、传得更远。遮住三处：
#   KEY=VALUE         键名像敏感字段就把值遮掉（API_TOKEN=***）
#   --password VALUE  选项名像敏感字段就把下一个参数一起遮掉
#   Authorization:…   请求头按头名遮
# 真实执行的命令不受影响 —— 这里只改「打印出来的那一份」。
_sk_run_redact_args() {
  local __out="" __sep="" __a __k __mask_next=0
  for __a in "$@"; do
    if [ "$__mask_next" -eq 1 ]; then
      __mask_next=0
      __a="***"
    else
      __k=""
      case "$__a" in
        *=*) __k=${__a%%=*} ;;
      esac
      if [ -n "$__k" ] && _sk_run_secret_key "$__k"; then
        __a="$__k=***"
      else
        case "$__a" in
          *[Aa]uthorization:*)
            __a="${__a%%:*}: ***"
            ;;
          --*)
            __k=${__a#--}
            __k=${__k%%=*}
            if [ "$__k" != "$__a" ] && _sk_run_secret_key "$__k"; then
              __mask_next=1
            fi
            ;;
        esac
      fi
    fi
    __out="$__out$__sep$(_sk_shell_quote "$__a")"
    __sep=" "
  done
  printf '%s' "$__out"
}

# _sk_run_display ARG... —— 给日志看的那份命令行
#
# 默认脱敏。SHELLKIT_REDACT=0 可以关掉（调试时用）——
# 关掉的这一刻起，口令就会进日志，所以它只能是调试开关，不是配置项。
_sk_run_display() {
  if [ "${SHELLKIT_REDACT:-1}" = "0" ]; then
    _sk_run_quote "$@"
    return 0
  fi
  _sk_run_redact_args "$@"
}

# run [--always] [--no-die] CMD... —— 执行命令，失败即 die；--no-die 只返回码
# @exitcode 0 命令成功
# @exitcode 2 用法错（没给命令）
# @exitcode 其他 命令自身的退出码；默认模式下失败会 die，--no-die 只返回码
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
  __shown="$(_sk_run_display "$@")"
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
# @exitcode 0 全部实例成功（stdout 输出成功实例数）
# @exitcode 2 参数错（并发数不是正整数、超时值非法、没给命令）
# @exitcode 其他 第一个失败实例的退出码
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
  __shown="$(_sk_run_display "$@")"
  if [ "${SHELLKIT_DRY_RUN:-0}" = "1" ]; then
    printf '[dry-run] %s (x%s)\n' "$__shown" "$__n" >&2
    return 0
  fi

  # 主体放进子 shell：临时目录的清理 trap 只装在这个子 shell 里，
  # 调用方的 trap 不受影响 —— trap 模块的规矩是「注册不等于安装」，
  # 库不该趁你调个函数就把你的信号行为接管掉。
  (
    local __tmp __i __p __rc __line __ok=0 __first_fail=0 __w __have
    local -a __pids=() __waits=()
    __tmp=$(mktemp -d "${TMPDIR:-/tmp}/shellkit-concurrent.XXXXXX") || {
      log_error "$(_t 'cannot create a temporary directory')"
      exit "$SK_ERR"
    }
    # 脚本中途被杀时临时目录也不会留下
    trap 'rm -rf "${__tmp:?}"' EXIT INT TERM HUP

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

    __i=1
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

    # wait 的结果要留着：实例被信号打死时状态文件根本写不出来，
    # 只看状态文件会把「被杀死」当成「成功」。
    __i=0
    for __p in ${__pids[@]+"${__pids[@]}"}; do
      __w=0
      wait "$__p" 2>/dev/null || __w=$?
      __waits[$__i]=$__w
      __i=$((__i + 1))
    done

    __ok=0
    __first_fail=0
    __i=1
    while [ "$__i" -le "$__n" ]; do
      __rc=0
      __have=0
      if [ -f "${__tmp}/${__i}.rc" ]; then
        read -r __rc <"${__tmp}/${__i}.rc" || __rc=""
        if [ -n "$__rc" ]; then
          __have=1
        fi
      fi
      if [ "$__have" -eq 0 ]; then
        # 没有状态：实例被信号打死，或还没收尾。按失败算，绝不当成成功。
        __w=${__waits[$((__i - 1))]:-0}
        case "$__w" in
          '' | *[!0-9]*) __w=0 ;;
        esac
        if [ "$__w" -eq 0 ]; then
          __w=125
        fi
        __rc=$__w
        log_warn "$(_t 'an instance produced no exit status'): $__i (exit $__rc)"
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

    if [ "$__first_fail" -ne 0 ]; then
      log_error "$(_t 'concurrent instances failed'): $__ok/$__n succeeded, first failure exit $__first_fail"
      exit "$__first_fail"
    fi
    printf '%s\n' "$__ok"
    exit 0
  )
}

# parallel_map N [--timeout SEC] -- CMD... —— 把一批不同的目标分给 N 个并发实例
#
# 与 run_concurrent 明确区分：
#   run_concurrent —— 同一条命令并发跑 N 份（每个实例自己从环境变量读目标）
#   parallel_map   —— 每个实例跑一条不同的目标，条目从标准输入读
#
# 条目一行一个（空行跳过），每个实例执行的命令是「CMD... 条目」——
# 条目作为最后一个参数追加在后面：
#
#   printf '%s\n' web1 web2 web3 | parallel_map 3 -- ./restart-service
#
# 输出约定（stdout 只给数据）：
#   stdout —— 每行一条结果：<条目>\t<退出码>（条目里有制表符时，取最后一个制表符之后的部分）
#   stderr —— 每个实例的 stdout/stderr，逐行带 [i/N] 前缀；失败明细也在这里
#
# 返回码：全部成功返回 0；有条目失败则返回第一个失败条目的退出码。
#
# 并发是「按批」的：一批最多 N 个，跑完这一批再下一批。这样不需要锁，
# 也不会有两个实例抢同一条目；代价是一批里最慢的那个会拖住整批。
# @exitcode 0 全部条目成功（stdout 输出每个条目的结果）
# @exitcode 2 参数错（并发数不是正整数、超时值非法、没给命令）
# @exitcode 其他 第一个失败条目的退出码
parallel_map() {
  if [ "$#" -eq 0 ]; then
    log_error "$(_t 'usage: parallel_map N [--timeout SEC] -- COMMAND...')"
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
        __timeout="${1#--timeout=}"
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
    log_error "$(_t 'parallel_map requires a command')"
    return "$SK_USAGE"
  fi

  local __shown
  __shown="$(_sk_run_display "$@")"
  if [ "${SHELLKIT_DRY_RUN:-0}" = "1" ]; then
    printf '[dry-run] %s (x%s)\n' "$__shown" "$__n" >&2
    return 0
  fi

  # 与 run_concurrent 一样：主体放进子 shell，清理用的 trap 不出子 shell。
  (
    local __tmp __line __i __p __rc __w __have __item __total=0 __batch=0 __batch_n=0
    local __first_fail=0 __start=1 __timeout_bin=""
    local -a __list=() __pids=() __waits=()
    __tmp=$(mktemp -d "${TMPDIR:-/tmp}/shellkit-parallel.XXXXXX") || {
      log_error "$(_t 'cannot create a temporary directory')"
      exit "$SK_ERR"
    }
    trap 'rm -rf "${__tmp:?}"' EXIT INT TERM HUP

    while IFS= read -r __line || [ -n "$__line" ]; do
      [ -n "$__line" ] || continue
      __list[${#__list[@]}]=$__line
    done
    __total=${#__list[@]}
    if [ "$__total" -eq 0 ]; then
      log_info "$(_t 'no items to process')"
      exit 0
    fi

    if [ "$__timeout" -gt 0 ]; then
      if command -v timeout >/dev/null 2>&1; then
        __timeout_bin=timeout
      elif command -v gtimeout >/dev/null 2>&1; then
        __timeout_bin=gtimeout
      else
        log_warn "$(_t 'timeout command not found, running without a timeout')"
      fi
    fi

    while [ "$__start" -le "$__total" ]; do
      __batch_n=0
      __pids=()
      __waits=()
      while [ "$__batch_n" -lt "$__n" ] && [ "$((__start + __batch_n))" -le "$__total" ]; do
        __item=${__list[$((__start + __batch_n - 1))]}
        (
          __rc=0
          if [ -n "$__timeout_bin" ]; then
            "$__timeout_bin" "$__timeout" "$@" "$__item" >"${__tmp}/${__batch_n}.out" 2>"${__tmp}/${__batch_n}.err" || __rc=$?
          else
            "$@" "$__item" >"${__tmp}/${__batch_n}.out" 2>"${__tmp}/${__batch_n}.err" || __rc=$?
          fi
          printf '%s\n' "$__rc" >"${__tmp}/${__batch_n}.rc"
          exit 0
        ) &
        __pids[${#__pids[@]}]=$!
        __batch_n=$((__batch_n + 1))
      done

      __i=0
      for __p in ${__pids[@]+"${__pids[@]}"}; do
        __w=0
        wait "$__p" 2>/dev/null || __w=$?
        __waits[$__i]=$__w
        __i=$((__i + 1))
      done

      __i=0
      while [ "$__i" -lt "$__batch_n" ]; do
        __item=${__list[$((__start + __i - 1))]}
        __rc=0
        __have=0
        if [ -f "${__tmp}/${__i}.rc" ]; then
          read -r __rc <"${__tmp}/${__i}.rc" || __rc=""
          if [ -n "$__rc" ]; then
            __have=1
          fi
        fi
        if [ "$__have" -eq 0 ]; then
          __w=${__waits[$__i]:-0}
          case "$__w" in
            '' | *[!0-9]*) __w=0 ;;
          esac
          if [ "$__w" -eq 0 ]; then
            __w=125
          fi
          __rc=$__w
          log_warn "$(_t 'an instance produced no exit status'): $__item (exit $__rc)"
        fi
        printf '%s\t%s\n' "$__item" "$__rc"
        if [ "$__rc" -ne 0 ] && [ "$__first_fail" -eq 0 ]; then
          __first_fail=$__rc
        fi
        if [ -s "${__tmp}/${__i}.out" ]; then
          while IFS= read -r __line || [ -n "$__line" ]; do
            printf '[%s/%s] %s\n' "$((__start + __i - 1))" "$__total" "$__line" >&2
          done <"${__tmp}/${__i}.out"
        fi
        if [ -s "${__tmp}/${__i}.err" ]; then
          while IFS= read -r __line || [ -n "$__line" ]; do
            printf '[%s/%s] %s\n' "$((__start + __i - 1))" "$__total" "$__line" >&2
          done <"${__tmp}/${__i}.err"
        fi
        __i=$((__i + 1))
      done
      __start=$((__start + __batch_n))
    done

    if [ "$__first_fail" -ne 0 ]; then
      log_error "$(_t 'some items failed'): first failure exit $__first_fail"
      exit "$__first_fail"
    fi
    exit 0
  )
}
