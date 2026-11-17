#!/usr/bin/env bash
# API 冻结清单（tools/api_freeze.sh / docs/API-FREEZE.md）的判据。
#
# 要守的事：1.0 的承诺面是一份**可 diff 的快照**，不是散文里的「50 个 stable」。
# 四条：
#   1. 当前树上门禁绿（已提交清单与源码一致）
#   2. 改了一组承诺返回码 ⇒ 红（行为漂移必须显式重生成）
#   3. 把 experimental 晋升成 stable ⇒ 红（承诺面扩大必须显式改了才放行）
#   4. 多出一个语义未知的 SK_* 常量 ⇒ 红（不许静默漏写进退出码表）
# 外加：清单头部的 frozen-at 必须等于 VERSION（发版后提醒重生成）。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

SCRIPT="$TEST_ROOT/tools/api_freeze.sh"
DOC="$TEST_ROOT/docs/API-FREEZE.md"

# _copy_tree DST —— 门禁需要的最小副本（不依赖 git，coverage 副本里也能跑）
_copy_tree() {
  local __dst=$1
  mkdir -p "$__dst/tools" "$__dst/docs" || return 1
  cp -R "$TEST_ROOT/lib" "$__dst/" || return 1
  cp -f "$TEST_ROOT/shellkit" "$__dst/" || return 1
  cp -f "$TEST_ROOT/VERSION" "$__dst/" || return 1
  cp -f "$TEST_ROOT/tools/api_baseline.txt" "$__dst/tools/" || return 1
  cp -f "$DOC" "$__dst/docs/" || return 1
  return 0
}

_run() {
  local __root=$1
  shift
  rc=0
  out=$(bash "$SCRIPT" --root "$__root" "$@" 2>&1) || rc=$?
  return 0
}

# CASE 1: 当前树绿，且清单头部与 VERSION 对得上
rc=0
out=$(bash "$SCRIPT" --check 2>&1) || rc=$?
assert_eq "0" "$rc" "the freeze gate must be green on the current tree"
assert_contains "$out" "50 个 stable" "the gate must report the stable count"
assert_contains "$(cat "$DOC")" "冻结基线：v1.0.0" \
  "the freeze document must carry the fixed 1.x baseline (it must not drift with each release)"
assert_contains "$(cat "$DOC")" "\`fs_atomic_write\`" "a known stable function must be listed"
assert_contains "$(cat "$DOC")" "112 个 \`@stability experimental\` 函数" \
  "the document must say the experimental surface is not promised"

# CASE 2: 改一组合格的承诺返回码 ⇒ 已提交清单与源码对不上
d=$(tmpdir)
_copy_tree "$d" || _fail "cannot create the tree copy"
awk -F'\t' -v OFS='\t' '$1 == "fs_atomic_write" { $2 = "0,1,2,9" } { print }' \
  "$d/tools/api_baseline.txt" >"$d/tools/ab.new" && mv "$d/tools/ab.new" "$d/tools/api_baseline.txt"
_run "$d" --check
assert_eq "5" "$rc" "a changed exit-code promise must fail the freeze gate"
assert_contains "$out" "fs_atomic_write" "the diff must name the drifted function"

# CASE 3: 把一个 experimental 晋升成 stable（承诺面扩大）⇒ 红
d=$(tmpdir)
_copy_tree "$d" || _fail "cannot create the tree copy"
awk -F'\t' -v OFS='\t' '$1 == "log_info" { $8 = "stable" } { print }' \
  "$d/tools/api_baseline.txt" >"$d/tools/ab.new" && mv "$d/tools/ab.new" "$d/tools/api_baseline.txt"
_run "$d" --check
assert_eq "5" "$rc" "promoting an experimental function must fail the freeze gate"
assert_contains "$out" "log_info" "the diff must name the promoted function"

# CASE 4: 语义未知的 SK_* 常量 ⇒ 3（宁可失败，也不静默漏写）
d=$(tmpdir)
_copy_tree "$d" || _fail "cannot create the tree copy"
printf 'SK_WEIRD=7\n' >>"$d/lib/bootstrap.sh"
_run "$d" --check
assert_eq "3" "$rc" "an unknown exit-code constant must be reported, not skipped"
assert_contains "$out" "SK_WEIRD" "the error must name the unknown constant"

# CASE 5: --write 之后门禁恢复绿（恢复路径真的可用）
d=$(tmpdir)
_copy_tree "$d" || _fail "cannot create the tree copy"
awk -F'\t' -v OFS='\t' '$1 == "fs_atomic_write" { $2 = "0,1,2,9" } { print }' \
  "$d/tools/api_baseline.txt" >"$d/tools/ab.new" && mv "$d/tools/ab.new" "$d/tools/api_baseline.txt"
_run "$d" --write
assert_eq "0" "$rc" "the writer must regenerate the document"
_run "$d" --check
assert_eq "0" "$rc" "the gate must pass after regeneration"
assert_contains "$(cat "$d/docs/API-FREEZE.md")" "0,1,2,9" "the regenerated document must carry the new promise"

# CASE 6: --help 可用
rc=0
bash "$SCRIPT" --help >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "--help must exit 0"

exit 0
