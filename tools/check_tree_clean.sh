#!/usr/bin/env bash
#
# 门禁：工作树里不能留「上一次运行被打断」留下的临时文件。
#
# 为什么需要这道门：
#   覆盖率基线、api 基线、bench 基线都用「同目录临时文件 + rename」原子替换
#   （临时文件必须与目标同目录，rename 才是原子操作）⇒ 被打断的运行
#   （Ctrl-C、kill、磁盘写满）会把半截临时文件留在**工作树里**。这类文件：
#     ① 往往很大 —— 实测一次跑歪就留下过 26 GiB 的 tools/coverage_branch_baseline.txt.tmp；
#     ② 被全局 gitignore 的 `*.tmp` 吃掉 ⇒ `git status` 干净，git 完全看不见；
#     ③ 会被「整仓拷贝」型步骤（覆盖率工具、tests/test_ai_docs.sh 等）再拷一遍
#        ⇒ 磁盘写满 ⇒ 报错现场落在**别的**步骤上，看起来像「用例失败」，
#        真因是磁盘不是代码（本仓库真踩过：门禁红在 test_ai_docs.sh，
#        报的是「copy tools failed」，真因是 26 GiB 的残留）。
#   工具自己的 trap 只能兜住 INT/TERM/正常退出；被 SIGKILL 掉的运行兜不住 ⇒
#   需要一道独立于工具的门禁来兜底。
#
#   bash tools/check_tree_clean.sh   # 0 通过；5 有残留
set -u

# SHELLKIT_CHECK_ROOT 只给自测用：在一棵假的树副本上跑本门禁。
ROOT="${SHELLKIT_CHECK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)}"

TMP="$(mktemp "${TMPDIR:-/tmp}/sk-tree-clean.XXXXXX")" || {
  printf 'check_tree_clean: cannot create a temp file\n' >&2
  exit 3
}
trap 'rm -f "$TMP"' EXIT

# 扫描范围：工作树。跳过 .git、依赖目录与构建产物 —— 它们不是源码树的残留。
find "$ROOT" \
  -path "$ROOT/.git" -prune -o \
  -path "$ROOT/site/node_modules" -prune -o \
  -path "$ROOT/dist" -prune -o \
  -path "$ROOT/.upstream" -prune -o \
  -path "$ROOT/.superpowers" -prune -o \
  -type f \( -name '*.tmp' -o -name '*.covtmp' \) -print 2>/dev/null >"$TMP" || true

if [ ! -s "$TMP" ]; then
  printf 'check_tree_clean: ok\n'
  exit 0
fi

while IFS= read -r __f; do
  [ -n "$__f" ] || continue
  __size="$(wc -c <"$__f" 2>/dev/null | tr -d ' ')"
  printf 'check_tree_clean: leftover temporary file: %s (%s bytes)\n' "${__f#"$ROOT"/}" "${__size:-?}" >&2
done <"$TMP"

printf 'check_tree_clean: the working tree still holds temporary files - they are leftovers of an interrupted run; remove them and retry\n' >&2
exit 5
