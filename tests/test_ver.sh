#!/usr/bin/env bash
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"

assert_eq "0" "$(ver_cmp 1.2.3 1.2.3)" "equal versions"
assert_eq "-1" "$(ver_cmp 1.2.3 1.2.4)" "left is smaller"
assert_eq "1" "$(ver_cmp 1.3.0 1.2.9)" "left is bigger"
assert_eq "0" "$(ver_cmp v1.2.3 1.2.3)" "leading v is stripped"
assert_eq "0" "$(ver_cmp V1.2.3 1.2.3)" "leading V is stripped"

assert_true ver_gt 2.0.0 1.9.9
assert_false ver_gt 1.0.0 1.0.0
assert_true ver_lt 1.0.0 1.0.1
assert_true ver_eq 1.0 1.0.0

# 分段比较：段按数值比，不是按字符串比
assert_eq "1" "$(ver_cmp 1.10 1.9)" "1.10 is newer than 1.9"
assert_eq "-1" "$(ver_cmp 2 10)" "2 is older than 10"
assert_eq "0" "$(ver_cmp 1.0.0 1)" "missing segments count as zero"

# 非法版本串保守判否（不误报有更新）
assert_false ver_gt "not-a-version" 1.0.0
assert_false ver_gt 1.0.0 ""
assert_false ver_gt "" ""
assert_false ver_gt 1.0.0-rc1 1.0.0
assert_eq "0" "$(ver_cmp "not-a-version" 1.0.0)" "an invalid version compares as equal"

# 缺参数：非法输入一律「当相等」（ver_cmp 返回 0）⇒ gt/lt 判否、eq 判真
assert_false ver_gt
assert_false ver_lt
assert_true ver_eq
