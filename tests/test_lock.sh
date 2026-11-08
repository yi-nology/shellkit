#!/usr/bin/env bash
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"

export SHELLKIT_LOCK_DIR
SHELLKIT_LOCK_DIR=$(tmpdir)

# 获取、持有、释放
assert_exit_code 0 lock_acquire L1
assert_eq "$$" "$(lock_held L1)" "lock_held reports our pid"

# 同名再获取失败（同一进程也算占用）
assert_exit_code 3 lock_acquire L1

# 等待超时也返回 SK_PRECOND
assert_exit_code 3 lock_acquire L1 1

lock_release L1
assert_exit_code 1 lock_held L1

# 名字校验：杜绝路径穿越
assert_exit_code 2 lock_acquire '../evil'
assert_exit_code 2 lock_acquire ''
assert_exit_code 2 lock_release '../evil'

# stale 回收：持有者进程已不存在
stale="$SHELLKIT_LOCK_DIR/shellkit-ST1.lock"
mkdir -p "$stale"
printf '999999\n' >"$stale/pid"
assert_exit_code 0 lock_acquire ST1
lock_release ST1

# 只释放自己持有的锁
foreign="$SHELLKIT_LOCK_DIR/shellkit-F1.lock"
mkdir -p "$foreign"
printf '1\n' >"$foreign/pid"
assert_exit_code 3 lock_release F1
assert_true test -d "$foreign"
rm -rf "$foreign"

# 退出时自动释放（清理栈）
(
  lock_acquire AUTO1
) || _fail "acquire in subshell failed"
assert_false test -d "$SHELLKIT_LOCK_DIR/shellkit-AUTO1.lock"

# 跨进程：别人持有时拿不到；它退出时自动释放，后来者立刻能拿到
(
  lock_acquire XP
  sleep 1
) >/dev/null 2>&1 &
holder=$!
tries=0
while [ ! -d "$SHELLKIT_LOCK_DIR/shellkit-XP.lock" ] && [ "$tries" -lt 50 ]; do
  sleep 0.1
  tries=$((tries + 1))
done
assert_true test -d "$SHELLKIT_LOCK_DIR/shellkit-XP.lock"
assert_exit_code 3 lock_acquire XP
wait "$holder"
assert_false test -d "$SHELLKIT_LOCK_DIR/shellkit-XP.lock"
assert_exit_code 0 lock_acquire XP
lock_release XP
