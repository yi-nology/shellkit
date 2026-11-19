#!/usr/bin/env bash
# 工作树洁净门禁（tools/check_tree_clean.sh）的自证测试。
#
# 为什么这道门存在：覆盖率/api/bench 基线都用「同目录临时文件 + rename」原子替换
# ⇒ 被打断的运行会把半截临时文件留在工作树里。它们被全局 gitignore 的 *.tmp
# 藏起来（git status 干净），却在「整仓拷贝」型步骤里被再拷一遍 ⇒ 磁盘写满
# ⇒ 报错现场落在别的步骤上，看起来像「用例失败」，真因是磁盘不是代码。
#
# 判据（每条都有负对照：造坏 ⇒ 必须变红）：
#   1) 树里有 *.tmp 残留 ⇒ 红，并点名文件；
#   2) 树里有 *.covtmp 残留 ⇒ 红；
#   3) 树干净 ⇒ 绿（正对照：判据不是恒红）；
#   4) .git 与依赖目录里的临时文件不算残留（它们不是源码树的垃圾）。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

GATE="$TEST_ROOT/tools/check_tree_clean.sh"

d=$(mktemp -d "$TEST_TMP_ROOT/tree.XXXXXX") || _fail "mktemp failed"
fake="$d/tree"
mkdir -p "$fake/tools" "$fake/.git/objects" "$fake/site/node_modules/pkg" || _fail "mkdir failed"

# 1) 有 .tmp 残留 ⇒ 红，并点名文件
: >"$fake/tools/leftover.tmp"
rc=0
out=$(SHELLKIT_CHECK_ROOT="$fake" bash "$GATE" 2>&1) || rc=$?
assert_ne "0" "$rc" "a leftover .tmp must fail the tree-clean gate"
assert_contains "$out" "tools/leftover.tmp" "the gate must name the leftover file"

# 2) 去掉它 ⇒ 绿（正对照：判据不是恒红）
rm -f "$fake/tools/leftover.tmp"
rc=0
SHELLKIT_CHECK_ROOT="$fake" bash "$GATE" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "a clean tree must pass the tree-clean gate"

# 3) .covtmp 同样算残留
: >"$fake/tools/x.covtmp"
rc=0
out=$(SHELLKIT_CHECK_ROOT="$fake" bash "$GATE" 2>&1) || rc=$?
assert_ne "0" "$rc" "a leftover .covtmp must fail the tree-clean gate"
assert_contains "$out" "tools/x.covtmp" "the gate must name the .covtmp leftover"
rm -f "$fake/tools/x.covtmp"

# 4) .git 与依赖目录里的临时文件不算残留
: >"$fake/.git/objects/keep.tmp"
: >"$fake/site/node_modules/pkg/keep.tmp"
rc=0
SHELLKIT_CHECK_ROOT="$fake" bash "$GATE" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "files under .git and node_modules are not leftovers of the source tree"

# 5) 门禁对自己也成立：仓库自己的工具脚本不能被自己的门禁判红
rc=0
bash "$GATE" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "the real working tree must pass the tree-clean gate"
