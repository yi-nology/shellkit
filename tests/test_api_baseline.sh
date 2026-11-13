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
#
# 首选 git archive：拿**提交过的状态**当底，不带工作树里别人的半成品。
# 但 git 在三种环境下不可用，任何一种都不该让用例以
# 「tar: This does not look like a tar archive」这种**二次错误**收场（CI #71）：
#   1. coverage 的临时树没有 .git（coverage.sh 自己的注释就写过这件事）
#   2. 容器里 checkout 属主与容器内用户不同 ⇒ dubious ownership 拒绝操作
#   3. 镜像里压根没装 git
# 所以：报错必须指出**第一因**，然后退到「门禁真正需要的子集」。
_copy_repo() {
  local dst=$1 __err __rc=0 __f
  mkdir -p "$dst" || return 1
  if command -v git >/dev/null 2>&1 && git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
    __err=$(mktemp "${TMPDIR:-/tmp}/api-baseline-git.XXXXXX") || return 1
    if git -c safe.directory="$REPO" -C "$REPO" archive HEAD 2>"$__err" | tar -x -C "$dst"; then
      rm -f "$__err"
    else
      __rc=$?
      printf 'api_baseline: git archive failed (rc=%s): %s
' \
        "$__rc" "$(cat "$__err" 2>/dev/null)" >&2
      rm -f "$__err"
      rm -rf "$dst" && mkdir -p "$dst" || return 1
      _copy_subset "$dst" || return 1
    fi
  else
    printf 'api_baseline: git unavailable here (no git, or no .git under %s); using a worktree subset\n' \
      "$REPO" >&2
    _copy_subset "$dst" || return 1
  fi
  mkdir -p "$dst/tools" || return 1
  # 门禁**代码**从工作树拷：未提交的门禁改动也要能被自证。
  cp "$REPO/tools/api_baseline.sh" "$dst/tools/" || return 1
  # 门禁的**数据**（基线 + 分级豁免名单）必须与 archive 取出的 lib 同一份状态：
  # 无条件用工作树覆盖，会拼出「已提交的 lib + 未提交的数据」自相矛盾的副本 ——
  # 注解批次（lib 注解 / 基线分级列 / 豁免名单三者一起改）里，规则一、规则三
  # 会在探针之前先 bad=1，探针不跑，用例死在与被测行为无关的第一因上
  # （实测：探针病例报不出「探针失败」，37 个函数先被规则一拦下）。
  # 所以只补 archive 里没有的文件（尚未提交的新门禁数据）；退路 _copy_subset
  # 全取工作树，lib 与数据同样自洽。
  for __f in api_baseline.txt stability_exempt.txt; do
    if [ ! -f "$dst/tools/$__f" ]; then
      cp "$REPO/tools/$__f" "$dst/tools/" || return 1
    fi
  done
  return 0
}

# _copy_subset DST —— 退路：只拷门禁真正读的那几处（实测 lib/ + MIGRATING + VERSION）
_copy_subset() {
  local dst=$1
  cp -R "$REPO/lib" "$dst/" || return 1
  mkdir -p "$dst/docs" || return 1
  cp "$REPO/docs/MIGRATING.md" "$dst/docs/" || return 1
  cp "$REPO/VERSION" "$dst/" || return 1
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
