#!/usr/bin/env bash
# 文件系统工具。写入一律原子。

SK_TMPDIR=""

# fs_ensure_dir DIR [MODE]
fs_ensure_dir() {
  local __dir=$1 __mode=${2:-}
  if [ ! -d "$__dir" ]; then
    mkdir -p "$__dir" || return 1
  fi
  if [ -n "$__mode" ]; then
    chmod "$__mode" "$__dir" 2>/dev/null || true
  fi
  return 0
}

# fs_atomic_write FILE CONTENT [MODE]
fs_atomic_write() {
  local __file=$1 __content=$2 __mode=${3:-600} __dir __tmp
  __dir=$(dirname "$__file")
  fs_ensure_dir "$__dir" "" || return 1
  __tmp=$(mktemp "$__file.tmp.XXXXXX") || return 1
  if ! printf '%s' "$__content" >"$__tmp"; then
    rm -f "$__tmp"
    return 1
  fi
  chmod "$__mode" "$__tmp" 2>/dev/null || true
  if ! mv -f "$__tmp" "$__file"; then
    rm -f "$__tmp"
    return 1
  fi
  return 0
}

# fs_backup FILE [KEEP] —— 产出 FILE.bak.YYYYmmddHHMMSS，按名升序保留最新 KEEP 份
fs_backup() {
  local __file=$1 __keep=${2:-3} __stamp __bak __x __i=0 __total
  local -a __list=()
  if [ ! -f "$__file" ]; then
    return 0
  fi
  __stamp=$(date +%Y%m%d%H%M%S)
  __bak="$__file.bak.$__stamp"
  cp -p "$__file" "$__bak" || return 1
  for __x in "$__file".bak.*; do
    if [ -e "$__x" ]; then
      __list[${#__list[@]}]=$__x
    fi
  done
  __total=${#__list[@]}
  if [ "$__total" -gt "$__keep" ]; then
    while [ "$__i" -lt $((__total - __keep)) ]; do
      rm -f "${__list[$__i]}"
      __i=$((__i + 1))
    done
  fi
  return 0
}

_sk_tmp_cleanup() {
  if [ -n "${SK_TMPDIR:-}" ] && [ -d "$SK_TMPDIR" ] && [ "${SHELLKIT_TMP_KEEP:-0}" != "1" ]; then
    rm -rf "$SK_TMPDIR"
  fi
  return 0
}

_sk_tmp_base() {
  local __base=${TMPDIR:-/tmp}
  printf '%s\n' "${__base%/}"
}

# fs_tmpdir —— 确保临时目录存在并输出路径。
# 目录名按 UID+进程号确定，因此同一进程内的 $(...) 子 shell 拿到的是同一个目录；
# 它不注册 trap，外部有 EXIT 需求请用 fs_tmp_init。
fs_tmpdir() {
  local __base __dir
  if [ -n "${SK_TMPDIR:-}" ] && [ -d "$SK_TMPDIR" ]; then
    printf '%s\n' "$SK_TMPDIR"
    return 0
  fi
  __base=$(_sk_tmp_base)
  __dir="$__base/shellkit-${UID:-0}-$$"
  if [ -L "$__dir" ]; then
    log_error "$(_t 'refusing to use a symlinked temporary directory'): $__dir"
    return "$SK_ERR"
  fi
  if [ ! -d "$__dir" ]; then
    (umask 077 && mkdir -p "$__dir") || return 1
  fi
  SK_TMPDIR=$__dir
  export SK_TMPDIR
  printf '%s\n' "$SK_TMPDIR"
}

# fs_tmp_init —— 在当前 shell 初始化临时目录并注册 EXIT 清理。
# 只在入口脚本里调用；调用方已有 EXIT trap 时不覆盖，只提示。
fs_tmp_init() {
  if ! fs_tmpdir >/dev/null; then
    return 1
  fi
  if [ -z "$(trap -p EXIT 2>/dev/null)" ]; then
    trap '_sk_tmp_cleanup' EXIT
  else
    log_debug "EXIT trap already set; temp dir will not be auto-removed: $SK_TMPDIR"
  fi
  return 0
}
