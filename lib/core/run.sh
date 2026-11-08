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
