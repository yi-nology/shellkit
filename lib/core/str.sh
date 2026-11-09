#!/usr/bin/env bash
# 字符串工具。Bash 3.2 没有 ${var^^} 这类大小写变换，统一用 tr 兜底。

# _sk_is_name NAME —— 是否为合法 shell 变量名
_sk_is_name() {
  case "${1:-}" in
    '' | [0-9]* | *[!A-Za-z0-9_]*) return 1 ;;
  esac
  return 0
}

# _sk_ref_get NAME —— 输出间接变量值。名字已校验，不会注入。
_sk_ref_get() {
  local __n=$1
  _sk_is_name "$__n" || return "$SK_USAGE"
  eval "printf '%s' \"\${$__n-}\""
}

# _sk_shell_quote TEXT —— 输出能被 shell 重新解析的形式（给 dry-run 打印用）
_sk_shell_quote() {
  local __s=${1:-} __out="" __c __i=0
  case "$__s" in
    '')
      printf "''"
      return 0
      ;;
    *[!A-Za-z0-9_@%+=:,./-]*) ;;
    *)
      printf '%s' "$__s"
      return 0
      ;;
  esac
  # 需要引号：内部单引号写成 '\''，整体再包一层单引号
  while [ "$__i" -lt "${#__s}" ]; do
    __c=${__s:$__i:1}
    if [ "$__c" = "'" ]; then
      __out="$__out'\\''"
    else
      __out="$__out$__c"
    fi
    __i=$((__i + 1))
  done
  printf "'%s'" "$__out"
}

# str_trim VAR —— 去掉首尾空白，原地改写该变量
# @exitcode 0 成功
# @exitcode 2 参数错（变量名非法）
str_trim() {
  local __n=${1:-} __v
  _sk_need_args "$#" 1 "str_trim VAR" || return $?
  _sk_is_name "$__n" || return "$SK_USAGE"
  __v=$(_sk_ref_get "$__n") || return $?
  __v="${__v#"${__v%%[![:space:]]*}"}"
  __v="${__v%"${__v##*[![:space:]]}"}"
  printf -v "$__n" '%s' "$__v"
}

# str_lower VAR —— 转小写，原地改写该变量（3.2 没有大写展开语法）
# @exitcode 0 成功
# @exitcode 2 参数错（变量名非法）
str_lower() {
  local __n=${1:-} __v
  _sk_need_args "$#" 1 "str_lower VAR" || return $?
  _sk_is_name "$__n" || return "$SK_USAGE"
  __v=$(_sk_ref_get "$__n") || return $?
  printf -v "$__n" '%s' "$(printf '%s' "$__v" | tr '[:upper:]' '[:lower:]')"
}

# str_upper VAR —— 转大写，原地改写该变量（3.2 没有大写展开语法）
# @exitcode 0 成功
# @exitcode 2 参数错（变量名非法）
str_upper() {
  local __n=${1:-} __v
  _sk_need_args "$#" 1 "str_upper VAR" || return $?
  _sk_is_name "$__n" || return "$SK_USAGE"
  __v=$(_sk_ref_get "$__n") || return $?
  printf -v "$__n" '%s' "$(printf '%s' "$__v" | tr '[:lower:]' '[:upper:]')"
}

# str_contains HAYSTACK NEEDLE —— 返回码；空 needle 恒返回 1
# @exitcode 0 包含该子串
# @exitcode 1 不包含（或 needle 为空）
str_contains() {
  if [ -z "${2:-}" ]; then
    return 1
  fi
  case "${1:-}" in
    *"$2"*) return 0 ;;
  esac
  return 1
}

# str_starts_with STR PREFIX —— 前缀匹配；用返回码而不是布尔值
# @exitcode 0 匹配
# @exitcode 1 不匹配（或前缀为空）
str_starts_with() {
  if [ -z "${2:-}" ]; then
    return 1
  fi
  case "${1:-}" in
    "$2"*) return 0 ;;
  esac
  return 1
}

# str_ends_with STR SUFFIX —— 后缀匹配；用返回码而不是布尔值
# @exitcode 0 匹配
# @exitcode 1 不匹配（或后缀为空）
str_ends_with() {
  if [ -z "${2:-}" ]; then
    return 1
  fi
  case "${1:-}" in
    *"$2") return 0 ;;
  esac
  return 1
}

# str_repeat VAR COUNT STRING —— 把字符串重复 N 次写进变量
# @exitcode 0 成功
# @exitcode 2 参数错（变量名非法或次数不是数字）
str_repeat() {
  local __n=${1:-} __count=${2:-} __s=${3:-} __out="" __i=0
  _sk_need_args "$#" 3 "str_repeat VAR COUNT STRING" || return $?
  _sk_is_name "$__n" || return "$SK_USAGE"
  case "$__count" in
    '' | *[!0-9]*) return "$SK_USAGE" ;;
  esac
  while [ "$__i" -lt "$__count" ]; do
    __out="${__out}${__s}"
    __i=$((__i + 1))
  done
  printf -v "$__n" '%s' "$__out"
}

# _sk_uint VAR DEFAULT —— 把变量值规范成非负整数；未设置或非法时用 DEFAULT
_sk_uint() {
  local __n=$1 __d=$2 __v
  if ! _sk_is_name "$__n"; then
    printf '%s\n' "$__d"
    return 0
  fi
  __v=$(_sk_ref_get "$__n") || __v=""
  case "$__v" in
    '' | *[!0-9]*) __v=$__d ;;
  esac
  printf '%s\n' "$__v"
}
