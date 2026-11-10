#!/usr/bin/env bash
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

work=$(tmpdir)
proj="$work/app"

"$TEST_ROOT/shellkit" new "$proj" >/dev/null 2>&1 || _fail "shellkit new failed"

# 新生成的工程自带同步好的库
assert_exit_code 0 "$TEST_ROOT/shellkit" vendor "$proj" --check

# 库被改动后 --check 必须判红（5 = SK_VERIFY）
printf '# drift\n' >>"$proj/vendor/shellkit/lib/core/log.sh"
assert_exit_code 5 "$TEST_ROOT/shellkit" vendor "$proj" --check

# 同步回去，并把改动冲掉
assert_exit_code 0 "$TEST_ROOT/shellkit" vendor "$proj"
assert_exit_code 0 "$TEST_ROOT/shellkit" vendor "$proj" --check
if grep -q 'drift' "$proj/vendor/shellkit/lib/core/log.sh"; then
  _fail "vendor 同步没有覆盖掉被改动的副本"
fi
assert_eq "$(cat "$TEST_ROOT/VERSION")" "$(cat "$proj/vendor/shellkit/VERSION")" "VERSION is synced"

# 不覆盖"看起来不是 shellkit"的同名目录
other="$work/other"
mkdir -p "$other/vendor/shellkit"
assert_exit_code 3 "$TEST_ROOT/shellkit" vendor "$other"

# 参数校验
assert_exit_code 3 "$TEST_ROOT/shellkit" vendor "$work/does-not-exist"
assert_exit_code 2 "$TEST_ROOT/shellkit" vendor

# 同步过去的库能被直接 source
got=$(
  . "$proj/vendor/shellkit/lib/bootstrap.sh"
  printf '%s' "$SK_VERSION"
)
assert_eq "$(cat "$TEST_ROOT/VERSION")" "$got" "vendored bootstrap reports the synced version"

# ---- vendor 出来的副本必须自带「管它的工具」 ----
#
# 工程被 vendor 到别的机器上时，PATH 上不一定有 shellkit。如果副本里只有库，
# 工程就永远升不了级 —— 而「升级」正是 vendor 这套机制存在的理由。
if [ ! -f "$proj/vendor/shellkit/shellkit" ]; then
  _fail "the vendored copy carries the CLI"
fi
if [ ! -d "$proj/vendor/shellkit/templates" ]; then
  _fail "the vendored copy carries the templates"
fi

# 自带的 CLI 真能跑，而且报的是副本自己的版本
vver=$(bash "$proj/vendor/shellkit/shellkit" --version 2>/dev/null || true)
assert_eq "$(cat "$TEST_ROOT/VERSION")" "$vver" "the vendored CLI runs and reports the synced version"

# 自带的 CLI 能把工程升级（离线：不依赖 PATH 上的 shellkit）
assert_exit_code 0 bash "$proj/vendor/shellkit/shellkit" upgrade "$proj"

# CLI 与模板漂移也要被 --check 抓到
printf '# drift\n' >>"$proj/vendor/shellkit/shellkit"
assert_exit_code 5 "$TEST_ROOT/shellkit" vendor "$proj" --check
assert_exit_code 0 "$TEST_ROOT/shellkit" vendor "$proj"
assert_exit_code 0 "$TEST_ROOT/shellkit" vendor "$proj" --check

# 用工程自带的副本同步本工程（README 记载的离线升级用法）：目标就是运行源，
# 绝不允许先删后拷 —— 那会把 vendor/shellkit/{lib,locale,templates} 删空、
# 工程入口当场报废（issue #30）。--check 绿的时候，真正的同步也必须绿。
assert_exit_code 0 bash "$proj/vendor/shellkit/shellkit" vendor "$proj" --check
assert_exit_code 0 bash "$proj/vendor/shellkit/shellkit" vendor "$proj"
if [ ! -f "$proj/vendor/shellkit/lib/bootstrap.sh" ]; then
  _fail "self-sync keeps the vendored lib intact"
fi
assert_eq "$(cat "$TEST_ROOT/VERSION")" "$(cat "$proj/vendor/shellkit/VERSION")" \
  "self-sync still lands the right version"
assert_exit_code 0 bash "$proj/bin/app" --version
assert_exit_code 0 "$TEST_ROOT/shellkit" vendor "$proj" --check
