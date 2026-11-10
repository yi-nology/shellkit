#!/usr/bin/env bash
# 切换中途被杀的恢复：两次 rename 之间死掉时，唯一完整的旧副本不许丢。
# （评审 P0：旧实现在「换到一半被打断」后，下次运行会 rm -rf 掉唯一的好副本）
# 受控中断的做法：mv 替身执行完第一次 rename（dest→old）就 kill -9 掉父进程 ——
# 与「两次 rename 之间被 SIGKILL / 断电」留下完全相同的磁盘状态。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

work=$(tmpdir)
locks="$work/locks"
mkdir -p "$locks"
proj="$work/app"
"$TEST_ROOT/shellkit" new "$proj" --cmd run --yes >/dev/null 2>&1
# vendor 里放一个用户自己加的文件：恢复与重装都必须把它保住
printf 'MINE\n' >"$proj/vendor/shellkit/user-note.txt"

# mv 替身：第一次 rename 落地后杀掉父进程（== 两个 rename 之间被杀）
shim="$work/shim"
mkdir -p "$shim"
cat >"$shim/mv" <<'EOF'
#!/bin/sh
case "$2" in
  */.shellkit-old | *.old)
    /bin/mv "$@" || exit $?
    kill -9 "$PPID"
    exit 1
    ;;
esac
exec /bin/mv "$@"
EOF
chmod +x "$shim/mv"

# CASE: vendor 切换在两次 rename 之间被杀
rc=0
PATH="$shim:$PATH" SHELLKIT_LOCK_DIR="$locks" "$TEST_ROOT/shellkit" vendor "$proj" >/dev/null 2>&1 || rc=$?
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
rc=0
PATH="$shim:$PATH" SHELLKIT_LOCK_DIR="$locks" "$TEST_ROOT/shellkit" install-self --prefix "$prefix" >/dev/null 2>&1 || rc=$?
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
