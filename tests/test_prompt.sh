#!/usr/bin/env bash
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"

SHELLKIT_NONINTERACTIVE=1

v=""
ask v "Project name" "demo" 2>/dev/null
assert_eq "demo" "$v" "ask uses default"

assert_exit_code 3 ask v "Project name" 2>/dev/null
assert_exit_code 2 ask "bad-name" "p" "d" 2>/dev/null

v=""
ask_yn v "Continue?" "y" 2>/dev/null
assert_eq "y" "$v" "ask_yn default y"

v=""
ask_yn v "Continue?" "n" 2>/dev/null
assert_eq "n" "$v" "ask_yn default n"

assert_true confirm "Proceed?" "y" 2>/dev/null
assert_false confirm "Proceed?" "n" 2>/dev/null

v=""
ask_choice v "Engine" "mysql|postgresql" "postgresql" 2>/dev/null
assert_eq "postgresql" "$v" "ask_choice default"

assert_exit_code 2 ask_choice v "Engine" "mysql|postgresql" "oracle" 2>/dev/null

f="$TEST_TMP_ROOT/line.txt"
printf 'abc\n' >"$f"
line=""
_sk_read_line line "" <"$f"
assert_eq "abc" "$line" "_sk_read_line reads"

line=""
assert_exit_code 1 _sk_read_line line "" </dev/null

start=$SECONDS
line=""
assert_exit_code 2 _sk_read_line line 1 < <(sleep 5)
elapsed=$((SECONDS - start))
if [ "$elapsed" -gt 3 ]; then
  _fail "_sk_read_line timeout took ${elapsed}s, expected about 1s"
fi
