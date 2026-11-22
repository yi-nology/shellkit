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
# stable 的数量从源码现算，不手抄（与下面 exp_n 同一纪律）。
# 手抄的数字在下一次晋升后必然过期 —— 本断言曾写死「50 个 stable」，
# Task 4 的 50 → 78 晋升后立刻假红：门禁是绿的，红的是这行手抄件。
stab_n=0
for __f in "$TEST_ROOT"/lib/core/*.sh; do
  __n=$(grep -c '@stability stable' "$__f") || __n=0
  stab_n=$((stab_n + __n))
done
assert_contains "$out" "$stab_n 个 stable" "the gate must report the stable count"
assert_contains "$(cat "$DOC")" "冻结基线：v1.0.0" \
  "the freeze document must carry the fixed 1.x baseline (it must not drift with each release)"
assert_contains "$(cat "$DOC")" "\`fs_atomic_write\`" "a known stable function must be listed"
# experimental 的数量从源码现算，不手抄。
# 手抄的数字有两个坏处：加函数时忘了改 ⇒ 假红；改错了 ⇒ 假绿（文档说 112 个、
# 实际 115 个，没人知道）。这里算一遍，文档里的数字必须与源码一致。
exp_n=$(awk '
  /^[A-Za-z_][A-Za-z0-9_]*\(\)/ {
    fname = $0
    sub(/\(.*/, "", fname)
    blk = ""
    if (prev ~ /^#/) {
      blk = prev
      for (i = NR - 2; i >= 1; i--) {
        if (lines[i] ~ /^#/) { blk = lines[i] "\n" blk }
        else { break }
      }
    }
    if (fname !~ /^_/) {
      stab = ""
      n = split(blk, L, "\n")
      for (j = 1; j <= n; j++) {
        if (L[j] ~ /@stability[ \t]+/) {
          rest = L[j]
          sub(/^[^@]*@stability[ \t]+/, "", rest)
          split(rest, W, /[ \t]+/)
          stab = W[1]
        }
      }
      if (stab == "experimental") n_exp++
    }
    next
  }
  { lines[NR] = $0; prev = $0 }
  END { print n_exp + 0 }
' "$TEST_ROOT"/lib/core/*.sh)
assert_contains "$(cat "$DOC")" "$exp_n 个 \`@stability experimental\` 函数" \
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
# 晋升对象从基线现选，不手抄（曾写死 log_info —— Task 4 把它升成 stable 后
# 变异成了 no-op ⇒ 门禁保持绿 ⇒ 本用例静默失去判据能力）。
__promote=$(awk -F'\t' '$8 == "experimental" { print $1; exit }' "$d/tools/api_baseline.txt")
[ -n "$__promote" ] || _fail "no experimental function left in the baseline to promote"
awk -F'\t' -v OFS='\t' -v fn="$__promote" '$1 == fn { $8 = "stable" } { print }' \
  "$d/tools/api_baseline.txt" >"$d/tools/ab.new" && mv "$d/tools/ab.new" "$d/tools/api_baseline.txt"
# 形状守卫：变异必须真的改到分级列（no-op 时门禁保持绿，期望 5 会把假绿当真）
assert_eq "stable" "$(awk -F'\t' -v fn="$__promote" '$1 == fn { print $8 }' "$d/tools/api_baseline.txt")" \
  "the promotion mutation must actually change the level column"
_run "$d" --check
assert_eq "5" "$rc" "promoting an experimental function must fail the freeze gate"
assert_contains "$out" "$__promote" "the diff must name the promoted function"

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
