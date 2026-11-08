#!/usr/bin/env bash
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"

d=$(tmpdir)

# stdout 透传，日志不进 stdout
assert_eq "hi" "$(run echo hi)" "run passes stdout through"
assert_stdout_empty run true

# dry-run：只打印不执行
out=$(SHELLKIT_DRY_RUN=1 run touch "$d/a" 2>&1)
assert_eq "[dry-run] touch $d/a" "$out" "dry-run prints the command"
assert_false test -f "$d/a"

# --always 绕过 dry-run
SHELLKIT_DRY_RUN=1 run --always touch "$d/b"
assert_true test -f "$d/b"

# 无参数
assert_exit_code 2 run

# 失败即退出，且退出码沿用命令自身的
assert_exit_code 7 bash -c ". '$TEST_ROOT/lib/bootstrap.sh'; run sh -c 'exit 7'"

# 失败消息里带命令原文与退出码
msg=$(bash -c ". '$TEST_ROOT/lib/bootstrap.sh'; run sh -c 'exit 9'" 2>&1 >/dev/null || true)
assert_contains "$msg" "command failed" "failure message names the problem"
assert_contains "$msg" "exit 9" "failure message carries the exit status"
