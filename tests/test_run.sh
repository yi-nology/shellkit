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

# ---------------------------------------------------------------------------
# issue #20：默认的 run 失败即 die，die 里的 exit 在 if / || 里照样退出整个 shell，
# 所以注释里推荐的 `if run ...` 根本不成立。--no-die 才是那个开关。
# ---------------------------------------------------------------------------

res=$(bash -c ". '$TEST_ROOT/lib/bootstrap.sh'; if run --no-die false; then echo then; else echo else; fi; echo after" 2>/dev/null)
assert_eq $'else\nafter' "$res" "--no-die makes run usable inside if"

assert_exit_code 0 bash -c ". '$TEST_ROOT/lib/bootstrap.sh'; run --no-die true"
assert_exit_code 7 bash -c ". '$TEST_ROOT/lib/bootstrap.sh'; run --no-die sh -c 'exit 7'"

# 不加 --no-die 时 if 拦不住：这条是行为契约，不能因为加了开关就悄悄变掉
res=$(bash -c ". '$TEST_ROOT/lib/bootstrap.sh'; if run sh -c 'exit 7'; then echo then; fi; echo after" 2>/dev/null)
assert_eq "" "$res" "plain run still exits from inside if"

# 只给开关不给命令仍然是用法错
assert_exit_code 2 run --no-die
assert_exit_code 2 run --always --no-die

# ---------------------------------------------------------------------------
# issue #27：dry-run 与失败消息必须保住参数边界，否则打印出来的命令粘回去就跑偏
# ---------------------------------------------------------------------------

out=$(SHELLKIT_DRY_RUN=1 run printf 'a b' 2>&1)
assert_eq "[dry-run] printf 'a b'" "$out" "dry-run keeps argument boundaries"

out=$(SHELLKIT_DRY_RUN=1 run echo "it's" 2>&1)
assert_eq "[dry-run] echo 'it'\''s'" "$out" "dry-run escapes embedded single quotes"

out=$(SHELLKIT_DRY_RUN=1 run touch "$d/with space" 2>&1)
assert_eq "[dry-run] touch '$d/with space'" "$out" "dry-run quotes a path with a space"

msg=$(bash -c ". '$TEST_ROOT/lib/bootstrap.sh'; run sh -c 'exit 4' 'a b'" 2>&1 >/dev/null || true)
assert_contains "$msg" "'a b'" "the failure message keeps argument boundaries"

# ---- run_concurrent ----

# stdout 只给数据：成功实例的数量
ok=$(run_concurrent 3 -- sh -c 'echo hi' 2>/dev/null)
assert_eq "3" "$ok" "run_concurrent reports the number of successes on stdout"

# 每个实例的输出逐行带 [i/N] 前缀，走 stderr
err=$(run_concurrent 2 -- sh -c 'echo line1; echo line2' 2>&1 1>/dev/null)
assert_contains "$err" "[1/2] line1"
assert_contains "$err" "[1/2] line2"
assert_contains "$err" "[2/2] line1"

# 有实例失败时返回第一个失败的退出码
rc=0
run_concurrent 3 -- sh -c 'exit 0' >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "run_concurrent succeeds when every instance succeeds"

rc=0
run_concurrent 3 -- sh -c 'exit 7' >/dev/null 2>&1 || rc=$?
assert_eq "7" "$rc" "run_concurrent returns the failing instance exit code"

rc=0
run_concurrent 2 -- sh -c 'exit 0' >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "run_concurrent returns 0 when all instances succeed"

# 参数错是 SK_USAGE
rc=0
run_concurrent abc -- true >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "run_concurrent rejects a non-numeric count"

rc=0
run_concurrent 0 -- true >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "run_concurrent rejects a count below one"

rc=0
run_concurrent 2 >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "run_concurrent requires a command"

# dry-run 只打印不执行
out=$(SHELLKIT_DRY_RUN=1 run_concurrent 2 -- touch "$d/concurrent" 2>&1)
assert_contains "$out" "[dry-run]"
assert_false test -f "$d/concurrent"
