#!/usr/bin/env bash
# shellkit demo 子命令的测试。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

SK="$TEST_ROOT/shellkit"

d=$(mktemp -d "$TEST_TMP_ROOT/demo.XXXXXX") || _fail "mktemp failed"

# CASE: demo 生成工程并跑通它自己的测试
out=$("$SK" demo "$d/1" 2>/dev/null)
rc=0
"$SK" demo "$d/2" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "demo must succeed"

# 工程是真的：骨架、命令、库副本、测试都在
assert_true test -x "$d/2/bin/2"
assert_true test -f "$d/2/commands/run.sh"
assert_true test -f "$d/2/commands/status.sh"
assert_true test -f "$d/2/lib/app.sh"
assert_true test -f "$d/2/vendor/shellkit/lib/bootstrap.sh"
assert_true test -x "$d/2/tests/run.sh"

# CASE: 导览告诉人下一步做什么
out=$("$SK" demo "$d/3" 2>/dev/null)
assert_contains "$out" "make test" "the tour should point at the test command"
assert_contains "$out" "vendor/shellkit/" "the tour should show what is in the project"

# CASE: 目标目录已存在就拒绝
# 演示命令会生成一堆文件；对着一个已有目录跑，用户的东西会被搅乱。
rc=0
"$SK" demo "$d/1" >/dev/null 2>&1 || rc=$?
assert_eq "3" "$rc" "demo must refuse a directory that already exists"

# CASE: --no-test 跳过测试但照样生成
rc=0
"$SK" demo "$d/4" --no-test >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "demo --no-test must succeed"
assert_true test -f "$d/4/vendor/shellkit/lib/bootstrap.sh"
