#!/usr/bin/env bash
#
# semver 版本比较（发版工具链共用）
#
# 为什么单独成文件：版本比较的口径一旦有两份，迟早会漂 —— 2026-11-18 就出过：
# CHANGELOG 选「上一个已发布版本」用 git 的 refname 字典序（预发布排在正式版
# **之后**），而发版校验用这里的 semver 口径（正式版 > 预发布）⇒ GA 发版时
# 选到了 RC，生成的小节是空的，看起来像「这版什么都没改」。
#
# 两份口径合到这里，`tools/release.sh` 与 `tools/changelog_prev.sh` 共用同一实现。
#
# 为什么不直接用 sort -V：BSD sort（macOS 自带）没有 -V。
#
# 用法：source 这个文件后调 `_ver_gt A B`（A > B 时返回 0）。

# _ver_pre_cmp A B —— 预发布串比较（semver 口径：数字段按数值、数字段 < 非数字段、
# 非数字段按字典序；前缀相同段数多者大）。输出 -1/0/1。
_ver_pre_cmp() {
  local __a=$1 __b=$2 __x __y
  while [ -n "$__a" ] || [ -n "$__b" ]; do
    case "$__a" in
      *.*)
        __x=${__a%%.*}
        __a=${__a#*.}
        ;;
      *)
        __x=$__a
        __a=''
        ;;
    esac
    case "$__b" in
      *.*)
        __y=${__b%%.*}
        __b=${__b#*.}
        ;;
      *)
        __y=$__b
        __b=''
        ;;
    esac
    if [ -z "$__x" ] && [ -n "$__y" ]; then
      printf '%s' '-1'
      return 0
    fi
    if [ -n "$__x" ] && [ -z "$__y" ]; then
      printf '%s' '1'
      return 0
    fi
    [ -n "$__x" ] || {
      printf '%s' '0'
      return 0
    }
    case "$__x" in
      *[!0-9]*)
        case "$__y" in
          *[!0-9]*)
            if [ "$__x" \< "$__y" ]; then
              printf '%s' '-1'
              return 0
            fi
            if [ "$__x" \> "$__y" ]; then
              printf '%s' '1'
              return 0
            fi
            ;;
          *)
            printf '%s' '1'
            return 0
            ;;
        esac
        ;;
      *)
        case "$__y" in
          *[!0-9]*)
            printf '%s' '-1'
            return 0
            ;;
          *)
            if [ "$((10#$__x))" -lt "$((10#$__y))" ]; then
              printf '%s' '-1'
              return 0
            fi
            if [ "$((10#$__x))" -gt "$((10#$__y))" ]; then
              printf '%s' '1'
              return 0
            fi
            ;;
        esac
        ;;
    esac
  done
  printf '%s' '0'
}

# _ver_gt A B —— A > B 时返回 0（不走 sort -V：BSD sort 没有它）
# 核心三段按数值比；核心相等时按 semver 预发布规则：正式版 > 预发布，
# 预发布之间由 _ver_pre_cmp 决定。
_ver_gt() {
  local __a=$1 __b=$2 __i=1 __x __y __pa='' __pb='' __r=''
  case "$__a" in *-*)
    __pa=${__a#*-}
    __a=${__a%%-*}
    ;;
  esac
  case "$__b" in *-*)
    __pb=${__b#*-}
    __b=${__b%%-*}
    ;;
  esac
  while [ "$__i" -le 3 ]; do
    __x=$(printf '%s' "$__a" | cut -d. -f"$__i")
    __y=$(printf '%s' "$__b" | cut -d. -f"$__i")
    if [ "${__x:-0}" -gt "${__y:-0}" ]; then
      return 0
    fi
    if [ "${__x:-0}" -lt "${__y:-0}" ]; then
      return 1
    fi
    __i=$((__i + 1))
  done
  if [ -z "$__pa" ] && [ -n "$__pb" ]; then
    return 0
  fi
  if [ -n "$__pa" ] && [ -z "$__pb" ]; then
    return 1
  fi
  [ -n "$__pa" ] || return 1
  __r=$(_ver_pre_cmp "$__pa" "$__pb")
  [ "$__r" = '1' ]
}
