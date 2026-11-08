#!/usr/bin/env bash
#
# 命令包装。补 set -e 的盲区：-e 在 if / || / 子 shell 里不生效，
# 而这些位置恰恰是最容易忘记检查的地方。
#
#   run cp "$src" "$dst"
#   if run systemctl restart foo; then ... fi
#   cmd || run notify-failure
#
# SHELLKIT_DRY_RUN=1 时只打印不执行；run --always 可绕过。

# run CMD... —— 执行命令，失败即 die（消息含命令原文与退出码）
run() {
  local __always=0 __rc=0
  if [ "${1:-}" = "--always" ]; then
    __always=1
    shift
  fi
  if [ "$#" -eq 0 ]; then
    log_error "$(_t 'run requires a command')"
    return "$SK_USAGE"
  fi
  if [ "$__always" -eq 0 ] && [ "${SHELLKIT_DRY_RUN:-0}" = "1" ]; then
    printf '[dry-run] %s\n' "$*" >&2
    return 0
  fi
  "$@" || __rc=$?
  if [ "$__rc" -ne 0 ]; then
    die "$__rc" "$(_t 'command failed'): $* (exit $__rc)"
  fi
  return 0
}
