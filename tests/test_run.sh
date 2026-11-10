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

# ---- 敏感参数不能进日志 ----
# 命令失败时会把命令行写进日志；命令行里带着口令，就是把口令写进了日志文件。
out=$(run --no-die sh -c 'exit 3' --password hunter2 2>&1) || true
assert_not_contains "$out" "hunter2" "a password must never reach the log"
assert_contains "$out" "command failed" "the failure must still be reported"

out=$(run --no-die sh -c 'exit 3' API_TOKEN=abc123 2>&1) || true
assert_not_contains "$out" "abc123" "a token must never reach the log"

out=$(run --no-die sh -c 'exit 3' -H 'Authorization: Bearer s3cr3t' 2>&1) || true
assert_not_contains "$out" "s3cr3t" "an authorization header must never reach the log"

# 不是敏感字段的参数照原样打印（脱敏不能把日志变成一锅粥）
out=$(run --no-die sh -c 'exit 3' --verbose /tmp/plain 2>&1) || true
assert_contains "$out" "/tmp/plain" "ordinary arguments must stay readable"

# ---- run_concurrent：被信号杀掉的实例不能算成功 ----
rc=0
ok=$(run_concurrent 1 -- sh -c 'kill -9 $PPID' 2>/dev/null) || rc=$?
assert_ne "0" "$rc" "an instance killed by a signal must fail the run"
assert_ne "1" "$ok" "an instance without an exit status must not be counted as a success"

rc=0
run_concurrent 1 -- sh -c 'kill -9 $$' >/dev/null 2>&1 || rc=$?
assert_ne "0" "$rc" "an instance that dies from a signal must fail the run"

# 正常路径不受影响
ok=$(run_concurrent 2 -- sh -c 'exit 0' 2>/dev/null)
assert_eq "2" "$ok" "run_concurrent still counts successes"

# ---- parallel_map：每个实例跑一条不同的条目 ----
out=$(printf '%s\n' alpha beta gamma | parallel_map 2 -- sh -c 'echo "$1"; exit 0' _ 2>/dev/null)
assert_contains "$out" "alpha" "parallel_map must report every item"
assert_contains "$out" "beta" "parallel_map must report every item"
assert_contains "$out" "gamma" "parallel_map must report every item"

out=$(printf '%s\n' a b | parallel_map 2 -- sh -c 'exit 0' _ 2>/dev/null | wc -l | tr -d ' ')
assert_eq "2" "$out" "parallel_map prints one result line per item"

rc=0
printf '%s\n' ok bad | parallel_map 2 -- sh -c '[ "$1" = bad ] && exit 9; exit 0' _ >/dev/null 2>&1 || rc=$?
assert_eq "9" "$rc" "parallel_map returns the first failing item's exit code"

rc=0
printf '%s\n' x | parallel_map 0 -- true >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "parallel_map rejects a count below one"

rc=0
parallel_map 2 -- >/dev/null 2>&1 <<<'x' || rc=$?
assert_eq "2" "$rc" "parallel_map requires a command"

rc=0
printf '%s\n' x | parallel_map 2 -- true >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "parallel_map succeeds when every item succeeds"

# ---- run_timeout ----
assert_exit_code 0 run_timeout 5 true
rc=0
run_timeout 5 sh -c 'exit 7' >/dev/null 2>&1 || rc=$?
assert_eq "7" "$rc" "run_timeout passes the command exit code through"
rc=0
run_timeout abc true >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "run_timeout rejects a non-numeric timeout"
rc=0
run_timeout 5 >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "run_timeout requires a command"
assert_exit_code 0 run_timeout 0 true
if command -v perl >/dev/null 2>&1; then
  rc=0
  run_timeout 1 sleep 5 >/dev/null 2>&1 || rc=$?
  assert_eq "124" "$rc" "run_timeout returns 124 on timeout"
else
  printf 'skip: no perl, run_timeout cannot enforce a timeout\n' >&2
fi

# ---- run_func_timeout ----
_fn_out() { printf 'hello\n'; }
assert_eq "hello" "$(run_func_timeout 5 _fn_out)" "run_func_timeout returns the function output"
rc=0
run_func_timeout 5 _fn_out >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "run_func_timeout succeeds when the function succeeds"
_fn_rc() { return 7; }
rc=0
run_func_timeout 5 _fn_rc >/dev/null 2>&1 || rc=$?
assert_eq "7" "$rc" "run_func_timeout passes the function exit code through"
rc=0
run_func_timeout abc _fn_out >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "run_func_timeout rejects a non-numeric timeout"
rc=0
run_func_timeout 5 >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "run_func_timeout requires a function name"
_fn_slow() { sleep 5; }
rc=0
run_func_timeout 1 _fn_slow >/dev/null 2>&1 || rc=$?
assert_eq "143" "$rc" "run_func_timeout returns 143 on timeout"

# ---- run_install_sudo_shim ----
run_install_sudo_shim
out=$(sudo touch "$d/should-not-exist" 2>&1)
assert_contains "$out" "dry-run" "the sudo shim turns sudo into a dry-run"
assert_false test -f "$d/should-not-exist"
unset -f sudo
