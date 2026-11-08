#!/usr/bin/env bash
# cmd_fetch —— 下载、校验、原子切换。
#
# 三件事都不是自己写的：net_download 负责下载与校验（已有且校验通过就跳过），
# retry 负责网络抖动，fs_ensure_symlink 负责切换。这个脚本只决定顺序和落点。
#
# 为什么切换用符号链接而不是覆盖文件：链接的替换是 rename，任何时刻读者看到的
# 要么是旧版本要么是新版本，不存在「读到半个」的窗口；而且旧版本还躺在那儿，
# 回滚就是再指一次。

# cmd_fetch [--refresh] VERSION
cmd_fetch() {
  local __refresh="" __version __base __root __sums __want

  cli_opt_init
  cli_opt __refresh --refresh -r
  cli_opts "$@" || return $?
  __version="${SK_OPTS_LEFT[0]:-}"

  __base=${RELEASE_BASE:-https://downloads.example.invalid/releases}
  __root=${RELEASE_ROOT:-/opt/fetch-release}

  if [ -z "$__version" ]; then
    log_error "missing version"
    cli_usage_cmd fetch
    return "$SK_USAGE"
  fi
  if ! validate_version "$__version"; then
    log_error "$SK_VALIDATE_ERR"
    return "$SK_USAGE"
  fi

  # 同时只允许一个实例动 current；拿到即进清理栈，异常退出也会释放
  lock_acquire fetch-release 10 || return $?

  __sums="$__root/SHA256SUMS"
  if [ "$__refresh" = "1" ] && [ -f "$__sums" ]; then
    rm -f "$__sums"
  fi

  # 清单本身没有摘要可校 —— 真实产品在这里用签名过的清单或固定的公钥验。
  net_download "$__base/SHA256SUMS" "$__sums" || return $?

  __want=$(_sum_for "$__sums" "payload-$__version.txt")
  if [ -z "$__want" ]; then
    log_error "version $__version is not listed in SHA256SUMS"
    return "$SK_VERIFY"
  fi

  # 校验失败是 5，retry 不会重试它 —— 重试只会白费带宽，然后拿到同一个坏文件。
  retry 3 net_download "$__base/payload-$__version.txt" \
    "$__root/versions/$__version/payload" "$__want" || return $?

  fs_ensure_symlink "versions/$__version" "$__root/current" || return $?
  log_ok "active version: $__version"
  return "$SK_OK"
}

# _sum_for SHA256SUMS FILENAME —— 取出某个文件的摘要。格式同 sha256sum -c 的输入：
#   <64 位十六进制><两个空格><文件名>
_sum_for() {
  local __file=${1:-} __name=${2:-} __h __n
  while read -r __h __n; do
    __n=${__n#\*}
    if [ "$__n" = "$__name" ]; then
      printf '%s\n' "$__h"
      return 0
    fi
  done <"$__file"
  return 1
}
