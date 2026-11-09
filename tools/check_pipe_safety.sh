#!/usr/bin/env bash
#
# 门禁：管道里不能出现「会提前退出的消费者」。
#
# 为什么需要这道门：grep -q / head 这类命令一命中就退出，管道上游还在往里写，
# 于是上游收到 SIGPIPE 被杀死（退出码 141）。平时看不出来 —— 141 只出现在
# PIPESTATUS 里。但只要调用方开了 `set -o pipefail`，整条管道就按 141 判失败：
#
#   man_modules | grep -qx log    # grep 匹配成功，man_modules 却被 SIGPIPE 打死
#
# 于是「模块存在」被误判成「模块不存在」，而且是竞态：同一台机器有时绿有时红，
# 本机可能一直绿，CI 上必炸。
#
# 规则：管道里凡是会提前退出的消费者（grep -q / -m、head、read、sed 的 q、
# awk 的 exit），它的上游必须是「只写一次」的命令（printf / echo）。
# 其余写法一律改成：让消费者读完整个输入（去掉 -q / head），或者用纯 bash 判断
# （case 匹配、参数展开）。
#
#   bash tools/check_pipe_safety.sh   # 0 合格；5 不合格
set -u

# SHELLKIT_CHECK_ROOT 只给自测用：在一棵假的树副本上跑本门禁。
ROOT="${SHELLKIT_CHECK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)}"
_bad=0
_scanned=0

_fail() {
  printf 'check_pipe_safety: %s\n' "$1" >&2
  _bad=1
}

# --------------------------------------------------------------------------
# 拆行：按管道符切开一段命令。引号里的 | 不算管道，|| 也不算，# 之后是注释。
# 结果放在 _stages 数组里（bash 3.2 没有 nameref，用全局数组传出去）。
# --------------------------------------------------------------------------
_stages=()
_split_pipe() {
  local __s=$1 __cur="" __q="" __i=0 __c
  local __n=${#__s}
  _stages=()
  while [ "$__i" -lt "$__n" ]; do
    __c=${__s:$__i:1}
    __i=$((__i + 1))
    if [ -z "$__q" ]; then
      case "$__c" in
        "'" | '"')
          __q=$__c
          __cur=$__cur$__c
          continue
          ;;
        "\\")
          __cur=$__cur$__c
          __i=$((__i + 1))
          if [ "$__i" -le "$__n" ]; then
            __cur=$__cur${__s:$__i:1}
          fi
          __i=$((__i + 1))
          continue
          ;;
        "#")
          # 注释只在行首或空白之后开始；${x#y} 这种不是注释
          case "$__cur" in
            '' | *[[:space:]]) break ;;
          esac
          __cur=$__cur$__c
          continue
          ;;
        "|")
          if [ "$__i" -le "$__n" ] && [ "${__s:$__i:1}" = "|" ]; then
            __cur=$__cur"||"
            __i=$((__i + 1))
            continue
          fi
          _stages[${#_stages[@]}]="$__cur"
          __cur=""
          continue
          ;;
      esac
    else
      case "$__c" in
        "$__q") __q="" ;;
        "\\")
          __cur=$__cur$__c
          __i=$((__i + 1))
          if [ "$__i" -le "$__n" ]; then
            __cur=$__cur${__s:$__i:1}
          fi
          __i=$((__i + 1))
          continue
          ;;
      esac
    fi
    __cur=$__cur$__c
  done
  _stages[${#_stages[@]}]="$__cur"
  return 0
}

# _stage_cmd STAGE —— 这一段跑的是什么命令（第一个实词）
_stage_cmd() {
  local __st=$1 __w=""
  for __w in $__st; do
    case "$__w" in
      *=*) continue ;;
      *) break ;;
    esac
  done
  printf '%s' "$__w"
}

# _stage_early STAGE —— 这一段是不是「命中就退出」的消费者
_stage_early() {
  local __st=$1 __cmd __tok
  __cmd=$(_stage_cmd "$__st")
  case "$__cmd" in
    head)
      return 0
      ;;
    read)
      return 0
      ;;
    grep)
      for __tok in $__st; do
        case "$__tok" in
          --*) continue ;;
          -*)
            case "${__tok#-}" in
              *q*) return 0 ;;
              m[0-9]*) return 0 ;;
            esac
            ;;
        esac
      done
      return 1
      ;;
    sed)
      case "$__st" in
        *";q"*) return 0 ;;
        *"q;"*) return 0 ;;
        *"'q'"*) return 0 ;;
        *'"q"'*) return 0 ;;
      esac
      return 1
      ;;
    awk)
      case "$__st" in
        *exit*) return 0 ;;
      esac
      return 1
      ;;
  esac
  return 1
}

# _check_line FILE LINENO LINE
_check_line() {
  local __file=$1 __lineno=$2 __line=$3
  local __i __cmd __consumer
  _split_pipe "$__line"
  [ "${#_stages[@]}" -ge 2 ] || return 0
  for ((__i = 1; __i < ${#_stages[@]}; __i += 1)); do
    _stage_early "${_stages[$__i]}" || continue
    __cmd=$(_stage_cmd "${_stages[$((__i - 1))]}")
    case "$__cmd" in
      printf) continue ;;
      echo) continue ;;
      true) continue ;;
      false) continue ;;
    esac
    __consumer=$(_stage_cmd "${_stages[$__i]}")
    _fail "$__file:$__lineno: ${__cmd} 的输出接进会提前退出的 ${__consumer} ⇒ ${__cmd} 会被 SIGPIPE 打死（141）；调用方开了 pipefail 时整条管道判失败。改法：让 ${__consumer} 读完整个输入（去掉 -q / head），或改成纯 bash 判断"
  done
  return 0
}

_scan_file() {
  local __file=$1 __lineno=0 __line
  while IFS= read -r __line || [ -n "$__line" ]; do
    __lineno=$((__lineno + 1))
    _check_line "$__file" "$__lineno" "$__line"
  done <"$__file"
  _scanned=$((_scanned + 1))
}

# --------------------------------------------------------------------------
# 扫描范围：库、CLI、安装脚本、门禁、测试、模板 —— 会被人 vendor 走的都在内。
# --------------------------------------------------------------------------
if [ ! -d "$ROOT/lib/core" ]; then
  printf 'check_pipe_safety: %s/lib/core not found\n' "$ROOT" >&2
  exit 1
fi

for __f in \
  "$ROOT"/lib/core/*.sh \
  "$ROOT"/lib/bootstrap.sh \
  "$ROOT"/shellkit \
  "$ROOT"/install.sh \
  "$ROOT"/tools/*.sh \
  "$ROOT"/tests/*.sh \
  "$ROOT"/po/*.sh \
  "$ROOT"/templates/* \
  "$ROOT"/templates/*/*; do
  [ -f "$__f" ] || continue
  case "$__f" in
    *.md | *.json | *.txt) continue ;;
  esac
  _scan_file "$__f"
done

if [ "$_scanned" -eq 0 ]; then
  printf 'check_pipe_safety: nothing was scanned under %s\n' "$ROOT" >&2
  exit 1
fi

if [ "$_bad" -ne 0 ]; then
  printf 'check_pipe_safety: 管道里有会提前退出的消费者（SIGPIPE + pipefail 会误判失败）\n' >&2
  exit 5
fi
printf 'check_pipe_safety: ok (%s files)\n' "$_scanned"
exit 0
