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

# ---- str_suggest ----
assert_eq "docker" "$(str_suggest dockr docker nginx redis)" "str_suggest picks the closest candidate"
assert_eq "nginx" "$(str_suggest ngx docker nginx redis)" "str_suggest picks the closest candidate"
assert_exit_code 1 str_suggest zzzzz
assert_eq "" "$(str_suggest zzzzz 2>/dev/null || true)" "str_suggest prints nothing when there is no candidate"
# 距离相同时取先给的那个
assert_eq "aa" "$(str_suggest ab aa)" "str_suggest keeps the first candidate on a tie"

# 编辑距离本身
assert_eq "0" "$(_str_edit_distance abc abc)" "edit distance of equal strings"
assert_eq "3" "$(_str_edit_distance abc '')" "edit distance against an empty string"
assert_eq "3" "$(_str_edit_distance '' abc)" "edit distance from an empty string"
assert_eq "1" "$(_str_edit_distance abc abd)" "edit distance of one substitution"
assert_eq "3" "$(_str_edit_distance kitten sitting)" "edit distance of a classic pair"
