#!/usr/bin/env bash
#
# 版本比较。纯 bash 实现，不依赖 GNU sort -V（macOS 的 BSD sort 行为有差异）。
#
# 口径：只认「数字与点」组成的版本号（去前导 v/V）；非法输入一律保守判否
# （不误报「有更新」），与 unix_script 既有 version_gt 口径一致。
#
# 分段比较：缺段当 0 ⇒ 1.0 与 1.0.0 判等。sort -V 会认为 1.0 < 1.0.0，
# 这里按分段语义走（设计文档选定「纯 bash 分段比较」）。

# _sk_ver_valid V —— 版本串是否合法（以数字开头，其后只允许数字与点）
# @exitcode 0 合法
# @exitcode 1 不合法
_sk_ver_valid() {
  case "${1:-}" in
    '' | *[!0-9.]*) return 1 ;;
  esac
  case "${1:-}" in
    [0-9]*) return 0 ;;
  esac
  return 1
}

# _sk_ver_field V N —— 取第 N 段（0 起）；不足的段当 0
# @exitcode 0 总是成功（stdout 是该段）
_sk_ver_field() {
  local __v=${1:-} __n=${2:-0} __i=0 __part
  while [ "$__i" -le "$__n" ]; do
    case "$__v" in
      *.*)
        __part=${__v%%.*}
        __v=${__v#*.}
        ;;
      *)
        __part=$__v
        __v=''
        ;;
    esac
    if [ "$__i" -eq "$__n" ]; then
      [ -n "$__part" ] || __part=0
      printf '%s' "$__part"
      return 0
    fi
    if [ -z "$__v" ]; then
      printf '%s' '0'
      return 0
    fi
    __i=$((__i + 1))
  done
  printf '%s' '0'
  return 0
}

# ver_cmp A B —— 比较两个版本号
# @exitcode 0 总是成功（stdout 输出 -1 / 0 / 1：A<B / A=B / A>B）
ver_cmp() {
  local __a=${1:-} __b=${2:-} __i=0 __x __y
  __a=${__a#v}
  __a=${__a#V}
  __b=${__b#v}
  __b=${__b#V}
  _sk_ver_valid "$__a" || {
    printf '%s' '0'
    return 0
  }
  _sk_ver_valid "$__b" || {
    printf '%s' '0'
    return 0
  }
  while [ "$__i" -lt 32 ]; do
    __x=$(_sk_ver_field "$__a" "$__i")
    __y=$(_sk_ver_field "$__b" "$__i")
    if [ "$__x" -lt "$__y" ]; then
      printf '%s' '-1'
      return 0
    fi
    if [ "$__x" -gt "$__y" ]; then
      printf '%s' '1'
      return 0
    fi
    __i=$((__i + 1))
  done
  printf '%s' '0'
  return 0
}

# ver_gt A B —— A 是否比 B 新
# @exitcode 0 A > B
# @exitcode 1 不是
ver_gt() {
  [ "$(ver_cmp "${1:-}" "${2:-}")" = '1' ]
}

# ver_lt A B —— A 是否比 B 旧
# @exitcode 0 A < B
# @exitcode 1 不是
ver_lt() {
  [ "$(ver_cmp "${1:-}" "${2:-}")" = '-1' ]
}

# ver_eq A B —— 两个版本是否相等
# @exitcode 0 相等
# @exitcode 1 不等
ver_eq() {
  [ "$(ver_cmp "${1:-}" "${2:-}")" = '0' ]
}
