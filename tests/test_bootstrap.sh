#!/usr/bin/env bash
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"

assert_eq "$(cd "$TEST_ROOT" && pwd)" "$SHELLKIT_HOME" "SHELLKIT_HOME"
assert_eq "0" "$SK_OK" "SK_OK"
assert_eq "3" "$SK_PRECOND" "SK_PRECOND"
assert_eq "4" "$SK_NET" "SK_NET"
assert_eq "shellkit" "$TEXTDOMAIN" "TEXTDOMAIN"

# 不改变 cwd
out=$(cd / && . "$TEST_ROOT/lib/bootstrap.sh" && pwd)
assert_eq "/" "$out" "bootstrap must not change cwd"

# 不改变 shell 选项
before=$(set -o | awk '$1 == "pipefail" { print $2 }')
. "$TEST_ROOT/lib/bootstrap.sh"
after=$(set -o | awk '$1 == "pipefail" { print $2 }')
assert_eq "$before" "$after" "bootstrap must not change shell options"

# 常量
assert_eq "0.1.0" "$SK_VERSION" "SK_VERSION"
