#!/usr/bin/env bash
#
# 门禁自测：check_local_names.sh 必须在「有人破坏规则」时变红。
#
# 为什么需要自测：门禁自己崩了、或者规则写空了，输出就会是「一切正常」——
# 而那恰恰是最需要它响的时候。这条门禁守的是「静默失效」这一类缺陷，
# 它自己要是静默了，等于把防线拆了。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

GATE="$TEST_ROOT/tools/check_local_names.sh"
FAKE="$TEST_TMP_ROOT/fake-root"

# 造一棵假的树：门禁只看 lib/core/*.sh 与 shellkit，够用了。
mkdir -p "$FAKE/lib/core" "$FAKE/tools"
cp "$GATE" "$FAKE/tools/check_local_names.sh"
cp "$TEST_ROOT"/lib/core/*.sh "$FAKE/lib/core/"
cp "$TEST_ROOT/shellkit" "$FAKE/shellkit"

run_gate() {
  SHELLKIT_CHECK_ROOT="$FAKE" bash "$FAKE/tools/check_local_names.sh" 2>&1
}

# 好树：必须绿
out=$(run_gate) || _fail "完好的树应该通过门禁，实际输出：$out"

# 坏树 1：公开出参函数新增一个没进保留名单的局部变量
cp "$FAKE/lib/core/str.sh" "$FAKE/lib/core/str.sh.bak"
sed -i '' 's/^  local __n=${1:-} __v$/  local __n=${1:-} __v __brand_new/' "$FAKE/lib/core/str.sh"
out=$(run_gate) && _fail "新增未登记的局部变量时门禁必须红"
case "$out" in
  *__brand_new*) ;;
  *) _fail "门禁没有指出是哪个名字坏了：$out" ;;
esac
mv "$FAKE/lib/core/str.sh.bak" "$FAKE/lib/core/str.sh"

# 坏树 2：公开出参入口不再调 _sk_check_out_name
cp "$FAKE/lib/core/str.sh" "$FAKE/lib/core/str.sh.bak"
sed -i '' 's/^  _sk_check_out_name "\$__n" || return \$?$/  :/' "$FAKE/lib/core/str.sh"
out=$(run_gate) && _fail "公开出参入口不校验保留名时门禁必须红"
mv "$FAKE/lib/core/str.sh.bak" "$FAKE/lib/core/str.sh"

# 坏树 3：把守卫函数本身改名 —— 门禁读不到名单时必须报错，而不是「一切正常」
cp "$FAKE/lib/core/str.sh" "$FAKE/lib/core/str.sh.bak"
sed -i '' 's/^_sk_check_out_name() {/_sk_check_out_name_RENAMED() {/' "$FAKE/lib/core/str.sh"
out=$(run_gate) && _fail "守卫函数被改名时门禁必须红（不能静默放行）"
mv "$FAKE/lib/core/str.sh.bak" "$FAKE/lib/core/str.sh"

# 坏树 4：局部变量不用 __ 前缀
cp "$FAKE/lib/core/str.sh" "$FAKE/lib/core/str.sh.bak"
sed -i '' 's/^  local __n=${1:-} __v$/  local __n=${1:-} badname/' "$FAKE/lib/core/str.sh"
out=$(run_gate) && _fail "局部变量没有 __ 前缀时门禁必须红"
mv "$FAKE/lib/core/str.sh.bak" "$FAKE/lib/core/str.sh"

# 树修回来之后必须重新变绿
out=$(run_gate) || _fail "修好之后应该重新通过门禁，实际输出：$out"
