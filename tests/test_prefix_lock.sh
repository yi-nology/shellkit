#!/usr/bin/env bash
# Prefix Lock（issue #82）的回归。
#
# install-self 的阶段目录名（<dest>.new / <dest>.old）是全 prefix 共享的
# 固定名字，两个进程同时走「恢复 → 铺 stage → 换名」会互相 rm -rf 对方的
# 阶段目录，留下半份副本或让恢复逻辑误判。修复是按 prefix 抢锁：
#   - 拿不到就明确报错（SK_PRECOND = 3），绝不并发硬闯；
#   - 锁挂在清理栈上，进程退出即释放 —— 装一次就要能自己收掉锁，
#     否则下一次安装永远红。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

SK="$TEST_ROOT/shellkit"
work=$(tmpdir)

# prefix_lock_dir PREFIX —— 复算 CLI 那边的锁名与锁目录。
# CLI 先 fs_ensure_dir 把 prefix 建出来再取锁名（prefix 存在与否会改变
# pwd -P 的解析结果），测试这边同样先建目录，再按同样的
# 「cd + pwd -P，拿不到就用原路径」口径解析，两边必须落到同一把锁上。
prefix_lock_dir() {
  local p crc
  p=$(cd "$1" 2>/dev/null && pwd -P) || p=$1
  crc=$(printf '%s' "$p" | cksum | awk '{print $1}')
  printf '%s/shellkit-pfx-%s.lock' "${TMPDIR:-/tmp}" "$crc"
}

# ---------- CASE: 别的进程正持有 prefix 锁 ⇒ 明确报错，什么都不装 ----------
p="$work/pfx"
mkdir -p "$p"
lockdir=$(prefix_lock_dir "$p")
if [ -d "$lockdir" ]; then
  rm -rf "$lockdir" || _fail "a stale prefix lock is blocking this test: $lockdir"
fi
# 持有者用测试进程自己的 pid —— 一定活着，锁不会被当僵锁回收
mkdir "$lockdir" || _fail "cannot create the lock dir"
printf '%s\n' "$$" >"$lockdir/pid"

out=$("$SK" install-self --prefix "$p" 2>&1) && rc=0 || rc=$?
assert_eq "3" "$rc" "install-self must refuse while another process holds the prefix lock"
assert_contains "$out" "another instance is running" "the refusal must say who is holding the lock"
if [ -e "$p/bin/shellkit" ] || [ -e "$p/share/shellkit.new" ] || [ -e "$p/share/shellkit.old" ]; then
  _fail "a refused install must not leave a symlink or swap debris behind"
fi

# ---------- CASE: 锁释放后必须能装，且装完自己收掉锁 ----------
rm -rf "$lockdir"
assert_exit_code 0 "$SK" install-self --prefix "$p"
assert_true test -x "$p/bin/shellkit"
if [ -d "$lockdir" ]; then
  _fail "the prefix lock must be released when install-self exits"
fi

# ---------- CASE: 锁不随 --force 放开 ----------
# --force 只放开内容比对，不放开互斥：并发硬闯正是这把锁要挡的事。
mkdir "$lockdir" || _fail "cannot create the lock dir"
printf '%s\n' "$$" >"$lockdir/pid"
out=$("$SK" install-self --prefix "$p" --force 2>&1) && rc=0 || rc=$?
assert_eq "3" "$rc" "--force must not bypass the prefix lock"
rm -rf "$lockdir"

exit 0
