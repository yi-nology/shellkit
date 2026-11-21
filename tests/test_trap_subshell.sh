#!/usr/bin/env bash
# trap_install 在子 shell 里**不得**替调用方执行它的 EXIT handler。
#
# 缺陷现场：调用方 `trap 'rm -rf "$work"' EXIT`，随后在**子 shell** 里调了任何
# 会走到 trap_install 的函数（lock_acquire / fs_tmp_init / proc_*）⇒ 子 shell
# 退出时把调用方的 work 目录删了 ⇒ 父进程后续写文件直接 "No such file or directory"。
#
# 只在 bash 5 复现：bash 3.2 在子 shell 里 `trap -p` 读到的不是 "trap -- " 开头的
# 完整形态 ⇒ 捕获根本不会发生。明说没跑，不许静默跳过（Linux CI 是 bash 5 ⇒ 真跑）。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"

d="$(tmpdir)"

if [ -z "${BASHPID:-}" ]; then
  printf 'SKIP: bash 3.2 不复现这条（子 shell 里 trap -p 读不到完整 handler）\n'
  exit 0
fi

# ------------------------------------------------------------------
# 1. 主断言：子 shell 里的 trap_install 不得提前执行调用方的 EXIT 清理
# ------------------------------------------------------------------
work="$d/work"
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT

(trap_install) >/dev/null 2>&1

if [ ! -d "$work" ]; then
  printf 'FAIL: 子 shell 里的 trap_install 提前执行了调用方的 EXIT 清理（work 目录被删）\n' >&2
  exit 1
fi

# ------------------------------------------------------------------
# 2. 变异自证：把守卫删掉 ⇒ 缺陷必须复现（否则这条断言没有判据能力）
# ------------------------------------------------------------------
# 变异：把「是否在子 shell」的判定改成永远说「不在」⇒ 守卫失效 ⇒ 缺陷复现。
# 挑这一行改而不是删守卫块：守卫块会随修复变长（加注释、加清状态），
# 按行数删就会删出半截代码 ⇒ 变异落到语法错误上，测的就不是那个缺陷了。
__start=$(grep -n -F '_sk_trap_in_subshell() {' "$TEST_ROOT/lib/core/trap.sh" | cut -d: -f1)
if [ -z "$__start" ]; then
  printf 'FAIL: 没找到 _sk_trap_in_subshell —— 变异没落到源码上，判据自己坏了\n' >&2
  exit 1
fi
__ret=$(awk -v s="$__start" 'NR>=s && NR<=s+9 && $0 ~ /^  return 0$/ {print NR; exit}' "$TEST_ROOT/lib/core/trap.sh")
if [ -z "$__ret" ]; then
  printf 'FAIL: 没找到 _sk_trap_in_subshell 的返回行 —— 变异没落到源码上，判据自己坏了\n' >&2
  exit 1
fi
awk -v r="$__ret" 'NR==r {sub(/return 0/, "return 1")} {print}' "$TEST_ROOT/lib/core/trap.sh" >"$d/trap_mutant.sh"
if cmp -s "$TEST_ROOT/lib/core/trap.sh" "$d/trap_mutant.sh"; then
  printf 'FAIL: 变异没改到任何东西 —— 判据自己坏了\n' >&2
  exit 1
fi
. "$d/trap_mutant.sh"

__out=$(
  work2="$d/work2"
  mkdir -p "$work2"
  trap 'rm -rf "$work2"' EXIT
  (trap_install) >/dev/null 2>&1
  if [ -d "$work2" ]; then printf 'survived'; else printf 'deleted'; fi
)
assert_eq "deleted" "$__out" "变异自证：删掉子 shell 守卫后，调用方的 EXIT 清理必须提前发生"

echo "OK: 子 shell 里的 trap_install 不再提前执行调用方的 EXIT 清理"
