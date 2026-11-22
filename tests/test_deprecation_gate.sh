#!/usr/bin/env bash
# 弃用门禁的判据：双向（合规放行 / 违规拦下）+ 两处变异自证（窗口判断改坏 ⇒
# 「不满窗口必须拦下」变绿；规则 (d) 的 _fail 改坏 ⇒ 「反向缺失必须拦下」变绿
# ⇒ 本用例红）。夹具全部建在临时目录，一个 @deprecated 都不会进 lib/。
. "$(cd "$(dirname "$0")" && pwd)/test_helper.sh"

ROOT="$TEST_ROOT"
GATE="$ROOT/tools/check_deprecation.sh"
d="$(tmpdir)"

if [ ! -f "$GATE" ]; then
  printf 'FAIL: 门禁不存在: %s\n' "$GATE" >&2
  exit 1
fi

# _mk_tree DIR —— 造一棵最小可跑的树（foo 是被观察的函数）
_mk_tree() {
  mkdir -p "$1/lib/core" "$1/docs" "$1/tools"
  printf '1.8.0\n' >"$1/VERSION"
  printf '# 台账：函数名<TAB>弃用版本<TAB>移除版本（未移除填 -）\n' >"$1/tools/deprecated.txt"
  printf '# baseline\nfoo\t0,1\tactive\t-\tprobe\t0\t-\texperimental\n' >"$1/tools/api_baseline.txt"
  printf '# migrating\n\n### 1.7.0 → 1.8.0：会改变结果的行为变化\n\n| 变化 |\n|---|\n| `foo` |\n' >"$1/docs/MIGRATING.md"
  cp "$ROOT/tools/ver_semver.sh" "$1/tools/ver_semver.sh"
  printf 'foo() { :; }\n' >"$1/lib/core/foo.sh"
}

# _ann DIR —— 给 foo 加合规注解
_ann() {
  printf '# 说明\n# @deprecated 1.7.0 —— 用 bar 代替\nfoo() { :; }\n' >"$1/lib/core/foo.sh"
}

# 1) 合规：注解 + 台账 + 迁移表 ⇒ 放行
t1="$(tmpdir)"
_mk_tree "$t1"
_ann "$t1"
printf 'foo\t1.7.0\t-\n' >>"$t1/tools/deprecated.txt"
if ! SHELLKIT_CHECK_ROOT="$t1" bash "$GATE" >"$t1/out" 2>"$t1/err"; then
  _fail "合规夹具被拦下了：$(cat "$t1/err")"
fi

# 2) 注解没有台账 ⇒ 拦下（退 5，报错点名台账）
t2="$(tmpdir)"
_mk_tree "$t2"
_ann "$t2"
SHELLKIT_CHECK_ROOT="$t2" bash "$GATE" >"$t2/out" 2>"$t2/err"
rc=$?
assert_eq 5 "$rc" "没有台账必须拦下（退 5）"
assert_contains "$(cat "$t2/err")" "没有它的台账行" "报错要指出台账缺失"

# 3) 注解但迁移表没提 ⇒ 拦下
t3="$(tmpdir)"
_mk_tree "$t3"
_ann "$t3"
printf 'foo\t1.7.0\t-\n' >>"$t3/tools/deprecated.txt"
printf '# migrating\n\nnothing here\n' >"$t3/docs/MIGRATING.md"
SHELLKIT_CHECK_ROOT="$t3" bash "$GATE" >"$t3/out" 2>"$t3/err"
rc=$?
assert_eq 5 "$rc" "迁移表没提必须拦下（退 5）"
assert_contains "$(cat "$t3/err")" "MIGRATING.md" "报错要指出迁移表"

# 4) 移除不满一个 minor ⇒ 拦下（弃用 1.8.0、移除 1.8.0：同 minor，窗口 0）
t4="$(tmpdir)"
_mk_tree "$t4"
printf '' >"$t4/lib/core/foo.sh" # foo 已从源码删除
printf 'foo\t1.8.0\t1.8.0\n' >>"$t4/tools/deprecated.txt"
SHELLKIT_CHECK_ROOT="$t4" bash "$GATE" >"$t4/out" 2>"$t4/err"
rc=$?
assert_eq 5 "$rc" "不满一个 minor 的移除必须拦下（退 5）"
assert_contains "$(cat "$t4/err")" "不满一个 minor" "报错要指出窗口"

# 5) 移除满窗口（弃用 1.7.0、移除 1.8.0）⇒ 放行
t5="$(tmpdir)"
_mk_tree "$t5"
printf '' >"$t5/lib/core/foo.sh"
printf 'foo\t1.7.0\t1.8.0\n' >>"$t5/tools/deprecated.txt"
if ! SHELLKIT_CHECK_ROOT="$t5" bash "$GATE" >"$t5/out" 2>"$t5/err"; then
  _fail "满窗口的移除被拦下了：$(cat "$t5/err")"
fi

# 6) 台账登记了弃用但源码没有注解（静默取消弃用）⇒ 拦下
t6="$(tmpdir)"
_mk_tree "$t6"
printf 'foo\t1.7.0\t-\n' >>"$t6/tools/deprecated.txt"
SHELLKIT_CHECK_ROOT="$t6" bash "$GATE" >"$t6/out" 2>"$t6/err"
rc=$?
assert_eq 5 "$rc" "静默取消弃用必须拦下（退 5）"
assert_contains "$(cat "$t6/err")" "没有 @deprecated 注解" "报错要指出注解缺失"

# 7) 真仓库空状态 ⇒ 放行（当前 0 个弃用 = 已武装无目标）
if ! bash "$GATE" >"$d/real.out" 2>"$d/real.err"; then
  _fail "真仓库的空状态被拦下了：$(cat "$d/real.err")"
fi

# 8) 变异自证：把窗口判断改坏 ⇒ case 4 必须从「拦下」变「放行」
mut="$d/gate-mutant.sh"
sed 's|if ! _window_ok "$__dep" "$__rm"; then|if false; then|' "$GATE" >"$mut"
if cmp -s "$GATE" "$mut"; then
  _fail "变异没落到源码上（窗口判断没变）—— 判据自己坏了"
fi
SHELLKIT_CHECK_ROOT="$t4" bash "$mut" >"$t4/mout" 2>"$t4/merr"
rc=$?
assert_eq 0 "$rc" "窗口判断改坏后不满窗口的移除被放行 —— 正说明原判断承重"

# 9) 规则 (d) 反向：基线里有、源码删了、台账没登记移除 ⇒ 拦下
t9="$(tmpdir)"
_mk_tree "$t9"
printf '' >"$t9/lib/core/foo.sh"
SHELLKIT_CHECK_ROOT="$t9" bash "$GATE" >"$t9/out" 2>"$t9/err"
rc=$?
assert_eq 5 "$rc" "规则 (d) 反向缺失必须拦下（退 5）"
assert_contains "$(cat "$t9/err")" "必须登记它的移除版本" "报错要指出反向台账缺失"

# 9a) 悬空注解：foo.sh 只有一行注解、没有函数定义 ⇒ 拦下
t9a="$(tmpdir)"
_mk_tree "$t9a"
printf '# @deprecated 1.7.0 —— 后面没有紧邻定义\n' >"$t9a/lib/core/foo.sh"
SHELLKIT_CHECK_ROOT="$t9a" bash "$GATE" >"$t9a/out" 2>"$t9a/err"
rc=$?
assert_eq 5 "$rc" "悬空注解必须拦下（退 5）"
assert_contains "$(cat "$t9a/err")" "悬空注解" "报错要指出悬空注解"

# 9b) 注解跨空行存活：注解 + 空行 + 定义、台账没登记 ⇒ 拦下。提取器不许把
# 空行当成「非注释内容」把注解吃掉 —— 吃掉就等于规则 (a) 对这条注解失明。
t9b="$(tmpdir)"
_mk_tree "$t9b"
printf '# 说明\n# @deprecated 1.7.0 —— 用 bar 代替\n\nfoo() { :; }\n' >"$t9b/lib/core/foo.sh"
SHELLKIT_CHECK_ROOT="$t9b" bash "$GATE" >"$t9b/out" 2>"$t9b/err"
rc=$?
assert_eq 5 "$rc" "空行不许吃掉注解：没有台账必须拦下（退 5）"
assert_contains "$(cat "$t9b/err")" "没有它的台账行" "注解要穿过空行到达规则 (a)"

# 10) 变异自证二：把规则 (d) 的 _fail 整行删掉 ⇒ 9 必须从「拦下」变「放行」
mut2="$d/gate-mutant-d.sh"
sed 's|_fail "$__fn 在基线里但源码里已经没有了 —— tools/deprecated.txt 必须登记它的移除版本"|:|' "$GATE" >"$mut2"
if cmp -s "$GATE" "$mut2"; then
  _fail "变异没落到源码上（规则 (d) 没变）—— 判据自己坏了"
fi
SHELLKIT_CHECK_ROOT="$t9" bash "$mut2" >"$t9/mout" 2>"$t9/merr"
rc=$?
assert_eq 0 "$rc" "规则 (d) 改坏后反向缺失被放行 —— 正说明反向对账承重"

echo "OK: 弃用门禁双向判据 + 变异自证通过"
