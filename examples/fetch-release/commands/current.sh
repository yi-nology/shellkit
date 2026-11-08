#!/usr/bin/env bash
# cmd_current —— 只把版本号写到 stdout。
#
# 所以 v=$(fetch-release current) 拿到的是 1.1.0，不是带时间戳的一行日志。

cmd_current() {
  local __root=${RELEASE_ROOT:-/opt/fetch-release} __target

  if [ ! -L "$__root/current" ]; then
    printf 'none\n'
    return 1
  fi

  __target=$(readlink "$__root/current" 2>/dev/null || true)
  printf '%s\n' "${__target##*/}"
  return "$SK_OK"
}
