#!/usr/bin/env bash
#
# 门禁自测：check_local_names.sh 必须在「有人破坏规则」时变红。
#
# 为什么需要自测：门禁自己崩了、或者规则写空了，输出就会是「一切正常」——
# 而那恰恰是最需要它响的时候。这条门禁守的是「静默失效」这一类缺陷，
# 它自己要是静默了，等于把防线拆了。
#
# 改坏文件一律用 bash 的字符串替换，不用 sed -i：BSD 的 sed -i '' 与 GNU 的
# sed -i 参数不同，本机（macOS）过了、CI（Ubuntu）会炸 —— 这条测试本身
# 就栽在这上面过一次。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

GATE="$TEST_ROOT/tools/check_local_names.sh"
FAKE="$TEST_TMP_ROOT/fake-root"
STR="$FAKE/lib/core/str.sh"

# 造一棵假的树：门禁只看 lib/core/*.sh 与 shellkit，够用了。
mkdir -p "$FAKE/lib/core" "$FAKE/tools"
cp "$GATE" "$FAKE/tools/check_local_names.sh"
cp "$TEST_ROOT"/lib/core/*.sh "$FAKE/lib/core/"
cp "$TEST_ROOT/shellkit" "$FAKE/shellkit"

run_gate() {
  SHELLKIT_CHECK_ROOT="$FAKE" bash "$FAKE/tools/check_local_names.sh" 2>&1
}

# _break_str OLD NEW —— 把 str.sh 里的 OLD 换成 NEW（换回来时用备份文件）
_break_str() {
  local __old=$1 __new=$2 __s
  __s=$(cat "$STR")
  case "$__s" in
    *"$__old"*) ;;
    *) _fail "要改的字符串在 str.sh 里找不到：$__old" ;;
  esac
  __s=${__s//"$__old"/"$__new"}
  printf '%s\n' "$__s" >"$STR"
}

# 好树：必须绿
out=$(run_gate) || _fail "完好的树应该通过门禁，实际输出：$out"

# 坏树 1：公开出参函数新增一个没进保留名单的局部变量
cp "$STR" "$STR.bak"
_break_str '  local __n=${1:-} __v' '  local __n=${1:-} __v __brand_new'
out=$(run_gate) && _fail "新增未登记的局部变量时门禁必须红"
case "$out" in
  *__brand_new*) ;;
  *) _fail "门禁没有指出是哪个名字坏了：$out" ;;
esac
mv "$STR.bak" "$STR"

# 坏树 2：公开出参入口不再调 _sk_check_out_name
cp "$STR" "$STR.bak"
_break_str '  _sk_check_out_name "$__n" || return $?' '  :'
out=$(run_gate) && _fail "公开出参入口不校验保留名时门禁必须红"
mv "$STR.bak" "$STR"

# 坏树 3：把守卫函数本身改名 —— 门禁读不到名单时必须报错，而不是「一切正常」
cp "$STR" "$STR.bak"
_break_str '_sk_check_out_name() {' '_sk_check_out_name_RENAMED() {'
out=$(run_gate) && _fail "守卫函数被改名时门禁必须红（不能静默放行）"
mv "$STR.bak" "$STR"

# 坏树 4：局部变量不用 __ 前缀
cp "$STR" "$STR.bak"
_break_str '  local __n=${1:-} __v' '  local __n=${1:-} badname'
out=$(run_gate) && _fail "局部变量没有 __ 前缀时门禁必须红"
mv "$STR.bak" "$STR"

# 树修回来之后必须重新变绿
out=$(run_gate) || _fail "修好之后应该重新通过门禁，实际输出：$out"
