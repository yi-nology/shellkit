#!/usr/bin/env bash
#
# 门禁：库内部命名空间 + 出参保留名单必须一致。
#
# 为什么需要这道门：printf -v 写的是「最近一层声明了该名字的作用域」。
# 从公开入口（ask / str_trim / cli_opt）到真正落笔的那一层，中间任何一层只要
# 声明了和目标变量同名的 local，内容就写回自己那层 —— 调用方拿到的还是原值。
# 不报错、不崩，只是静默失效，比普通 bug 更难查。
#
# 查三件事：
#   1. lib/ 与 shellkit 里每个 local 声明的变量名都以 __ 开头
#      （库内部命名空间；「保留名单」才有确定含义）
#   2. 出参链路上的函数（_sk_check_out_name 里那份名单对应的链路）声明的每一个
#      具名局部变量，都必须出现在保留名单里 —— 新增局部变量忘了进名单，
#      就会多出一个「静默失效」的名字
#   3. 每个公开的出参入口都必须调用 _sk_check_out_name
#
#   bash tools/check_local_names.sh   # 0 合格；5 不合格
set -u

# SHELLKIT_CHECK_ROOT 只给自测用：在一棵假的树副本上跑本门禁。
ROOT="${SHELLKIT_CHECK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)}"
_bad=0

_fail() {
  printf 'check_local_names: %s\n' "$1" >&2
  _bad=1
}

# 出参链路：从公开入口一路走到 printf -v 的每一环。
# 名单里任何一个函数新增了具名局部变量，都要同步进 _sk_check_out_name 的名单。
CHAIN_FUNCS="str_trim str_lower str_upper str_repeat _sk_ref_get
ask ask_yn ask_choice confirm
_sk_ask_raw _sk_ask_yn_raw _sk_ask_choice_raw _sk_read_line
cli_opt cli_opts _sk_opt_set"

# 公开的出参入口：必须自己挡住保留名。
OUT_PARAM_FUNCS="str_trim str_lower str_upper str_repeat ask ask_yn ask_choice cli_opt"

# _sk_split_words TEXT —— 按 shell 词法把一行拆成若干词（每词一行）
#   处理单双引号；反斜杠转义下一个字符。不做变量展开，也不执行任何内容。
_sk_split_words() {
  local __s=${1:-} __tok="" __q="" __i=0 __c
  local __len=${#__s}
  while [ "$__i" -lt "$__len" ]; do
    __c=${__s:$__i:1}
    __i=$((__i + 1))
    if [ -z "$__q" ]; then
      case "$__c" in
        " " | "\t")
          if [ -n "$__tok" ]; then
            printf '%s\n' "$__tok"
            __tok=""
          fi
          continue
          ;;
        "'" | '"')
          __q=$__c
          continue
          ;;
        "\\")
          __i=$((__i + 1))
          __c=${__s:$__i:1}
          ;;
      esac
    elif [ "$__c" = "$__q" ]; then
      __q=""
      continue
    elif [ "$__c" = "\\" ] && [ "$__q" = '"' ]; then
      __i=$((__i + 1))
      __c=${__s:$__i:1}
    fi
    __tok="${__tok}${__c}"
  done
  if [ -n "$__tok" ]; then
    printf '%s\n' "$__tok"
  fi
}

# _fn_body FILE FUNC —— 打印函数正文；函数不存在返回 1
_fn_body() {
  local __file=$1 __want=$2 __line __head __in=0 __found=0
  while IFS= read -r __line || [ -n "$__line" ]; do
    if [ "$__in" = "1" ]; then
      case "$__line" in
        '}'*)
          __in=0
          continue
          ;;
      esac
      printf '%s\n' "$__line"
      continue
    fi
    # 函数定义行：取第一个 { 之前的内容，去掉尾部空白后与「名字()」比较
    __head=${__line%%\{*}
    __head=${__head%"${__head##*[![:space:]]}"}
    if [ "$__head" = "$__want()" ]; then
      __in=1
      __found=1
    fi
  done <"$__file"
  [ "$__found" = "1" ] || return 1
  return 0
}

# _fn_names FILE —— 打印文件里所有函数名（每行一个）
_fn_names() {
  local __file=$1 __line __head
  while IFS= read -r __line || [ -n "$__line" ]; do
    __head=${__line%%\{*}
    __head=${__head%"${__head##*[![:space:]]}"}
    case "$__head" in
      *\(\))
        __head=${__head%\(\)}
        case "$__head" in
          "" | *[!A-Za-z0-9_]*) continue ;;
        esac
        printf '%s\n' "$__head"
        ;;
    esac
  done <"$__file"
}

# _fn_locals FILE FUNC —— 打印该函数声明的具名局部变量（每行一个）
_fn_locals() {
  local __body
  __body=$(_fn_body "$1" "$2") || return 1
  printf '%s\n' "$__body" | while IFS= read -r __line; do
    case "$__line" in
      [[:space:]]*local[[:space:]]* | [[:space:]]*local) ;;
      *) continue ;;
    esac
    __rest="${__line#"${__line%%[![:space:]]*}"}"
    __rest="${__rest#local}"
    for __tok in $(_sk_split_words "$__rest"); do
      case "$__tok" in
        -*) continue ;;
        *=*) __name=${__tok%%=*} ;;
        *) __name=$__tok ;;
      esac
      [ -n "$__name" ] || continue
      printf '%s\n' "$__name"
    done
  done
}

# _check_locals FILE —— 规则 1：局部变量名一律 __ 前缀
_check_locals() {
  local __file=$1 __line __lineno=0 __rest __tok __name __tokens
  while IFS= read -r __line || [ -n "$__line" ]; do
    __lineno=$((__lineno + 1))
    __rest="${__line#"${__line%%[![:space:]]*}"}"
    case "$__rest" in
      local | local\ *) ;;
      *) continue ;;
    esac
    __rest="${__rest#local}"
    __tokens=$(_sk_split_words "$__rest")
    for __tok in $__tokens; do
      case "$__tok" in
        -*) continue ;;
        *=*) __name=${__tok%%=*} ;;
        *) __name=$__tok ;;
      esac
      [ -n "$__name" ] || continue
      case "$__name" in
        __*) ;;
        *) _fail "${__file##*/}:${__lineno}: 局部变量 $__name 必须用 __ 前缀（库内部命名空间）" ;;
      esac
    done
  done <"$__file"
}

# 保留名单：_sk_check_out_name 的 case 分支里列出来的那些名字
_guard_list() {
  local __body
  __body=$(_fn_body "$ROOT/lib/core/str.sh" "_sk_check_out_name") || return 1
  printf '%s\n' "$__body" | grep -o '__[A-Za-z0-9_]*' | sort -u
}

for __f in "$ROOT"/lib/core/*.sh "$ROOT"/lib/bootstrap.sh "$ROOT"/shellkit; do
  [ -f "$__f" ] || continue
  _check_locals "$__f"
done

# 规则 2：出参链路上的每个具名局部变量都必须在保留名单里
#   两部分：
#     2a 自动 —— 凡是出现动态出参（printf -v "$..."）的函数，它声明的每个具名局部变量
#         都必须在名单里。新写一个出参函数而不进名单，门禁立刻红。
#     2b 硬名单 —— 把「出参」转手交给私有函数的公开入口（ask / cli_opts 之类），
#         它们自己的局部变量同样在链路上，一并列进 CHAIN_FUNCS 盯着。
__guard=$(_guard_list) || {
  _fail "读不到 _sk_check_out_name 的保留名单（str.sh 被改坏了？）"
  __guard=""
}
if [ -n "$__guard" ]; then
  for __cand in "$ROOT"/lib/core/*.sh; do
    [ -f "$__cand" ] || continue
    for __fn in $(_fn_names "$__cand"); do
      # 私有函数（名字带 _ 前缀）的出参只来自库内部，名字由我们自己保证；
      # 它们靠下面 CHAIN_FUNCS 那份硬名单盯着（被公开入口用到的那些）。
      case "$__fn" in
        _*) continue ;;
      esac
      __body=$(_fn_body "$__cand" "$__fn") || continue
      case "$__body" in
        *'printf -v "$'*) ;;
        *) continue ;;
      esac
      for __name in $(_fn_locals "$__cand" "$__fn"); do
        case "$__name" in
          __*) ;;
          *) continue ;;
        esac
        if ! printf '%s\n' "$__guard" | grep -qx "$__name"; then
          _fail "$__fn() 的局部变量 $__name 没进 _sk_check_out_name 的保留名单（用这个名字的调用方会静默拿到旧值）"
        fi
      done
    done
  done
  for __fn in $CHAIN_FUNCS; do
    __file=""
    for __cand in "$ROOT"/lib/core/*.sh; do
      if _fn_body "$__cand" "$__fn" >/dev/null 2>&1; then
        __file=$__cand
        break
      fi
    done
    if [ -z "$__file" ]; then
      _fail "链路上找不到函数 $__fn（它被删了还是改了名？）"
      continue
    fi
    for __name in $(_fn_locals "$__file" "$__fn"); do
      case "$__name" in
        __*) ;;
        *) continue ;;
      esac
      if ! printf '%s\n' "$__guard" | grep -qx "$__name"; then
        _fail "$__fn() 的局部变量 $__name 没进 _sk_check_out_name 的保留名单（用这个名字的调用方会静默拿到旧值）"
      fi
    done
  done
fi

# 规则 3：公开的出参入口必须挡住保留名
#   3a 自动 —— 凡是公开的（名字不以 _ 开头）动态出参函数，都必须调 _sk_check_out_name
#   3b 硬名单 —— 转手交给私有函数的公开入口同样要挡
for __cand in "$ROOT"/lib/core/*.sh; do
  [ -f "$__cand" ] || continue
  for __fn in $(_fn_names "$__cand"); do
    case "$__fn" in
      _*) continue ;;
    esac
    __body=$(_fn_body "$__cand" "$__fn") || continue
    case "$__body" in
      *'printf -v "$'*) ;;
      *) continue ;;
    esac
    case "$__body" in
      *_sk_check_out_name*) ;;
      *) _fail "$__fn() 是公开出参入口，必须调用 _sk_check_out_name 挡住保留名" ;;
    esac
  done
done
for __fn in $OUT_PARAM_FUNCS; do
  __file=""
  for __cand in "$ROOT"/lib/core/*.sh; do
    if _fn_body "$__cand" "$__fn" >/dev/null 2>&1; then
      __file=$__cand
      break
    fi
  done
  if [ -z "$__file" ]; then
    _fail "找不到公开出参函数 $__fn"
    continue
  fi
  if ! _fn_body "$__file" "$__fn" | grep -q '_sk_check_out_name'; then
    _fail "$__fn() 是公开出参入口，必须调用 _sk_check_out_name 挡住保留名"
  fi
done

if [ "$_bad" -ne 0 ]; then
  printf 'check_local_names: 库内部命名空间与出参保留名单不合格\n' >&2
  exit 5
fi
printf 'check_local_names: ok\n'
exit 0
