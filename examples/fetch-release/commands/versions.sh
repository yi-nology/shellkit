#!/usr/bin/env bash
# cmd_versions —— 列出本地已经下载过的版本。
#
# 列表来自目录而不是配置项：状态只在文件系统里存一份，就不会出现「配置说装了、
# 文件其实不在」这种两边不一致的情况。

cmd_versions() {
  local __root=${RELEASE_ROOT:-/opt/fetch-release} __d __any=0

  for __d in "$__root"/versions/*; do
    [ -d "$__d" ] || continue
    printf '%s\n' "${__d##*/}"
    __any=1
  done

  [ "$__any" -eq 1 ] || return 1
  return "$SK_OK"
}
