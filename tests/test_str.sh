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
