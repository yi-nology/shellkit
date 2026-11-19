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
# 副本**全部取工作树**，不依赖 git —— 理由见 _copy_repo 的注释。
. "$(cd "$(dirname "$0")" && pwd)/test_helper.sh"

REPO="$TEST_ROOT"

# _copy_repo DST —— 造一份门禁需要的最小副本（**不依赖 git**）
#
# 为什么不用 `git archive HEAD`：那份 archive 是**已提交的状态**，而门禁的数据
# （tools/api_baseline.txt）来自工作树 —— 两者可能不是同一份状态。
# 新增模块尚未提交时就撞上：基线里已经有 proc_* / git_* 的条目，
# archive 出来的 lib 里却没有这些函数 ⇒ 门禁报「探针表里有一个不是公开函数的
# 条目」⇒ 规则一先拦下 ⇒ 探针压根没跑 ⇒ 用例红在
# 「探针失败: validate_port」这个**与被测行为无关的第一因**上
# （实测：把 validate_port 的范围判断改成恒真，探针没红，用例反而红了）。
#
# 同源才判得准：lib、门禁代码、门禁数据、MIGRATING 全部取工作树。
# 也不依赖 git —— compat 容器里要么没有 git，要么 git 不认这个 checkout 的属主
# （dubious ownership），依赖它就会红在「建不出副本」上（CI run 43374301252）。
_copy_repo() {
  local dst=$1
  mkdir -p "$dst" || return 1
  cp -R "$REPO/lib" "$dst/" || return 1
  mkdir -p "$dst/docs" || return 1
  cp "$REPO/docs/MIGRATING.md" "$dst/docs/" || return 1
  cp "$REPO/VERSION" "$dst/" || return 1
  mkdir -p "$dst/tools" || return 1
  cp "$REPO/tools/api_baseline.sh" "$REPO/tools/api_baseline.txt" \
    "$REPO/tools/stability_exempt.txt" "$dst/tools/" || return 1
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

# _assert_gate_rc WANT MSG —— 断言门禁退出码；失败时把门禁输出一起打出来
#
# 门禁的退出码只说明「红了」，看不出为什么红：macos runner 上拿到过一个
# 契约外的 1（契约是 0/2/3/5），日志里却只有 rc 没有门禁报错，无从定位（#73）。
_assert_gate_rc() {
  local __want=$1 __msg=$2
  if [ "$GATE_RC" != "$__want" ]; then
    printf '%s\n' '--- api_baseline output ---' >&2
    printf '%s\n' "$GATE_OUT" >&2
    printf '%s\n' '--- end api_baseline output ---' >&2
  fi
  assert_eq "$__want" "$GATE_RC" "$__msg"
}

# CASE: 基线里的承诺被改坏 ⇒ 门禁必须红
d=$(tmpdir)
_copy_repo "$d" || _fail "cannot create the repo copy"
awk -v FS='\t' -v OFS='\t' '$1 == "str_trim" { $2 = "0,2,9" } { print }' \
  "$d/tools/api_baseline.txt" >"$d/tools/api_baseline.new"
mv "$d/tools/api_baseline.new" "$d/tools/api_baseline.txt"
_gate "$d"
_assert_gate_rc "5" "the gate must fail when the baseline does not match the source"
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
_assert_gate_rc "5" "the gate must fail when a probed function changes behavior"
assert_contains "$GATE_OUT" "探针失败: validate_port" "the probe must catch the behavior change"

# CASE: 公开函数被删掉 ⇒ 门禁必须红
d=$(tmpdir)
_copy_repo "$d" || _fail "cannot create the repo copy"
# 把 str_suggest 改成私有名（不再是公开函数）＝ 公开 API 少了一个
awk '{ if ($0 ~ /^str_suggest\(\) {$/) sub(/^str_suggest/, "_str_suggest"); print }' \
  "$d/lib/core/str.sh" >"$d/lib/core/str.new"
mv "$d/lib/core/str.new" "$d/lib/core/str.sh"
_gate "$d"
_assert_gate_rc "5" "the gate must fail when a public function disappears"
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
_assert_gate_rc "5" "an undeclared behavior change must fail the gate"
assert_contains "$GATE_OUT" "str_trim" "the gate must name the function whose promise changed"

# 没声明就不许重生成基线 —— 否则「改了行为顺手重生成基线」就能把声明绕过
rc=0
out=$(bash "$d/tools/api_baseline.sh" --root "$d" --write-baseline 2>&1) || rc=$?
assert_eq "5" "$rc" "the baseline must not be regenerated without a declaration"
assert_contains "$out" "MIGRATING" "the error must point at docs/MIGRATING.md"

# 写进迁移说明 —— 「会改变结果的行为变化」小节的表格里点名 str_trim
# 小节的版本必须「新于基线版本」，而基线版本跟着 VERSION 走 —— 写死版本对会在
# 每次发版后腐化（0.18.0 发版、基线重生成后这里就红过一次），所以按当前
# VERSION 推导下一版：0.18.0 → 0.19.0。
__cur=$(tr -d '[:space:]' <"$REPO/VERSION")
__next=${__cur%.*}.$((${__cur##*.} + 1))
printf '\n### %s → %s：会改变结果的行为变化\n\n| 变化 | 以前 | 现在 | 你会在哪里撞到 |\n|---|---|---|---|\n| `str_trim` 的返回码 | 只有 0 与 2 | 多了一个 9 | 按返回码分支的调用方 |\n' \
  "$__cur" "$__next" >>"$d/docs/MIGRATING.md"

rc=0
out=$(bash "$d/tools/api_baseline.sh" --root "$d" --write-baseline 2>&1) || rc=$?
assert_eq "0" "$rc" "the baseline must be regenerable once the change is declared"
assert_contains "$out" "str_trim" "the tool should report what changed"

_gate "$d"
_assert_gate_rc "0" "the gate must pass once the change is declared"
assert_contains "$GATE_OUT" "api_baseline: ok" "the gate should report success"

# 真实工作树一个字节都没动
assert_true test -f "$REPO/tools/api_baseline.txt"
assert_true test -f "$REPO/tools/api_baseline.sh"
