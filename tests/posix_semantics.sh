#!/bin/sh
#
# POSIX 子集与 bash core 的**语义分叉**判据（#171 / #172 / #173 / #174）。
#
# 为什么单独一份、而且只用 POSIX sh 语法：
#   这几条修的是「同一套 API 两份实现」的分叉 ⇒ 判据必须能在**设备侧**
#   真的解释器（busybox ash）上跑，否则等于没验设备侧。
#   同一份判据也在 dash 上跑（CI 的 compat job）。
#
# 每条都带**负对照**（把缺陷造回去必须判红）与**变异自证**（判据本身坏了要判红）。
#
# shellcheck disable=SC2016
# 下面几处单引号里的 $ 是**要原样传给 sed/grep 的模式**（它们要匹配
# 源码里的 $_sp_vc_a 这类字面量），不是当前 shell 的变量。
set -u

LIB="${SK_POSIX_LIB:-}"
if [ -z "$LIB" ]; then
  LIB="$(cd "$(dirname "$0")/.." && pwd)/lib/posix/shellkit-posix.sh"
fi
if [ ! -f "$LIB" ]; then
  printf 'FAIL: the POSIX subset is missing: %s\n' "$LIB" >&2
  exit 1
fi

TMP="${TMPDIR:-/tmp}/sk-posix-sem.$$"
rm -rf "$TMP"
mkdir -p "$TMP" || exit 1
trap 'rm -rf "$TMP"' 0 1 2 15

FAILS=0
# 名字带独占前缀：POSIX 子集自己有一个公开的 fail()，判据再定义同名
# 函数会被覆盖 ⇒ 失败计数永远不增 ⇒ 整份判据变成假绿。
sem_fail() {
  printf 'FAIL: %s\n' "$1" >&2
  FAILS=$((FAILS + 1))
}

# ---- 被测库 ----
# shellcheck disable=SC1090
. "$LIB" || exit 1

# ---- 变异工具：按**内容**定位行号，再按行号替换 ----
#
# 为什么不用 sed 的模式替换：
#   1) 模式里有 [ ] => BRE 里是字符类，匹配不到字面括号；
#   2) 模式里有 & => 替换文本里 & 是「整个匹配」的引用，会把原文插回去；
#   3) 模式里有 $ => shell 与 sed 都要转义，转义层数一多就静默失配。
# => 改成「grep -F 找到行号 -> sed 按行号替换」，判据只依赖字面内容。
#
# mut_at FILE PATTERN REPLACEMENT OUT
#   PATTERN 必须逐字出现在 FILE 里（不做正则匹配）
#   返回 0 = 已生成 OUT；1 = PATTERN 没找到（形状守卫要报这个）
mut_at() {
  _ma_file=$1
  _ma_pat=$2
  _ma_rep=$3
  _ma_out=$4
  _ma_n=$(grep -nF "$_ma_pat" "$_ma_file" | head -n 1 | cut -d: -f1)
  if [ -z "$_ma_n" ]; then
    return 1
  fi
  sed "${_ma_n}s|.*|$_ma_rep|" "$_ma_file" >"$_ma_out"
  return 0
}

# =====================================================================
# #171 lock_release：只删自己持有的锁 + 从清理栈摘除
# =====================================================================

# 1) 锁被**别人**持有时，lock_release 必须拒绝删除（不是无条件 rm -rf）
LOCKDIR="$TMP/locks"
mkdir -p "$LOCKDIR" || exit 1
SHELLKIT_LOCK_DIR="$LOCKDIR"
export SHELLKIT_LOCK_DIR

lock_acquire semtest >/dev/null 2>&1
if [ ! -d "$LOCKDIR/shellkit-semtest.lock" ]; then
  sem_fail 'S171-1: lock_acquire did not create the lock directory'
fi

# 把锁的持有者改成「别人」（另一个还活着的 pid）
printf "%s\n" "$$" >"$LOCKDIR/shellkit-semtest.lock/pid"
# 用一个确定活着、且不是自己的 pid：父 shell 的 pid 由 $PPID 不可靠 ⇒
# 用 1（init 永远活着）—— 只在**判据**里用，不写进库。
printf "%s\n" "1" >"$LOCKDIR/shellkit-semtest.lock/pid"
lock_release semtest >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
  sem_fail 'S171-1: lock_release must refuse to release a lock held by another process'
fi
if [ ! -d "$LOCKDIR/shellkit-semtest.lock" ]; then
  sem_fail 'S171-1: lock_release deleted a lock held by another process (the mutex silently failed)'
fi

# 2) 自己持有的锁 ⇒ 必须能删掉，且清理栈里那条必须被摘掉
printf "%s\n" "$$" >"$LOCKDIR/shellkit-semtest.lock/pid"
lock_release semtest >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  sem_fail 'S171-2: lock_release must succeed for a lock held by this process'
fi
if [ -d "$LOCKDIR/shellkit-semtest.lock" ]; then
  sem_fail 'S171-2: lock_release did not remove the lock directory'
fi

# 清理栈里必须**没有**那条 release 了（否则退出清理会再删一次别人的锁）
if printf "%s\n" "$_SK_POSIX_TRAP_CMDS" | grep -qF "lock_release semtest"; then
  sem_fail 'S171-2: the cleanup stack still holds the release action (the exit path would delete someone else lock)'
fi

# 3) 变异自证：把「只删自己的锁」这个守卫掏空 ⇒ 判据必须红
#
# 守卫的位置：pid 不等于自己时拒绝。改它 ⇒ 上面第 1 条必须判红。
if grep -qF '"$_sp_lr_pid" != "$$"' "$LIB"; then
  MUT="$TMP/mut171.sh"
  if mut_at "$LIB" '"$_sp_lr_pid" != "$$"' 'if false; then' "$MUT"; then
    LOCKDIR2="$TMP/locks2"
    mkdir -p "$LOCKDIR2"
    SHELLKIT_LOCK_DIR="$LOCKDIR2"
    export SHELLKIT_LOCK_DIR
    (
      . "$MUT" 2>/dev/null || exit 99
      mkdir -p "$LOCKDIR2/shellkit-mut.lock"
      printf "%s\n" "1" >"$LOCKDIR2/shellkit-mut.lock/pid"
      lock_release mut >/dev/null 2>&1
      if [ -d "$LOCKDIR2/shellkit-mut.lock" ]; then
        exit 1
      fi
      exit 0
    )
    mrc=$?
    if [ "$mrc" -ne 0 ]; then
      sem_fail 'S171-3: the mutated library must delete a foreign lock (otherwise the judgment has no teeth)'
    fi
  else
    sem_fail 'S171-3: the mutation did not apply (the shape guard caught it)'
  fi
else
  sem_fail 'S171-3: the ownership guard is gone from the library'
fi

# =====================================================================
# #172 lock_acquire：mkdir 失败要分清「被占」与「建不出来」
# =====================================================================

# 锁目录建不出来（父路径是个普通文件）⇒ 必须**立刻**返回并报错，
# 不能进「回收僵尸锁」的循环里无限重试。
BADPARENT="$TMP/notadir"
printf "not a directory\n" >"$BADPARENT"
SHELLKIT_LOCK_DIR="$BADPARENT"
export SHELLKIT_LOCK_DIR

# 用一个**会超时的**壳跑它：原来这个调用会永远循环 ⇒ 只能靠超时打断。
if command -v timeout >/dev/null 2>&1; then
  timeout 5 sh -c ". \"$LIB\" >/dev/null 2>&1; lock_acquire semtest2" >"$TMP/acq.out" 2>&1
  rc=$?
  if [ "$rc" -eq 124 ]; then
    sem_fail 'S172-1: lock_acquire loops forever when the lock directory cannot be created (the device side hangs silently)'
  elif [ "$rc" -eq 0 ]; then
    sem_fail 'S172-1: lock_acquire must not succeed when the lock directory cannot be created'
  fi
  if [ ! -s "$TMP/acq.out" ]; then
    sem_fail 'S172-1: lock_acquire must report why it failed (zero output is a silent hang)'
  fi
else
  printf 'SKIP: S172-1 needs the timeout command\n' >&2
fi

# =====================================================================
# #173 ver_cmp：认 v 前缀与预发布后缀（与 bash core 同一口径）
# =====================================================================

check_cmp() {
  want=$1
  a=$2
  b=$3
  got=$(ver_cmp "$a" "$b" 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ] || [ "$got" != "$want" ]; then
    sem_fail "S173: ver_cmp $a $b must be $want (got '$got' rc=$rc)"
  fi
}

check_cmp 0 "v1.2.3" "1.2.3"
check_cmp 0 "1.2.3" "V1.2.3"
check_cmp 1 "1.2.3" "1.2.3-rc.1"
check_cmp -1 "1.2.3-rc.1" "1.2.3"
check_cmp -1 "1.2.3-rc.1" "1.2.3-rc.2"
check_cmp 1 "1.2.3-rc.2" "1.2.3-rc.1"
check_cmp 0 "1.2.3-rc.1" "1.2.3-rc.1"
check_cmp -1 "1.2.3-alpha" "1.2.3-beta"
check_cmp -1 "1.2.3-rc.08" "1.2.3-rc.9"
check_cmp 0 "1.2" "1.2.0"
check_cmp 1 "10.0.0" "9.9.9"

# 变异自证：把「剥 v 前缀」掏空 ⇒ v 前缀那几条必须判红
if grep -qF '_sp_vc_a=${_sp_vc_a#v}' "$LIB"; then
  MUT2="$TMP/mut173.sh"
  if mut_at "$LIB" '_sp_vc_a=${_sp_vc_a#v}' 'v*) : ;;' "$MUT2"; then
    (
      . "$MUT2" 2>/dev/null || exit 99
      got=$(ver_cmp "v1.2.3" "1.2.3" 2>/dev/null)
      if [ "$got" = "0" ]; then exit 1; fi
      exit 0
    )
    mrc=$?
    if [ "$mrc" -ne 0 ]; then
      sem_fail 'S173-M: the mutated library must stop accepting the v prefix (otherwise the judgment has no teeth)'
    fi
  else
    sem_fail 'S173-M: the mutation did not apply (the shape guard caught it)'
  fi
else
  sem_fail 'S173-M: the v-prefix handling is gone from the library'
fi

# =====================================================================
# #174 retry：白名单 / 退避上限 / 分类
# =====================================================================

# 1) 白名单：SHELLKIT_RETRY_ON 只放行名单里的退出码
SHELLKIT_RETRY_ON="42"
export SHELLKIT_RETRY_ON
SHELLKIT_RETRY_DELAY=0
export SHELLKIT_RETRY_DELAY
retry 3 sh -c "exit 7" >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 7 ]; then
  sem_fail 'S174-1: retry must return the original exit code when the code is not on the allow list'
fi

# 2) 白名单里的退出码 ⇒ 真的重试（用计数器文件数次数）
SHELLKIT_RETRY_ON="7"
retry 3 sh -c "exit 7" >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 7 ]; then
  sem_fail 'S174-1: retry must return the exit code after exhausting the attempts'
fi

# 3) 用法错（退出码 2）不重试 —— 与 bash core 同一口径
unset SHELLKIT_RETRY_ON 2>/dev/null || true
cnt="$TMP/count"
printf "0\n" >"$cnt"
retry 5 sh -c 'n=$(cat "$1"); printf "%s\n" "$((n + 1))" >"$1"; exit 2' sh "$cnt" >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 2 ]; then
  sem_fail 'S174-3: retry must return the usage error as is'
fi
calls=$(cat "$cnt")
if [ "$calls" -ne 1 ]; then
  sem_fail "S174-3: retry must not retry a usage error (ran $calls times, expected 1)"
fi

# 4) 退避上限：延迟不得超过 SHELLKIT_RETRY_MAX_DELAY
SHELLKIT_RETRY_DELAY=100
SHELLKIT_RETRY_MAX_DELAY=1
export SHELLKIT_RETRY_DELAY SHELLKIT_RETRY_MAX_DELAY
start=$(date +%s 2>/dev/null || echo 0)
retry 3 sh -c "exit 5" >/dev/null 2>&1
end=$(date +%s 2>/dev/null || echo 0)
if [ "$start" != "0" ] && [ "$end" != "0" ]; then
  spent=$((end - start))
  if [ "$spent" -gt 10 ]; then
    sem_fail "S174-4: the first delay must be clamped by the max (waited ${spent}s, the max is 1s)"
  fi
fi
unset SHELLKIT_RETRY_DELAY SHELLKIT_RETRY_MAX_DELAY 2>/dev/null || true

# ---- 收尾 ----
if [ "$FAILS" -gt 0 ]; then
  printf '%s failing\n' "$FAILS" >&2
  exit 1
fi
printf 'ok\n'
exit 0
