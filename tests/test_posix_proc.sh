#!/usr/bin/env bash
#
# POSIX 子集的**进程层**判据（设备侧那一层：后台引导 / 整组停止 / 看门狗）。
#
# 判据本体在 tests/posix_smoke.sh —— 那是**一份 POSIX sh 脚本**，
# 所以同一份判据能在 dash 与 busybox ash 上原样跑（设备侧的真环境），
# 而不是「在 macOS 的 bash 上假装是 ash」。
#
# 这一份（bash）只做四件事：
#   1. 用真 POSIX shell 跑那份判据，要求它通过；
#   2. 本机有 busybox 就再跑一遍 ash（设备侧真正的解释器）；
#   3. 能力清单的**结构事实**：这四个函数标 yes，且第三列写清了限制
#      （写「-」等于没写：设备侧的人无从知道这一条在 ash 上会怎么降级）；
#   4. 判据自己有承重：把库的僵尸判定改坏 ⇒ 判据必须变红。
#
# 为什么要单独一份（而不是并进 tests/test_posix.sh）：
#   那份用 bash 驱动（_posix '...'），只能在本机的 dash 上跑；
#   CI 的 "posix subset on busybox ash" job 要跑的是**同一个文件**——
#   两处判据各写一遍，迟早会漂成两套不同的东西。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

SMOKE="$TEST_ROOT/tests/posix_smoke.sh"
POSIX_LIB="$TEST_ROOT/lib/posix/shellkit-posix.sh"
CAP_FILE="$TEST_ROOT/lib/posix/capabilities.tsv"

# 真 POSIX shell：优先 dash（最接近 POSIX），没有就退到 sh
POSIX_SH=""
if command -v dash >/dev/null 2>&1; then
  POSIX_SH=dash
elif [ -x /bin/dash ]; then
  POSIX_SH=/bin/dash
else
  POSIX_SH="sh"
fi

# ---- CASE: 判据文件在 ----
assert_true test -f "$SMOKE"

# ---- CASE: 真 POSIX shell 下判据全过 ----
out=$("$POSIX_SH" "$SMOKE" 2>&1)
rc=$?
if [ "$rc" != "0" ]; then
  _fail "the POSIX smoke judgment must pass under $POSIX_SH (exit $rc): $out"
fi
assert_contains "$out" "ok" "the POSIX smoke judgment must report ok"

# ---- CASE: busybox ash 下同一份判据也过（设备侧的真解释器）----
#   没有 busybox 就明说没跑，不静默跳过。
if command -v busybox >/dev/null 2>&1; then
  out=$(busybox ash "$SMOKE" 2>&1)
  rc=$?
  if [ "$rc" != "0" ]; then
    _fail "the POSIX smoke judgment must pass under busybox ash (exit $rc): $out"
  fi
else
  printf 'NA: busybox is not installed, the ash run is skipped (CI runs it)
'
fi

# ---- CASE: 能力清单说「有」，且写清了限制 ----
cap_line() {
  grep -m1 "^$1	" "$CAP_FILE" 2>/dev/null || true
}
for fn in proc_start proc_stop proc_is_running proc_watchdog; do
  line=$(cap_line "$fn")
  assert_contains "$line" "yes" "$fn must be listed as available in the POSIX subset"
  case "$line" in
    *"	-" | "")
      _fail "the capability list must say what $fn looks like in the POSIX subset (a bare yes is not enough)"
      ;;
  esac
  assert_contains "$line" "进程组" "the capability list must spell out the process-group limitation of $fn"
done

# ---- CASE: POSIX 子集真的定义了这四个函数（与主库同名）----
for fn in proc_start proc_stop proc_is_running proc_watchdog; do
  if ! grep -q "^$fn() {" "$POSIX_LIB"; then
    _fail "the POSIX subset must define $fn (same name as the main library)"
  fi
done

# ---- CASE: 判据有承重 —— 把库的僵尸判定改坏，判据必须变红 ----
d=$(tmpdir)
mutant="$d/mutant.sh"
cp "$POSIX_LIB" "$mutant" || _fail "cannot copy the POSIX subset"
sed 's/Z | X) return 0 ;;/Z | X) return 1 ;;/' "$mutant" >"$mutant.new" 2>/dev/null ||
  _fail "cannot build the mutant"
mv "$mutant.new" "$mutant" || _fail "cannot replace the mutant"
# 形状守卫：变异必须真的落到源码上（否则这一节是假通过）
if ! grep -q 'Z | X) return 1 ;;' "$mutant"; then
  _fail "the mutation did not apply (the shape guard caught it)"
fi
out=$(SK_POSIX_LIB="$mutant" "$POSIX_SH" "$SMOKE" 2>&1)
rc=$?
assert_ne "0" "$rc" "the POSIX judgment must go red when the zombie branch is broken"
assert_contains "$out" "FAIL:" "the broken judgment must name the failure"

printf 'ok
'
