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
# 实现：一次 awk 扫描做完「拆管道 → 认命令 → 判消费者」的活。
#   为什么不用纯 bash 逐行扫：原实现每行都要跑一次拆管道，而拆出来的每一段
#   又要 fork 一次子 shell 去问「这段跑的是什么命令」（O(行数 × 段数) 次 fork）
#   —— 本机单跑 88s，CI 上是每个 job 的固定开销。改成一次 awk 扫描后只剩一次
#   fork。判定口径与失败文案保持逐字不变（既有测试断的就是文案）。
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

# 扫描器内嵌在本文件里，不拆成独立的 .awk 文件：
#   门禁自测（tests/test_pipe_safety.sh）会把本脚本单独复制到一棵假树上跑，
#   内嵌 ⇒ 假树不需要第二个文件，判据不会因为「少拷了一个文件」而假红。
__scan_prog=$(mktemp "${TMPDIR:-/tmp}/sk-pipe-safety.XXXXXX") || {
  printf 'check_pipe_safety: 临时文件创建失败（TMPDIR 不可写？）\n' >&2
  exit 1
}
__scan_list=$(mktemp "${TMPDIR:-/tmp}/sk-pipe-safety-list.XXXXXX") || {
  rm -f "$__scan_prog"
  printf 'check_pipe_safety: 临时文件创建失败（TMPDIR 不可写？）\n' >&2
  exit 1
}
trap 'rm -f "$__scan_prog" "$__scan_list"' EXIT

cat >"$__scan_prog" <<'SK_PIPE_SAFETY_AWK'
# 一次扫描：逐行拆管道 → 认出每段跑什么命令 → 判有没有「命中就退」的消费者。

function fail(msg) {
  printf "check_pipe_safety: %s\n", msg > "/dev/stderr"
  bad = 1
}

# split_pipe —— 按管道符切开一段命令。
#   引号里的 | 不算管道，|| 也不算，# 之后是注释（形如 x#y 的参数展开不是注释）。
function split_pipe(s,   i, n, c, q, cur, nst) {
  nst = 0
  n = length(s)
  i = 1
  q = ""
  cur = ""
  while (i <= n) {
    c = substr(s, i, 1)
    i++
    if (q == "") {
      if (c == "'" || c == "\"") {
        q = c
        cur = cur c
        continue
      }
      if (c == "\\") {
        cur = cur c
        i++
        if (i <= n) cur = cur substr(s, i, 1)
        i++
        continue
      }
      if (c == "#") {
        # 注释只在行首或空白之后开始
        if (cur == "" || substr(cur, length(cur), 1) ~ /[[:space:]]/) break
        cur = cur c
        continue
      }
      if (c == "|") {
        if (i <= n && substr(s, i, 1) == "|") {
          cur = cur "||"
          i++
          continue
        }
        stages[++nst] = cur
        cur = ""
        continue
      }
    } else {
      if (c == q) {
        q = ""
      } else if (c == "\\") {
        cur = cur c
        i++
        if (i <= n) cur = cur substr(s, i, 1)
        i++
        continue
      }
    }
    cur = cur c
  }
  stages[++nst] = cur
  return nst
}

# stage_cmd —— 这一段跑的是什么命令（第一个实词；带 = 的赋值不算）
function stage_cmd(st,   m, i, parts, w) {
  m = split(st, parts, /[[:space:]]+/)
  for (i = 1; i <= m; i++) {
    w = parts[i]
    if (w == "") continue
    if (index(w, "=") > 0) continue
    return w
  }
  return ""
}

# stage_early —— 这一段是不是「命中就退出」的消费者
function stage_early(st,   cmd, m, i, parts, w, rest) {
  cmd = stage_cmd(st)
  if (cmd == "head") return 1
  if (cmd == "read") return 1
  if (cmd == "grep") {
    m = split(st, parts, /[[:space:]]+/)
    for (i = 1; i <= m; i++) {
      w = parts[i]
      if (w == "") continue
      if (substr(w, 1, 2) == "--") continue
      if (substr(w, 1, 1) == "-") {
        rest = substr(w, 2)
        if (index(rest, "q") > 0) return 1
        if (rest ~ /^m[0-9]/) return 1
      }
    }
    return 0
  }
  if (cmd == "sed") {
    if (index(st, ";q") > 0) return 1
    if (index(st, "q;") > 0) return 1
    if (index(st, "'q'") > 0) return 1
    if (index(st, "\"q\"") > 0) return 1
    return 0
  }
  if (cmd == "awk") {
    if (index(st, "exit") > 0) return 1
    return 0
  }
  return 0
}

BEGIN {
  bad = 0
  n = 0
  while ((getline p < listfile) > 0) {
    if (p != "") paths[++n] = p
  }
  close(listfile)

  for (fi = 1; fi <= n; fi++) {
    lineno = 0
    while ((getline line < paths[fi]) > 0) {
      lineno++
      nst = split_pipe(line)
      if (nst < 2) continue
      for (i = 2; i <= nst; i++) {
        if (!stage_early(stages[i])) continue
        cmd = stage_cmd(stages[i - 1])
        if (cmd == "printf" || cmd == "echo" || cmd == "true" || cmd == "false") continue
        consumer = stage_cmd(stages[i])
        fail(paths[fi] ":" lineno ": " cmd " 的输出接进会提前退出的 " consumer " ⇒ " cmd " 会被 SIGPIPE 打死（141）；调用方开了 pipefail 时整条管道判失败。改法：让 " consumer " 读完整个输入（去掉 -q / head），或改成纯 bash 判断")
      }
    }
    close(paths[fi])
  }

  if (bad) exit 5
  exit 0
}
SK_PIPE_SAFETY_AWK

# --------------------------------------------------------------------------
# 扫描范围：库、CLI、安装脚本、门禁、测试、模板 —— 会被人 vendor 走的都在内。
# --------------------------------------------------------------------------
if [ ! -d "$ROOT/lib/core" ]; then
  printf 'check_pipe_safety: %s/lib/core not found\n' "$ROOT" >&2
  exit 1
fi

: >"$__scan_list"
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
  printf '%s\n' "$__f" >>"$__scan_list"
  _scanned=$((_scanned + 1))
done

if [ "$_scanned" -eq 0 ]; then
  printf 'check_pipe_safety: nothing was scanned under %s\n' "$ROOT" >&2
  exit 1
fi

awk -v listfile="$__scan_list" -f "$__scan_prog"
__rc=$?
if [ "$__rc" -ne 0 ]; then
  _bad=1
fi

if [ "$_bad" -ne 0 ]; then
  printf 'check_pipe_safety: 管道里有会提前退出的消费者（SIGPIPE + pipefail 会误判失败）\n' >&2
  exit 5
fi
printf 'check_pipe_safety: ok (%s files)\n' "$_scanned"
exit 0
