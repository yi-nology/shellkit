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

# 拿锁失败不能留下副作用：既不装 trap，也不往清理栈里塞动作。
# 否则一次失败的 lock_acquire 会让调用方以为「反正有清理」，实际什么都没拿到。
# pid 用一个真活着、且能被 kill -0 探到的进程：非 root 下 pid 1 会被判成已死
sleep 30 &
_busy_pid=$!
probe="$SHELLKIT_LOCK_DIR/../probe.out"
bash -c '
  . "$1/lib/bootstrap.sh"
  mkdir -p "$SHELLKIT_LOCK_DIR/shellkit-BUSY.lock"
  printf "%s" "$3" >"$SHELLKIT_LOCK_DIR/shellkit-BUSY.lock/pid"
  lock_acquire BUSY 0 2>/dev/null
  printf "rc=%s\n" "$?" >"$2"
  trap -p EXIT >>"$2"
  trap_list >>"$2"
' _ "$TEST_ROOT" "$probe" "$_busy_pid"
kill "$_busy_pid" 2>/dev/null || true
wait "$_busy_pid" 2>/dev/null || true
assert_eq "rc=3" "$(cat "$probe")" "a failed lock_acquire has no side effects"
rm -f "$probe"
rm -rf "$SHELLKIT_LOCK_DIR/shellkit-BUSY.lock"

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

# ---------------------------------------------------------------------------
# issue #24：锁目录在、pid 文件不在。以前 SHELLKIT_LOCK_STALE 默认 0 表示「永不回收」，
# 于是一次断电/SIGKILL 就让这个锁名永久不可用，报错还说「另一个实例在跑」。
# 规则要拆成两半：刚建出来的给宽限（mkdir 与写 pid 之间有真实窗口，立刻抢会双持有），
# 超过宽限的必须回收。
# ---------------------------------------------------------------------------
nopid="$SHELLKIT_LOCK_DIR/shellkit-NOPID.lock"
mkdir -p "$nopid"
assert_exit_code 3 lock_acquire NOPID 0
assert_true test -d "$nopid"

# 做旧到宽限之外
touch -t 200001010000 "$nopid"
assert_exit_code 0 lock_acquire NOPID
lock_release NOPID

# 显式把宽限调大时，同样的旧目录也不再回收
mkdir -p "$nopid"
touch -t 200001010000 "$nopid"
assert_exit_code 3 env SHELLKIT_LOCK_STALE=9999999999 bash -c '
  . "$1/lib/bootstrap.sh"
  lock_acquire NOPID 0 2>/dev/null
' _ "$TEST_ROOT"
rm -rf "$nopid"

# 活着的持有者绝不按年龄回收：抢走锁等于让两个实例同时干活
sleep 30 &
_alive=$!
adir="$SHELLKIT_LOCK_DIR/shellkit-ALIVE.lock"
mkdir -p "$adir"
printf '%s\n' "$_alive" >"$adir/pid"
touch -t 200001010000 "$adir"
assert_exit_code 3 lock_acquire ALIVE 0
kill "$_alive" 2>/dev/null || true
wait "$_alive" 2>/dev/null || true
rm -rf "$adir"
