#!/usr/bin/env bash
# doctor 的三类检查：环境、库完整性、vendor 漂移。
# 全部离线：只跑本地 CLI，不碰网络，也不往仓库里写东西。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

# 固定成英文输出，断言才能写死文案
run_doctor() {
  env -u LANGUAGE LC_ALL=C "$@"
}

# 把 CLI 连同它自带的库复制一份，用来造「库不完整」的现场
copy_cli() {
  local __dest=$1
  mkdir -p "$__dest" || return 1
  cp -R "$TEST_ROOT/lib" "$__dest/lib" || return 1
  cp -R "$TEST_ROOT/locale" "$__dest/locale" || return 1
  cp "$TEST_ROOT/VERSION" "$__dest/VERSION" || return 1
  cp "$TEST_ROOT/shellkit" "$__dest/shellkit" || return 1
  chmod 755 "$__dest/shellkit" || return 1
  return 0
}

work=$(tmpdir)

# CASE: 环境正常时三类检查全过，退出 0
out=$(run_doctor bash "$TEST_ROOT/shellkit" doctor 2>&1) && rc=0 || rc=$?
assert_eq 0 "$rc" "doctor exits 0 on a healthy library"
assert_contains "$out" "environment check" "the environment section is printed"
assert_contains "$out" "library integrity" "the library integrity section is printed"
assert_contains "$out" "vendor check" "the vendor section is printed"

# CASE: 模块文件缺失 —— 退出 5，且点名少了哪个模块
broken="$work/broken"
copy_cli "$broken" || _fail "cannot copy the CLI"
mv "$broken/lib/core/http.sh" "$broken/http.sh.moved"
out=$(run_doctor bash "$broken/shellkit" doctor 2>&1) && rc=0 || rc=$?
assert_eq 5 "$rc" "a missing module file is a verification failure"
assert_contains "$out" "http" "the missing module is named"

# CASE: 模块文件是空的 —— 退出 5
empty="$work/empty"
copy_cli "$empty" || _fail "cannot copy the CLI"
: >"$empty/lib/core/retry.sh"
out=$(run_doctor bash "$empty/shellkit" doctor 2>&1) && rc=0 || rc=$?
assert_eq 5 "$rc" "an empty module file is a verification failure"
assert_contains "$out" "retry" "the empty module is named"

# CASE: 模块文件语法坏了 —— 退出 5
badsyn="$work/bad-syntax"
copy_cli "$badsyn" || _fail "cannot copy the CLI"
printf 'if then fi\n' >"$badsyn/lib/core/lock.sh"
out=$(run_doctor bash "$badsyn/shellkit" doctor 2>&1) && rc=0 || rc=$?
assert_eq 5 "$rc" "a broken module file is a verification failure"
assert_contains "$out" "lock" "the broken module is named"

# CASE: vendor 与 CLI 一致 —— 退出 0
proj="$work/proj"
mkdir -p "$proj"
"$TEST_ROOT/shellkit" vendor "$proj" >/dev/null 2>&1 || _fail "vendor failed"
out=$(run_doctor bash "$TEST_ROOT/shellkit" doctor --dir "$proj" 2>&1) && rc=0 || rc=$?
assert_eq 0 "$rc" "an in-sync vendor copy passes"

# CASE: vendor 漂移 —— 退出 5，且点名漂移的文件
printf '# drift\n' >>"$proj/vendor/shellkit/lib/core/log.sh"
out=$(run_doctor bash "$TEST_ROOT/shellkit" doctor --dir "$proj" 2>&1) && rc=0 || rc=$?
assert_eq 5 "$rc" "a drifted vendor copy is a verification failure"
assert_contains "$out" "lib/core/log.sh" "the drifted file is named"

# CASE: 不用 --dir 时看当前目录里的 vendor
out=$(cd "$proj" && run_doctor bash "$TEST_ROOT/shellkit" doctor 2>&1) && rc=0 || rc=$?
assert_eq 5 "$rc" "the current directory is checked for a vendor copy"
assert_contains "$out" "lib/core/log.sh" "the drifted file is named"

# CASE: vendor 路径不是目录 —— 退出 5
notdir="$work/notdir"
mkdir -p "$notdir/vendor"
: >"$notdir/vendor/shellkit"
out=$(run_doctor bash "$TEST_ROOT/shellkit" doctor --dir "$notdir" 2>&1) && rc=0 || rc=$?
assert_eq 5 "$rc" "a vendor path that is not a directory is a verification failure"

# CASE: 目录里没有 vendor —— 退出 0
out=$(run_doctor bash "$TEST_ROOT/shellkit" doctor --dir "$work" 2>&1) && rc=0 || rc=$?
assert_eq 0 "$rc" "a directory without a vendor copy passes"

# CASE: 用法错 —— 退出 2
out=$(run_doctor bash "$TEST_ROOT/shellkit" doctor --bogus 2>&1) && rc=0 || rc=$?
assert_eq 2 "$rc" "an unknown option is a usage error"
out=$(run_doctor bash "$TEST_ROOT/shellkit" doctor --dir 2>&1) && rc=0 || rc=$?
assert_eq 2 "$rc" "an option without a value is a usage error"

# CASE: SHELLKIT_MODULES 是「直接用库」的按需加载开关，不该影响 CLI ——
# 泄漏进来时 os 模块没加载，doctor 把 command not found 伪装成「缺工具」。
# 判据：设与不设该变量，doctor 的输出必须一字不差（issue #32）。
plain_rc=0
plain=$(run_doctor bash "$TEST_ROOT/shellkit" doctor --dir "$work" 2>&1) || plain_rc=$?
limited_rc=0
limited=$(run_doctor env SHELLKIT_MODULES="cli log fs" bash "$TEST_ROOT/shellkit" doctor --dir "$work" 2>&1) || limited_rc=$?
assert_eq "$plain_rc" "$limited_rc" "SHELLKIT_MODULES must not change doctor's exit code"
assert_not_contains "$limited" "command not found" "SHELLKIT_MODULES must not leak into the CLI"
assert_eq "$plain" "$limited" "SHELLKIT_MODULES must not change doctor's output"
