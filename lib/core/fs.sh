#!/usr/bin/env bash
# 文件系统工具。写入一律原子，幂等操作已正确时零改动。

SK_TMPDIR=""

# fs_ensure_dir DIR [MODE] —— 幂等建目录；给了 MODE 就 chmod
# @exitcode 0 目录已存在或建好
# @exitcode 2 没给参数
# @exitcode 1 mkdir 失败
fs_ensure_dir() {
  local __dir=${1:-} __mode=${2:-}
  _sk_need_args "$#" 1 "fs_ensure_dir DIR [MODE]" || return $?
  if [ ! -d "$__dir" ]; then
    mkdir -p "$__dir" || return 1
  fi
  if [ -n "$__mode" ]; then
    chmod "$__mode" "$__dir" 2>/dev/null || true
  fi
  return 0
}

# fs_atomic_write FILE CONTENT [MODE] —— 原子写文件；默认权限 600，父目录不存在会先建
# @exitcode 0 写成功（临时文件 + mv，原文件权限保留）
# @exitcode 2 没给参数
# @exitcode 1 建目录、落临时文件或改名失败
fs_atomic_write() {
  local __file=${1:-} __content=${2:-} __mode=${3:-600} __dir __tmp
  _sk_need_args "$#" 2 "fs_atomic_write FILE CONTENT [MODE]" || return $?
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
# @exitcode 0 备份成功（或文件本来就不存在）
# @exitcode 2 参数错（保留份数不是正整数）
# @exitcode 1 备份失败
fs_backup() {
  local __file=${1:-} __keep=${2:-3} __stamp __bak __x __i=0 __total __seq=0
  local -a __list=()
  _sk_need_args "$#" 1 "fs_backup FILE [KEEP]" || return $?
  case "$__keep" in
    '' | *[!0-9]*)
      log_error "$(_t 'invalid keep count'): $__keep"
      return "$SK_USAGE"
      ;;
  esac
  if [ ! -f "$__file" ]; then
    return 0
  fi
  __stamp=$(date +%Y%m%d%H%M%S)
  # 名字必须唯一：同一秒里备份两次，第二次会覆盖第一次刚建的备份（等于丢一份）。
  # 加 pid 与序号后缀；前缀仍是定长时间戳，所以「按名升序 == 时间序」的轮转前提不变。
  __bak="$__file.bak.$__stamp.$$"
  while [ -e "$__bak" ]; do
    __seq=$((__seq + 1))
    __bak="$__file.bak.$__stamp.$$-$__seq"
  done
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

# _sk_fs_new_tmp FILE —— 在同目录建临时文件；FILE 存在时连权限一起复制过来
_sk_fs_new_tmp() {
  local __file=$1 __tmp
  __tmp=$(mktemp "$__file.tmp.XXXXXX") || return 1
  if [ -f "$__file" ]; then
    if ! cp -p "$__file" "$__tmp"; then
      rm -f "$__tmp"
      return 1
    fi
  fi
  printf '%s\n' "$__tmp"
  return 0
}

# _sk_fs_has_newline TEXT
_sk_fs_has_newline() {
  if [ "$(printf '%s' "$1" | wc -l)" -ne 0 ]; then
    return 0
  fi
  return 1
}

# fs_ensure_line FILE LINE —— 整行精确匹配；不存在才追加。幂等。
# @exitcode 0 文件已含该行或已写入
# @exitcode 2 参数错（行为空或含换行）
# @exitcode 1 写文件失败
fs_ensure_line() {
  local __file=${1:-} __line=${2:-} __tmp
  _sk_need_args "$#" 1 "fs_ensure_line FILE LINE" || return $?
  if [ -z "$__line" ]; then
    log_error "$(_t 'line must not be empty')"
    return "$SK_USAGE"
  fi
  if _sk_fs_has_newline "$__line"; then
    log_error "$(_t 'line must not contain a newline')"
    return "$SK_USAGE"
  fi
  if [ -f "$__file" ]; then
    # 用 ENVIRON 传值：awk -v 会对赋值做转义（\t -> TAB），含反斜杠的行就再也匹配不上自己
    if WANT=$__line awk '$0 == ENVIRON["WANT"] { found = 1 } END { exit found ? 0 : 1 }' "$__file"; then
      return 0
    fi
  fi
  fs_ensure_dir "$(dirname "$__file")" "" || return 1
  __tmp=$(_sk_fs_new_tmp "$__file") || return 1
  if [ -f "$__file" ] && [ -n "$(tail -c 1 "$__file" 2>/dev/null)" ]; then
    printf '\n' >>"$__tmp" || {
      rm -f "$__tmp"
      return 1
    }
  fi
  printf '%s\n' "$__line" >>"$__tmp" || {
    rm -f "$__tmp"
    return 1
  }
  if ! mv -f "$__tmp" "$__file"; then
    rm -f "$__tmp"
    return 1
  fi
  return 0
}

# fs_ensure_block FILE BEGIN END CONTENT —— 标记块内内容整体替换；没有就追加。幂等。
# @exitcode 0 区块已存在或已写入
# @exitcode 2 参数错（区块标识非法）
# @exitcode 1 写文件失败
fs_ensure_block() {
  local __file=${1:-} __begin=${2:-} __end=${3:-} __content=${4:-}
  local __tmp __cf __src
  _sk_need_args "$#" 3 "fs_ensure_block FILE BEGIN END [CONTENT]" || return $?
  if [ -z "$__begin" ] || [ -z "$__end" ]; then
    log_error "$(_t 'block markers must not be empty')"
    return "$SK_USAGE"
  fi
  if [ "$__begin" = "$__end" ]; then
    log_error "$(_t 'block markers must differ')"
    return "$SK_USAGE"
  fi
  if _sk_fs_has_newline "$__begin$__end"; then
    log_error "$(_t 'block markers must be single lines')"
    return "$SK_USAGE"
  fi
  fs_ensure_dir "$(dirname "$__file")" "" || return 1
  __tmp=$(_sk_fs_new_tmp "$__file") || return 1
  __cf=$(mktemp "$__file.content.XXXXXX") || {
    rm -f "$__tmp"
    return 1
  }
  if ! printf '%s' "$__content" >"$__cf"; then
    rm -f "$__tmp" "$__cf"
    return 1
  fi
  if [ -f "$__file" ]; then
    __src=$__file
  else
    __src=/dev/null
  fi

  # 标记同样走 ENVIRON：awk -v 会把 \t 之类转义掉，标记就再也匹配不上文件里的原样文本
  if ! B=$__begin E=$__end awk -v cf="$__cf" '
    function emit(   line) {
      if (!emitted && cf != "") {
        while ((getline line < cf) > 0) print line
        close(cf)
        emitted = 1
      }
    }
    BEGIN { inblk = 0; seen = 0; emitted = 0; b = ENVIRON["B"]; e = ENVIRON["E"] }
    !inblk && !seen && $0 == b { inblk = 1; seen = 1; print; next }
    inblk {
      if ($0 == e) { emit(); print e; inblk = 0 }
      next
    }
    { print }
    END {
      if (inblk) { emit(); print e }
      if (!seen) { print b; emit(); print e }
    }
  ' "$__src" >"$__tmp"; then
    rm -f "$__tmp" "$__cf"
    return 1
  fi
  rm -f "$__cf"

  if [ -f "$__file" ] && cmp -s "$__tmp" "$__file"; then
    rm -f "$__tmp"
    return 0
  fi
  if ! mv -f "$__tmp" "$__file"; then
    rm -f "$__tmp"
    return 1
  fi
  return 0
}

# fs_ensure_symlink TARGET LINK —— 已是正确链接则不动；否者替换（绝不覆盖普通文件）
# @exitcode 0 软链已就位
# @exitcode 2 参数错
# @exitcode 1 建链失败
fs_ensure_symlink() {
  local __target=${1:-} __link=${2:-} __cur
  _sk_need_args "$#" 2 "fs_ensure_symlink TARGET LINK" || return $?
  if [ -z "$__target" ] || [ -z "$__link" ]; then
    log_error "$(_t 'fs_ensure_symlink requires TARGET and LINK')"
    return "$SK_USAGE"
  fi
  fs_ensure_dir "$(dirname "$__link")" "" || return 1
  if [ -L "$__link" ]; then
    __cur=$(readlink "$__link" 2>/dev/null || true)
    if [ "$__cur" = "$__target" ]; then
      return 0
    fi
    rm -f "$__link" || return 1
  elif [ -e "$__link" ]; then
    log_error "$(_t 'refusing to replace a non-symlink'): $__link"
    return "$SK_ERR"
  fi
  if ! ln -s "$__target" "$__link"; then
    return 1
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
# @exitcode 0 成功（stdout 输出临时目录路径）
# @exitcode 1 建不了临时目录
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

# fs_tmp_init —— 在当前 shell 初始化临时目录，并把清理动作推进清理栈。
# 与 0.1.0 的差别：以前「调用方已有 EXIT trap 就放弃清理」，现在改为入栈，
# 与调用方自己的 trap 共存（trap_install 会链式保留已有 EXIT trap）。
# @exitcode 0 成功（初始化当前工程的临时目录）
# @exitcode 1 建不了临时目录
fs_tmp_init() {
  if ! fs_tmpdir >/dev/null; then
    return 1
  fi
  trap_push '_sk_tmp_cleanup'
  trap_install
  return 0
}
