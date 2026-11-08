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
