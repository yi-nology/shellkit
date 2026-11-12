#!/usr/bin/env bash
# 切换中途被杀的恢复：两次 rename 之间死掉时，唯一完整的旧副本不许丢。
# （评审 P0：旧实现在「换到一半被打断」后，下次运行会 rm -rf 掉唯一的好副本）
# 受控中断的做法：mv 替身执行完第一次 rename（dest→old）就 kill -9 掉父进程 ——
# 与「两次 rename 之间被 SIGKILL / 断电」留下完全相同的磁盘状态。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fault.sh"

work=$(tmpdir)
locks="$work/locks"
mkdir -p "$locks"
export SHELLKIT_LOCK_DIR="$locks"
proj="$work/app"
"$TEST_ROOT/shellkit" new "$proj" --cmd run --yes >/dev/null 2>&1
# 基线工程必须完整：不完整的话，下面的断言测的就不是「切换中途被杀」
if [ ! -f "$proj/.shellkit-manifest" ]; then
  _fail "the base project is incomplete: shellkit new did not finish"
fi
# vendor 里放一个用户自己加的文件：恢复与重装都必须把它保住
printf 'MINE\n' >"$proj/vendor/shellkit/user-note.txt"

# 让副本与源不一样，才有「换名」这回事：
# 幂等语义下，副本与源逐字相同时根本不会换名（没有 rename ⇒ 也就没有
# 「换到一半被打断」这个状态）。这里删掉副本里的一个文件 ——
# 同步会把它补回去，于是两份不同 ⇒ 触发换名。
rm -f "$proj/vendor/shellkit/VERSION"

# 受控中断：走共享的故障注入层 ——
# 第一次 rename（旧副本挪开、新的还没换上）落地后杀掉父进程，
# 与「两次 rename 之间被杀 / 断电」留下完全相同的磁盘状态。
#   fault_signal_kill recover after 1
# recover 这一档匹配的正是「换名落到 .shellkit-old / *.old」的那次 rename。

# CASE: vendor 切换在两次 rename 之间被杀
fault_reset
fault_signal_kill recover after 1
rc=0
fault_run "$TEST_ROOT/shellkit" vendor "$proj" >/dev/null 2>&1 || rc=$?
assert_ne "0" "$rc" "the interrupted vendor must not report success"
# 被杀后的状态：dest 不见了，.shellkit-old 是唯一完整的副本
assert_false test -e "$proj/vendor/shellkit"
assert_true test -f "$proj/vendor/.shellkit-old/lib/bootstrap.sh"
assert_true test -f "$proj/vendor/.shellkit-old/user-note.txt"

# CASE: 再跑一次必须先恢复旧副本，再完整重装；用户自加的文件要活下来
out=$(SHELLKIT_LOCK_DIR="$locks" "$TEST_ROOT/shellkit" vendor "$proj" 2>&1)
assert_contains "$out" "recovering the vendored library" "the recovery must say what it did"
assert_true test -f "$proj/vendor/shellkit/lib/bootstrap.sh"
assert_true test -f "$proj/vendor/shellkit/user-note.txt"
assert_false test -e "$proj/vendor/.shellkit-new"
assert_false test -e "$proj/vendor/.shellkit-old"

# CASE: install-self 的同一族洞（.old / .new 两个 rename）
# 先真装一次 —— 重装时才有「唯一完整的旧副本」可丢（全新安装没有旧副本，
# 被杀时 .old 里只有个空目录，测不到该测的东西）
prefix="$work/prefix"
SHELLKIT_LOCK_DIR="$locks" "$TEST_ROOT/shellkit" install-self --prefix "$prefix" >/dev/null 2>&1
assert_true test -f "$prefix/share/shellkit/lib/bootstrap.sh"
# 同理：装好的副本与源逐字相同时不会换名，删一个文件制造出差异
rm -f "$prefix/share/shellkit/VERSION"
fault_reset
fault_signal_kill recover after 1
rc=0
fault_run "$TEST_ROOT/shellkit" install-self --prefix "$prefix" >/dev/null 2>&1 || rc=$?
assert_ne "0" "$rc" "the interrupted install-self must not report success"
assert_false test -e "$prefix/share/shellkit"
assert_true test -f "$prefix/share/shellkit.old/lib/bootstrap.sh"
out=$(SHELLKIT_LOCK_DIR="$locks" "$TEST_ROOT/shellkit" install-self --prefix "$prefix" 2>&1)
assert_contains "$out" "recovering the installed copy" "the recovery must say what it did"
assert_true test -f "$prefix/share/shellkit/lib/bootstrap.sh"
assert_false test -e "$prefix/share/shellkit.old"
assert_false test -e "$prefix/share/shellkit.new"

# CASE: 并发互斥 —— 锁被别的进程占着时，写类操作拒绝，--check 只读不受影响
crc=$(printf '%s' "$(cd "$proj" && pwd -P)" | cksum)
crc=${crc%% *}
mkdir -p "$locks/shellkit-proj-$crc.lock"
printf '%s\n' "$$" >"$locks/shellkit-proj-$crc.lock/pid"
rc=0
out=$(SHELLKIT_LOCK_DIR="$locks" "$TEST_ROOT/shellkit" vendor "$proj" 2>&1) || rc=$?
assert_ne "0" "$rc" "vendor must refuse while the project lock is held"
assert_contains "$out" "another instance" "the refusal must name the cause"
rc=0
out=$(SHELLKIT_LOCK_DIR="$locks" "$TEST_ROOT/shellkit" upgrade "$proj" 2>&1) || rc=$?
assert_ne "0" "$rc" "upgrade must refuse while the project lock is held"
rc=0
out=$(SHELLKIT_LOCK_DIR="$locks" "$TEST_ROOT/shellkit" upgrade "$proj" --check 2>&1) || rc=$?
assert_eq "0" "$rc" "--check is read-only and must not need the lock"
# 释放后照常能干活
rm -rf "$locks/shellkit-proj-$crc.lock"
out=$(SHELLKIT_LOCK_DIR="$locks" "$TEST_ROOT/shellkit" vendor "$proj" 2>&1)
assert_contains "$out" "vendored library" "vendor must work again after the lock is released"

exit 0
