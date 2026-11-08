#!/usr/bin/env bash
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

d=$(tmpdir)
tools_dir="$TEST_ROOT/tools"

# ---- 渲染 ----
src="$d/sample.sh"
cat >"$src" <<'SAMPLE'
#!/usr/bin/env bash

# 普通函数，第一行就是摘要
# 第二行补充说明
demo_fn() { :; }

# @brief 显式摘要优先
# @param NAME 名字
# @param VALUE 值
# @exitcode 0 成功
# @exitcode 3 前置条件不满足
# @example
#   demo_tagged a b
# @see demo_fn
demo_tagged() { :; }

# @internal 不该出现
hidden_fn() { :; }

# 私有函数也不该出现
_private_fn() { :; }
SAMPLE

out=$(awk -v mod="sample" -f "$tools_dir/shdoc.awk" "$src")
assert_contains "$out" "## sample" "module heading is emitted"
assert_contains "$out" "### \`demo_fn\`" "public function gets a heading"
assert_contains "$out" "普通函数，第一行就是摘要" "first comment line becomes the brief"
assert_contains "$out" "第二行补充说明" "extra brief lines are kept"
assert_contains "$out" "显式摘要优先" "@brief overrides the first line"
assert_contains "$out" "NAME 名字" "@param is rendered"
assert_contains "$out" "3 前置条件不满足" "@exitcode is rendered"
assert_contains "$out" "demo_tagged a b" "@example is rendered"
assert_not_contains "$out" "hidden_fn" "@internal functions are hidden"
assert_not_contains "$out" "_private_fn" "private functions are hidden"

# ---- 注释覆盖率 ----
cov="$d/cov.sh"
cat >"$cov" <<'COV'
#!/usr/bin/env bash

# 有注释
good_fn() { :; }

bad_fn() { :; }

# 私有函数免检
_hidden_fn() { :; }
COV
out=$(awk -v file="cov.sh" -f "$tools_dir/coverage.awk" "$cov")
assert_contains "$out" "bad_fn" "a public function without a doc comment is reported"
assert_not_contains "$out" "good_fn" "a documented function is not reported"
assert_not_contains "$out" "_hidden_fn" "private functions are exempt"

# ---- 仓库自检 ----
assert_exit_code 0 bash "$TEST_ROOT/shellkit" docs --check

# ---- 漂移必须判红，且能恢复 ----
ref="$TEST_ROOT/docs/REFERENCE.md"
cp "$ref" "$d/ref.bak"
trap 'cp -f "$d/ref.bak" "$ref" 2>/dev/null || true' EXIT
printf '\n<!-- tampered -->\n' >>"$ref"
assert_exit_code 5 bash "$TEST_ROOT/shellkit" docs --check
cp -f "$d/ref.bak" "$ref"
assert_exit_code 0 bash "$TEST_ROOT/shellkit" docs --check
