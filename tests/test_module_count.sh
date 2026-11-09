#!/usr/bin/env bash
#
# 门禁自测：check_module_count.sh 必须在「模块数与文档对不上」时变红。
#
# 这道门禁守的是「承诺与事实错位」：文档写着 17 个模块、实际 18 个。
# 如果门禁自己坏了（数不出来、或者什么都放行），它就变成了摆设。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

GATE="$TEST_ROOT/tools/check_module_count.sh"
FAKE="$TEST_TMP_ROOT/fake-root"

mkdir -p "$FAKE/lib" "$FAKE/tools" "$FAKE/docs" "$FAKE/site/guide"
cp "$GATE" "$FAKE/tools/check_module_count.sh"
cp "$TEST_ROOT/lib/modules.txt" "$FAKE/lib/modules.txt"
cp "$TEST_ROOT/README.md" "$FAKE/README.md"
cp "$TEST_ROOT/docs/MIGRATING.md" "$FAKE/docs/MIGRATING.md"
cp "$TEST_ROOT/site/index.md" "$FAKE/site/index.md"
cp "$TEST_ROOT/site/guide/index.md" "$FAKE/site/guide/index.md"
cp "$TEST_ROOT/site/guide/modules.md" "$FAKE/site/guide/modules.md"
cp "$TEST_ROOT/site/guide/faq.md" "$FAKE/site/guide/faq.md"

run_gate() {
  SHELLKIT_CHECK_ROOT="$FAKE" bash "$FAKE/tools/check_module_count.sh" 2>&1
}

# 好树：模块数与文档一致，必须绿
out=$(run_gate) || _fail "模块数一致时应该通过，实际输出：$out"

# 坏树：加了一个模块，文档还写着旧数字
cp "$FAKE/lib/modules.txt" "$FAKE/lib/modules.txt.bak"
printf 'extra\n' >>"$FAKE/lib/modules.txt"
out=$(run_gate) && _fail "模块数与文档对不上时门禁必须红"
case "$out" in
  *模块数*) ;;
  *) _fail "门禁没有说明是模块数对不上：$out" ;;
esac

# 清单读不到时必须报错，不能当成「0 个模块，正好没人写过」
: >"$FAKE/lib/modules.txt"
out=$(run_gate) && _fail "清单读不到模块时门禁必须红"

# 还原之后必须重新变绿
mv "$FAKE/lib/modules.txt.bak" "$FAKE/lib/modules.txt"
out=$(run_gate) || _fail "修好之后应该重新通过，实际输出：$out"
