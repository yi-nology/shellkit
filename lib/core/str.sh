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

# str_trim VAR
str_trim() {
  local __n=$1 __v
  _sk_is_name "$__n" || return "$SK_USAGE"
  __v=$(_sk_ref_get "$__n") || return $?
  __v="${__v#"${__v%%[![:space:]]*}"}"
  __v="${__v%"${__v##*[![:space:]]}"}"
  printf -v "$__n" '%s' "$__v"
}

# str_lower VAR
str_lower() {
  local __n=$1 __v
  _sk_is_name "$__n" || return "$SK_USAGE"
  __v=$(_sk_ref_get "$__n") || return $?
  printf -v "$__n" '%s' "$(printf '%s' "$__v" | tr '[:upper:]' '[:lower:]')"
}

# str_upper VAR
str_upper() {
  local __n=$1 __v
  _sk_is_name "$__n" || return "$SK_USAGE"
  __v=$(_sk_ref_get "$__n") || return $?
  printf -v "$__n" '%s' "$(printf '%s' "$__v" | tr '[:lower:]' '[:upper:]')"
}

# str_contains HAYSTACK NEEDLE —— 返回码；空 needle 恒返回 1
str_contains() {
  if [ -z "${2:-}" ]; then
    return 1
  fi
  case "${1:-}" in
    *"$2"*) return 0 ;;
  esac
  return 1
}

# str_starts_with STR PREFIX
str_starts_with() {
  if [ -z "${2:-}" ]; then
    return 1
  fi
  case "${1:-}" in
    "$2"*) return 0 ;;
  esac
  return 1
}

# str_ends_with STR SUFFIX
str_ends_with() {
  if [ -z "${2:-}" ]; then
    return 1
  fi
  case "${1:-}" in
    *"$2") return 0 ;;
  esac
  return 1
}

# str_repeat VAR COUNT STRING
str_repeat() {
  local __n=$1 __count=$2 __s=$3 __out="" __i=0
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
