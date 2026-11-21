#!/usr/bin/env bash
# 字符串工具。Bash 3.2 没有 ${var^^} 这类大小写变换，统一用 tr 兜底。

# _sk_is_name NAME —— 是否为合法 shell 变量名
_sk_is_name() {
  case "${1:-}" in
    '' | [0-9]* | *[!A-Za-z0-9_]*) return 1 ;;
  esac
  return 0
}

# _sk_check_out_name NAME —— 出参变量名校验；撞上内部保留名返回 2
#   为什么只挡这一份名单，而不是「__ 前缀一律拒绝」：
#   printf -v 写的是「最近一层声明了该名字的作用域」，所以真正会出事的是
#   「目标变量名 == 出参链路上某一层的局部变量名」。这份名单就是那条链路上的
#   全部具名局部变量 —— 只有这些名字会静默失效，其余名字（哪怕带 __ 前缀）都安全。
#   名单由 tools/check_local_names.sh 守着：链路上新增局部变量而没进名单，门禁就红。
#   用法：_sk_check_out_name "$__n" || return $?
_sk_check_out_name() {
  case "${1:-}" in
    __ans | __answer | __arg | __buf | __choices | __confirm_ans | __count | \
      __default | __hint | __i | __idx | __long | __msg | __n | __opt | \
      __opt_var | __out | __parsed | __prompt | __rc | __s | __short | __start | \
      __timeout | __tries | __v | __val | __var)
      log_error "$(_t 'reserved variable name'): ${1:-}"
      return "$SK_USAGE"
      ;;
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
# @exitcode 2 参数错（变量名非法或用了库保留名）
# @stability experimental
str_trim() {
  local __n=${1:-} __v
  _sk_need_args "$#" 1 "str_trim VAR" || return $?
  _sk_is_name "$__n" || return "$SK_USAGE"
  _sk_check_out_name "$__n" || return $?
  __v=$(_sk_ref_get "$__n") || return $?
  __v="${__v#"${__v%%[![:space:]]*}"}"
  __v="${__v%"${__v##*[![:space:]]}"}"
  printf -v "$__n" '%s' "$__v"
}

# str_lower VAR —— 转小写，原地改写该变量（3.2 没有大写展开语法）
# @exitcode 0 成功
# @exitcode 2 参数错（变量名非法或用了库保留名）
# @stability experimental
str_lower() {
  local __n=${1:-} __v
  _sk_need_args "$#" 1 "str_lower VAR" || return $?
  _sk_is_name "$__n" || return "$SK_USAGE"
  _sk_check_out_name "$__n" || return $?
  __v=$(_sk_ref_get "$__n") || return $?
  printf -v "$__n" '%s' "$(printf '%s' "$__v" | tr '[:upper:]' '[:lower:]')"
}

# str_upper VAR —— 转大写，原地改写该变量（3.2 没有大写展开语法）
# @exitcode 0 成功
# @exitcode 2 参数错（变量名非法或用了库保留名）
# @stability experimental
str_upper() {
  local __n=${1:-} __v
  _sk_need_args "$#" 1 "str_upper VAR" || return $?
  _sk_is_name "$__n" || return "$SK_USAGE"
  _sk_check_out_name "$__n" || return $?
  __v=$(_sk_ref_get "$__n") || return $?
  printf -v "$__n" '%s' "$(printf '%s' "$__v" | tr '[:lower:]' '[:upper:]')"
}

# str_contains HAYSTACK NEEDLE —— 返回码；空 needle 恒返回 1
# @exitcode 0 包含该子串
# @exitcode 1 不包含（或 needle 为空）
# @stability experimental
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
# @stability experimental
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
# @stability experimental
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
# @exitcode 2 参数错（变量名非法、用了库保留名或次数不是数字）
# @stability experimental
str_repeat() {
  local __n=${1:-} __count=${2:-} __s=${3:-} __out="" __i=0
  _sk_need_args "$#" 3 "str_repeat VAR COUNT STRING" || return $?
  _sk_is_name "$__n" || return "$SK_USAGE"
  _sk_check_out_name "$__n" || return $?
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

# _str_edit_distance A B —— 编辑距离（Levenshtein），纯 bash
# 用两个平行数组当滚动行 —— bash 3.2 没有关联数组，也不需要 eval。
_str_edit_distance() {
  local __a=${1:-} __b=${2:-}
  local __alen=${#__a} __blen=${#__b}
  local __i __j __cost __above __left __diag __best
  local -a __prev=() __cur=()
  if [ "$__a" = "$__b" ]; then
    printf '0'
    return 0
  fi
  if [ "$__alen" -eq 0 ]; then
    printf '%s' "$__blen"
    return 0
  fi
  if [ "$__blen" -eq 0 ]; then
    printf '%s' "$__alen"
    return 0
  fi
  for ((__j = 0; __j <= __blen; __j++)); do
    __prev[__j]=$__j
  done
  for ((__i = 1; __i <= __alen; __i++)); do
    __cur[0]=$__i
    for ((__j = 1; __j <= __blen; __j++)); do
      if [ "${__a:__i-1:1}" = "${__b:__j-1:1}" ]; then
        __cost=0
      else
        __cost=1
      fi
      __above=$((__prev[__j] + 1))
      __left=$((__cur[__j - 1] + 1))
      __diag=$((__prev[__j - 1] + __cost))
      __best=$__above
      if [ "$__left" -lt "$__best" ]; then
        __best=$__left
      fi
      if [ "$__diag" -lt "$__best" ]; then
        __best=$__diag
      fi
      __cur[__j]=$__best
    done
    __prev=(${__cur[@]+"${__cur[@]}"})
  done
  printf '%s' "${__prev[__blen]}"
  return 0
}

# str_suggest WORD [CANDIDATE...] —— 最接近的候选
# @brief 距离相同时取先给的那个；没有候选时返回 1。
# @param WORD 用户输入
# @param CANDIDATE 候选词，可给多个
# @exitcode 0 找到候选（stdout 输出候选）
# @exitcode 1 没有候选
# @stability experimental
str_suggest() {
  local __word=${1:-} __cand __best="" __bestd="" __d
  if [ "$#" -gt 0 ]; then
    shift
  fi
  for __cand in "$@"; do
    [ -n "$__cand" ] || continue
    __d=$(_str_edit_distance "$__word" "$__cand")
    if [ -z "$__bestd" ] || [ "$__d" -lt "$__bestd" ]; then
      __best="$__cand"
      __bestd="$__d"
    fi
  done
  [ -n "$__best" ] || return 1
  printf '%s' "$__best"
  return 0
}

# str_parse_indices INPUT MAX —— 把「选区串」解析成编号列表
# @brief 输入形如 1 / 1,3 / 2-5 / 1,3,5-8（可混合、乱序、重复；逗号后可带空格）。
# @brief 输出是**去重升序**的编号列表（空格分隔），便于按序号取候选项。
# @brief 区间写成 2-5 ⇒ 2 3 4 5；区间逆序（5-2）、越界（大于 MAX）、非数字一律判错。
# @param INPUT 选区串
# @param MAX 候选项总数（编号从 1 到 MAX）
# @exitcode 0 解析成功（stdout 是去重升序的编号列表，空格分隔）
# @exitcode 1 输入非法：空 / 空段 / 非数字 / 区间逆序 / 越界
# @exitcode 2 参数错（参数个数不对，或 MAX 不是正整数）
# @stability experimental
str_parse_indices() {
  local __input=${1:-} __max=${2:-}
  local __rest __tok __lo __hi __n __i __j __prev __tmp __dup __more __out=""
  local -a __sel=()
  _sk_need_args "$#" 2 "str_parse_indices INPUT MAX" || return $?
  case "$__max" in
    '' | *[!0-9]*) return "$SK_USAGE" ;;
  esac
  [ "$__max" -ge 1 ] || return "$SK_USAGE"
  [ -n "$__input" ] || return 1
  __rest=$__input
  while :; do
    case "$__rest" in
      *,*)
        __tok=${__rest%%,*}
        __rest=${__rest#*,}
        __more=1
        ;;
      *)
        __tok=$__rest
        __rest=""
        __more=0
        ;;
    esac
    # 去首尾空格：用户手打 "1, 3, 5-8" 是常态
    __tok=${__tok#"${__tok%%[![:space:]]*}"}
    __tok=${__tok%"${__tok##*[![:space:]]}"}
    [ -n "$__tok" ] || return 1
    case "$__tok" in
      *-*)
        __lo=${__tok%%-*}
        __hi=${__tok#*-}
        case "$__lo" in '' | *[!0-9]*) return 1 ;; esac
        case "$__hi" in '' | *[!0-9]*) return 1 ;; esac
        # 10# 前缀：去掉前导零（08 是 8，不是八进制）
        __lo=$((10#$__lo))
        __hi=$((10#$__hi))
        [ "$__lo" -le "$__hi" ] || return 1
        __n=$__lo
        while [ "$__n" -le "$__hi" ]; do
          [ "$__n" -le "$__max" ] || return 1
          __dup=0
          for __i in "${__sel[@]+"${__sel[@]}"}"; do
            if [ "$__i" = "$__n" ]; then
              __dup=1
              break
            fi
          done
          if [ "$__dup" != "1" ]; then
            __sel[${#__sel[@]}]=$__n
          fi
          __n=$((__n + 1))
        done
        ;;
      *)
        case "$__tok" in *[!0-9]*) return 1 ;; esac
        __n=$((10#$__tok))
        [ "$__n" -ge 1 ] || return 1
        [ "$__n" -le "$__max" ] || return 1
        __dup=0
        for __i in "${__sel[@]+"${__sel[@]}"}"; do
          if [ "$__i" = "$__n" ]; then
            __dup=1
            break
          fi
        done
        if [ "$__dup" != "1" ]; then
          __sel[${#__sel[@]}]=$__n
        fi
        ;;
    esac
    [ "$__more" = "1" ] || break
  done
  [ "${#__sel[@]}" -gt 0 ] || return 1
  # 插入排序：选中项通常只有几个 ⇒ O(k²) 足够，且零 fork
  __i=1
  while [ "$__i" -lt "${#__sel[@]}" ]; do
    __j=$__i
    while [ "$__j" -gt 0 ]; do
      __prev=$((__j - 1))
      if [ "${__sel[__prev]}" -le "${__sel[__j]}" ]; then
        break
      fi
      __tmp=${__sel[__prev]}
      __sel[__prev]=${__sel[__j]}
      __sel[__j]=$__tmp
      __j=$__prev
    done
    __i=$((__i + 1))
  done
  for __i in "${__sel[@]+"${__sel[@]}"}"; do
    __out="$__out${__out:+ }$__i"
  done
  printf '%s\n' "$__out"
  return 0
}
