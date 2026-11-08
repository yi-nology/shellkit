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
