#!/usr/bin/env bash
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"

v="  hi there  "
str_trim v
assert_eq "hi there" "$v" "str_trim"

v="  "
str_trim v
assert_eq "" "$v" "str_trim all spaces"

v="MiXeD"
str_lower v
assert_eq "mixed" "$v" "str_lower"

v="MiXeD"
str_upper v
assert_eq "MIXED" "$v" "str_upper"

assert_true str_contains "abcdef" "cd"
assert_false str_contains "abcdef" "zz"
assert_false str_contains "abcdef" ""

assert_true str_starts_with "abcdef" "abc"
assert_false str_starts_with "abcdef" "bcd"
assert_true str_ends_with "abcdef" "def"
assert_false str_ends_with "abcdef" "de"

v=""
str_repeat v 3 "ab"
assert_eq "ababab" "$v" "str_repeat"

assert_exit_code 1 _sk_is_name "bad-name"
assert_exit_code 2 str_trim "bad-name"
v="keep"
assert_exit_code 2 str_trim "bad-name"
assert_eq "keep" "$v" "invalid name must not touch the variable"

# 出参名撞上出参链路上的局部变量时必须拒绝：以前是静默失效（值写回函数自己那层，
# 调用方拿到的还是旧值）。名单之外的变量名照常能用 —— 不是「__ 前缀一律拒绝」。
assert_exit_code 2 str_trim __n 2>/dev/null
assert_exit_code 2 str_lower __v 2>/dev/null
assert_exit_code 2 str_upper __n 2>/dev/null
assert_exit_code 2 str_repeat __out 2 "x" 2>/dev/null

__custom="  trim me  "
str_trim __custom
assert_eq "trim me" "$__custom" "a __-prefixed name outside the reserved list still works"
