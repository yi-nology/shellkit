#!/usr/bin/env bash
#
# 公开 API 行为基线门禁的自证用例。
#
# 四条用例，每条都在**仓库副本**里做 —— 真实工作树一个字节都不动：
#
#   1. 基线里的承诺被改坏 ⇒ 门禁必须红（基线与源码对不上）
#   2. 被探针覆盖的函数行为变了 ⇒ 门禁必须红（探针抓到）
#   3. 公开函数被删掉 ⇒ 门禁必须红（删公开函数是破坏性变更）
#   4. 行为变更没写进 MIGRATING ⇒ 红；写进去并重生成基线 ⇒ 绿
#
# 副本从 `git archive HEAD` 取 —— 用**提交过的状态**当底，免得把工作树里
# 别人还没做完的改动带进来（这份测试要能独立复现，不能被别人的半成品连累）。
# 门禁自己的两个新文件从工作树拷进副本。
. "$(cd "$(dirname "$0")" && pwd)/test_helper.sh"

REPO="$TEST_ROOT"

# _copy_repo DST —— 造一份仓库副本
_copy_repo() {
  local dst=$1
  mkdir -p "$dst" || return 1
  if ! git -C "$REPO" archive HEAD 2>/dev/null | tar -x -C "$dst"; then
    return 1
  fi
  mkdir -p "$dst/tools" || return 1
  cp "$REPO/tools/api_baseline.sh" "$dst/tools/" || return 1
  cp "$REPO/tools/api_baseline.txt" "$dst/tools/" || return 1
  return 0
}

# _gate DIR [ARGS...] —— 跑副本里的门禁；结果放在 GATE_OUT / GATE_RC
GATE_OUT=""
GATE_RC=0
_gate() {
  local dir=$1
  shift
  GATE_RC=0
  GATE_OUT=$(bash "$dir/tools/api_baseline.sh" --root "$dir" "$@" 2>&1) || GATE_RC=$?
  return 0
}

# CASE: 基线里的承诺被改坏 ⇒ 门禁必须红
d=$(tmpdir)
_copy_repo "$d" || _fail "cannot create the repo copy"
awk -v FS='\t' -v OFS='\t' '$1 == "str_trim" { $2 = "0,2,9" } { print }' \
  "$d/tools/api_baseline.txt" >"$d/tools/api_baseline.new"
mv "$d/tools/api_baseline.new" "$d/tools/api_baseline.txt"
_gate "$d"
assert_eq "5" "$GATE_RC" "the gate must fail when the baseline does not match the source"
assert_contains "$GATE_OUT" "基线与源码对不上" "the gate must say the baseline does not match the source"
assert_contains "$GATE_OUT" "str_trim" "the gate must name the mismatched function"

# CASE: 被探针覆盖的函数行为变了 ⇒ 门禁必须红（探针抓到）
d=$(tmpdir)
_copy_repo "$d" || _fail "cannot create the repo copy"
# 把 validate_port 的范围判断改成恒真：非法端口也返回 0（承诺是 0/1）
awk '{ if ($0 ~ /-le 65535/) print "    if true; then"; else print }' \
  "$d/lib/core/validate.sh" >"$d/lib/core/validate.new"
mv "$d/lib/core/validate.new" "$d/lib/core/validate.sh"
_gate "$d" --probes validate_port
assert_eq "5" "$GATE_RC" "the gate must fail when a probed function changes behavior"
assert_contains "$GATE_OUT" "探针失败: validate_port" "the probe must catch the behavior change"

# CASE: 公开函数被删掉 ⇒ 门禁必须红
d=$(tmpdir)
_copy_repo "$d" || _fail "cannot create the repo copy"
# 把 str_suggest 改成私有名（不再是公开函数）＝ 公开 API 少了一个
awk '{ if ($0 ~ /^str_suggest\(\) {$/) sub(/^str_suggest/, "_str_suggest"); print }' \
  "$d/lib/core/str.sh" >"$d/lib/core/str.new"
mv "$d/lib/core/str.new" "$d/lib/core/str.sh"
_gate "$d"
assert_eq "5" "$GATE_RC" "the gate must fail when a public function disappears"
assert_contains "$GATE_OUT" "str_suggest" "the gate must name the removed function"
assert_contains "$GATE_OUT" "源码里已经没有了" "the gate must say the function is gone"

# CASE: 行为变更没声明 ⇒ 红；声明了 ⇒ 绿
d=$(tmpdir)
_copy_repo "$d" || _fail "cannot create the repo copy"
# 给 str_trim 多承诺一个返回码（只改注释里的 @exitcode，行为不变）
awk '{ if ($0 ~ /^str_trim\(\) {$/) print "# @exitcode 9 新的失败码"; print }' \
  "$d/lib/core/str.sh" >"$d/lib/core/str.new"
mv "$d/lib/core/str.new" "$d/lib/core/str.sh"

_gate "$d"
assert_eq "5" "$GATE_RC" "an undeclared behavior change must fail the gate"
assert_contains "$GATE_OUT" "str_trim" "the gate must name the function whose promise changed"

# 没声明就不许重生成基线 —— 否则「改了行为顺手重生成基线」就能把声明绕过
rc=0
out=$(bash "$d/tools/api_baseline.sh" --root "$d" --write-baseline 2>&1) || rc=$?
assert_eq "5" "$rc" "the baseline must not be regenerated without a declaration"
assert_contains "$out" "MIGRATING" "the error must point at docs/MIGRATING.md"

# 写进迁移说明 —— 「会改变结果的行为变化」小节的表格里点名 str_trim
cat >>"$d/docs/MIGRATING.md" <<'EOF'

### 0.17.0 → 0.18.0：会改变结果的行为变化

| 变化 | 以前 | 现在 | 你会在哪里撞到 |
|---|---|---|---|
| `str_trim` 的返回码 | 只有 0 与 2 | 多了一个 9 | 按返回码分支的调用方 |
EOF

rc=0
out=$(bash "$d/tools/api_baseline.sh" --root "$d" --write-baseline 2>&1) || rc=$?
assert_eq "0" "$rc" "the baseline must be regenerable once the change is declared"
assert_contains "$out" "str_trim" "the tool should report what changed"

_gate "$d"
assert_eq "0" "$GATE_RC" "the gate must pass once the change is declared"
assert_contains "$GATE_OUT" "api_baseline: ok" "the gate should report success"

# 真实工作树一个字节都没动
assert_true test -f "$REPO/tools/api_baseline.txt"
assert_true test -f "$REPO/tools/api_baseline.sh"
