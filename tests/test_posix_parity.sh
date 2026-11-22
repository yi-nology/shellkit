#!/usr/bin/env bash
# POSIX 子集与 bash core 的**差分对拍**门禁。
#
# 为什么要它：v1.4.1 那轮对拍只查了 4 个函数（lock ×2 / ver_cmp / retry），
# 就挖出 4 条真分叉（含一条静默失效）。剩下二十来个同名函数从没对拍过 ——
# 「同名不同义」的缺陷在设备侧是静默的：同一份调用在两边退出码不同、
# 消息不同、清理命令丢参数，而现场装不了 shellkit 补救。
#
# 三层，互相独立：
#   1. **差分**：同一份调用在两边跑，退出码 + stdout + stderr 必须逐字一致。
#      探针在 tests/posix_parity.sh（纯 POSIX sh，dash / busybox ash 上也能跑）。
#   2. **绝对判据**：每个用例的退出码必须落在钉死的期望表里 ——
#      否则「两边一起漂」也会绿。
#   3. **变异自证**：把 POSIX 侧改坏（消息丢参数 / 退出码当消息用）⇒
#      门禁必须判红。判据自己坏了要能被发现。
#
# 外加一条**解释器对拍**：POSIX 侧在 dash / busybox ash 上跑，结果必须与
# POSIX sh 一致（设备侧用的就是那两个解释器）。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

ROOT="$TEST_ROOT"
PROBE="$ROOT/tests/posix_parity.sh"
POSIX_LIB="$ROOT/lib/posix/shellkit-posix.sh"
d="$(tmpdir)"

if [ ! -f "$PROBE" ]; then
  printf 'FAIL: 对拍探针不存在: %s\n' "$PROBE" >&2
  exit 1
fi

# ------------------------------------------------------------------
# 绝对期望表：用例名 <TAB> 期望退出码
# ------------------------------------------------------------------
cat >"$d/expected.tsv" <<'PARITY_EOF'
die_code	3
die_msg_only	2
die_code_zero	0
fail_code	3
fail_msg_only	2
fail_noargs	2
log_info_multi	0
log_ok	0
log_warn	0
log_error	0
log_error_errmsg	0
log_section	0
status_emit_human	0
status_emit_escape	0
status_emit_noargs	0
status_emit_machine	0
status_state_valid_ok	0
status_state_valid_bad	1
status_version_machine	0
trap_push_noargs	2
trap_push_args	0
trap_push_order	0
fs_ensure_dir_noargs	2
fs_ensure_dir_ok	0
net_sha256_missing	0
net_verify_empty	5
net_verify_missing	5
conf_get_any_one_arg	0
conf_get_any_bad_key	2
os_name_ok	0
os_arch_ok	0
os_is_root_as_root	0
os_is_root_as_user	0
os_has_cmd_present	0
os_has_cmd_missing	1
os_has_cmd_noargs	2
require_cmd_present	0
require_cmd_missing	3
require_cmd_noargs	2
PARITY_EOF

# ------------------------------------------------------------------
# 1. 两侧各跑一次
# ------------------------------------------------------------------
if ! SK_PARITY_SIDE=bash bash "$PROBE" >"$d/bash.txt" 2>"$d/bash.err"; then
  printf 'FAIL: bash 一侧跑挂了：\n' >&2
  cat "$d/bash.err" >&2
  exit 1
fi
if ! sh "$PROBE" >"$d/posix.txt" 2>"$d/posix.err"; then
  printf 'FAIL: POSIX 一侧跑挂了：\n' >&2
  cat "$d/posix.err" >&2
  exit 1
fi

# ------------------------------------------------------------------
# 2. 差分：两边必须逐字一致
# ------------------------------------------------------------------
if ! diff -u "$d/bash.txt" "$d/posix.txt" >"$d/diff.txt" 2>&1; then
  printf 'FAIL: POSIX 子集与 bash core 的行为不一致（同名不同义）：\n' >&2
  cat "$d/diff.txt" >&2
  exit 1
fi

# ------------------------------------------------------------------
# 3. 绝对期望表：退出码必须对得上，且用例一个都不能少
# ------------------------------------------------------------------
__exp_lines=$(grep -c '[^[:space:]]' "$d/expected.tsv")
__got_lines=$(grep -c '[^[:space:]]' "$d/bash.txt")
if [ "$__exp_lines" != "$__got_lines" ]; then
  printf 'FAIL: 用例数不对：期望 %s 个，实得 %s 个\n' "$__exp_lines" "$__got_lines" >&2
  exit 1
fi
for __side in bash posix; do
  if ! awk -F'\t' '
    NR==FNR { e[$1]=$2; next }
    {
      if (!($1 in e)) { printf "用例没登记: %s\n", $1 > "/dev/stderr"; bad=1 }
      else if ($2 != e[$1]) { printf "退出码不对: %s 期望 %s 实得 %s\n", $1, e[$1], $2 > "/dev/stderr"; bad=1 }
    }
    END { exit bad ? 1 : 0 }
  ' "$d/expected.tsv" "$d/$__side.txt"; then
    printf 'FAIL: %s 一侧的退出码与期望表对不上\n' "$__side" >&2
    exit 1
  fi
done

# ------------------------------------------------------------------
# 4. 变异自证：把 POSIX 侧改坏 ⇒ 差分必须出现
# ------------------------------------------------------------------
# 变异一：log_info 只收第一个参数（多参数消息的后半截被丢）
sed 's|_sk_posix_log INFO "\$\*"|_sk_posix_log INFO "${1:-}"|' "$POSIX_LIB" >"$d/mutant1.sh"
if cmp -s "$POSIX_LIB" "$d/mutant1.sh"; then
  printf 'FAIL: 变异一没落到源码上（log_info 的参数收集没变）—— 判据自己坏了\n' >&2
  exit 1
fi
SK_POSIX_LIB="$d/mutant1.sh" sh "$PROBE" >"$d/mutant1.txt" 2>/dev/null
if diff -q "$d/bash.txt" "$d/mutant1.txt" >/dev/null 2>&1; then
  printf 'FAIL: 变异一（log_info 丢参数）没被差分抓到 —— 这道门禁没有判据能力\n' >&2
  exit 1
fi

# 变异二：die 把「消息」当退出码用（原来的参数序）
sed 's|^  _sp_die_code=${1:-}$|  _sp_die_code=${2:-1}|' "$POSIX_LIB" >"$d/mutant2.sh"
if cmp -s "$POSIX_LIB" "$d/mutant2.sh"; then
  printf 'FAIL: 变异二没落到源码上（die 的退出码取值没变）—— 判据自己坏了\n' >&2
  exit 1
fi
SK_POSIX_LIB="$d/mutant2.sh" sh "$PROBE" >"$d/mutant2.txt" 2>/dev/null
if diff -q "$d/bash.txt" "$d/mutant2.txt" >/dev/null 2>&1; then
  printf 'FAIL: 变异二（die 参数序错乱）没被差分抓到 —— 这道门禁没有判据能力\n' >&2
  exit 1
fi

# ------------------------------------------------------------------
# 5. 解释器对拍：POSIX 侧在 dash / busybox ash 上必须与 sh 一致
# ------------------------------------------------------------------
for __sh in dash busybox; do
  if ! command -v "$__sh" >/dev/null 2>&1; then
    continue
  fi
  if [ "$__sh" = "busybox" ]; then
    if ! busybox ash "$PROBE" >"$d/$__sh.txt" 2>/dev/null; then
      printf 'FAIL: busybox ash 一侧跑挂了\n' >&2
      exit 1
    fi
  else
    if ! "$__sh" "$PROBE" >"$d/$__sh.txt" 2>/dev/null; then
      printf 'FAIL: %s 一侧跑挂了\n' "$__sh" >&2
      exit 1
    fi
  fi
  if ! diff -u "$d/posix.txt" "$d/$__sh.txt" >"$d/diff.$__sh.txt" 2>&1; then
    printf 'FAIL: POSIX 侧在 %s 上的行为与 sh 不一致：\n' "$__sh" >&2
    cat "$d/diff.$__sh.txt" >&2
    exit 1
  fi
done

echo "OK: POSIX 子集与 bash core 的 39 个用例逐字一致"
