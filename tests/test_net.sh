#!/usr/bin/env bash
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"

d=$(tmpdir)
src="$d/src.txt"
printf 'shellkit net test\n' >"$src"
sum=$(net_sha256 "$src")
assert_eq "$(os_sha256 "$src")" "$sum" "net_sha256 matches os_sha256"

dst="$d/dst.txt"
net_download "file://$src" "$dst" "$sum" 2>/dev/null
assert_eq "shellkit net test" "$(cat "$dst")" "net_download content"

net_download "file://$src" "$dst" "$sum" 2>/dev/null
assert_eq "shellkit net test" "$(cat "$dst")" "net_download reuses cache"

bad="$d/bad.txt"
assert_exit_code 5 net_download "file://$src" "$bad" "0000000000000000000000000000000000000000000000000000000000000000"
assert_false test -f "$bad"

assert_true net_verify "$src" "$sum"
assert_exit_code 5 net_verify "$src" "deadbeef"

assert_exit_code 4 net_wait_port 127.0.0.1 1 1
