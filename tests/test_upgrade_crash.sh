#!/usr/bin/env bash
# 升级中途被 SIGKILL 之后的恢复。
#
# 评审 P0：升级是「换文件」+「改清单」两件事。崩在中间就留下
# 「文件已是新版、清单还记着旧指纹」的状态 —— 下次升级把这些文件当成
# 「用户改过」，从此再也拿不到模板更新（冻结）。
#
# 升级日志（write-ahead journal）就是为这个窗口写的：动第一个文件之前把
# 「这些文件该换成什么指纹」落盘，重跑时据此把基线推进到正确值。
#
# 受控中断的做法：mv 替身数到第 N 次「落到工程文件上」的 rename 就 kill -9
# 掉父进程 —— 与「rename 已成功、进程尚未来得及提交清单」的磁盘状态完全一样。
# N 从 1 走到最后一个文件：每次崩完都必须能恢复，且恢复后没有任何文件被冻结。
#
# TEST_TIMEOUT: 900 —— 每个崩溃点都要跑三次真实升级（崩 / 恢复 / 复验），
# 一次升级含模板渲染与 vendor 同步，几分钟是正常的。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fault.sh"

work=$(tmpdir)
locks="$work/locks"
mkdir -p "$locks"
export SHELLKIT_LOCK_DIR="$locks"

# ---- 改过的模板：让升级真的有事可做 ----
tpl="$work/tpl"
cp -R "$TEST_ROOT/templates" "$tpl"
for rel in README.md AGENTS.md Makefile .shellcheckrc lib/app.sh tests/test_helper.sh tests/run.sh bin/__NAME__; do
  printf '\n# crash-test marker\n' >>"$tpl/$rel"
done

# ---- 受控中断：走共享的故障注入层 ----
#
# 数到第 N 次「落到工程文件上」的 rename 就杀掉父进程 —— 与「rename 已成功、
# 进程尚未来得及提交清单」的磁盘状态完全一样。
# 替身怎么造由 tests/lib/fault.sh 负责（这里不再各写各的）：
#   fault_scope      哪个目录算「工程目录」（rename 阶段判「工程自己的文件」）
#   fault_signal_kill rename after N  数到第 N 次换工程文件时杀掉父进程

# file_sum FILE —— 文件的 sha256
file_sum() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    openssl dgst -sha256 "$1" | awk '{print $NF}'
  fi
}

# manifest_sum PROJECT REL —— 清单里记的基线
manifest_sum() {
  awk -v rel="$2" '$1 == "@file" && $2 == rel { print $3; exit }' "$1/.shellkit-manifest"
}

owned="bin/tool lib/app.sh README.md AGENTS.md Makefile .shellcheckrc tests/test_helper.sh tests/run.sh"

# ---- 基线工程 ----
base="$work/base"
"$TEST_ROOT/shellkit" new "$base" --name tool --cmd run --yes >/dev/null 2>&1
assert_true test -f "$base/.shellkit-manifest"

n_total=0
for rel in $owned; do
  if [ -f "$base/$rel" ]; then
    n_total=$((n_total + 1))
  fi
done
assert_eq "8" "$n_total" "the project must own all eight template files"

for n in 1 2 3 4 5 6 7 8; do
  proj="$work/p$n"
  cp -R "$base" "$proj"

  # ---- 崩在第 n 个文件提交之后 ----
  fault_reset
  fault_scope "$proj"
  fault_signal_kill rename after "$n"
  rc=0
  fault_run "$TEST_ROOT/shellkit" upgrade "$proj" --template "$tpl" \
    >"$work/crash.$n.log" 2>&1 || rc=$?
  assert_ne "0" "$rc" "the interrupted upgrade must not report success (n=$n)"

  # 升级日志必须已经落盘：没有它就没有恢复的依据
  assert_true test -f "$proj/.shellkit-upgrade-journal"

  # 前 n 个文件已经是新版、清单还记着旧指纹 —— 这正是要恢复的状态
  ahead=0
  for rel in $owned; do
    want=$(file_sum "$proj/$rel")
    got=$(manifest_sum "$proj" "$rel")
    if [ "$want" != "$got" ]; then
      ahead=$((ahead + 1))
    fi
  done
  assert_eq "$n" "$ahead" "the crash must leave exactly $n file(s) ahead of the manifest (n=$n)"

  # ---- 重跑：必须把基线推进到正确值 ----
  fault_reset
  out=$(fault_run "$TEST_ROOT/shellkit" upgrade "$proj" --template "$tpl" 2>&1)
  assert_contains "$out" "upgrade finished" "the recovery upgrade must finish (n=$n)"
  assert_false test -e "$proj/.shellkit-upgrade-journal"

  for rel in $owned; do
    want=$(file_sum "$proj/$rel")
    got=$(manifest_sum "$proj" "$rel")
    assert_eq "$want" "$got" "the manifest baseline must match the file on disk after the recovery: $rel (n=$n)"
  done

  # ---- 再跑一次：没有任何文件被冻结 ----
  out=$(fault_run "$TEST_ROOT/shellkit" upgrade "$proj" --template "$tpl" 2>&1)
  assert_contains "$out" "0 updated, 0 added, 0 left alone" "no file may stay frozen after the recovery (n=$n)"
done

exit 0
