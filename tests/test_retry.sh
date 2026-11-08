#!/usr/bin/env bash
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"

export SHELLKIT_RETRY_DELAY=0
d=$(tmpdir)

# 成功一次即返回
assert_true retry 3 true
assert_eq "out" "$(retry 3 echo out)" "stdout passes through"

# 失败到用尽次数，返回最后一次的退出码
c1="$d/c1"
_try1() {
  printf 'x' >>"$c1"
  return 1
}
assert_exit_code 1 retry 3 _try1
assert_eq "3" "$(wc -c <"$c1" | tr -d ' ')" "retries the full count"

# SK_USAGE 默认不重试
c2="$d/c2"
_try2() {
  printf 'x' >>"$c2"
  return 2
}
assert_exit_code 2 retry 3 _try2
assert_eq "1" "$(wc -c <"$c2" | tr -d ' ')" "usage errors are not retried"

# SK_VERIFY 默认不重试
c3="$d/c3"
_try3() {
  printf 'x' >>"$c3"
  return 5
}
assert_exit_code 5 retry 3 _try3
assert_eq "1" "$(wc -c <"$c3" | tr -d ' ')" "verify errors are not retried"

# SHELLKIT_RETRY_ON 显式指定后，2 也可以重试
c4="$d/c4"
_try4() {
  printf 'x' >>"$c4"
  return 2
}
export SHELLKIT_RETRY_ON=2
assert_exit_code 2 retry 2 _try4
assert_eq "2" "$(wc -c <"$c4" | tr -d ' ')" "SHELLKIT_RETRY_ON overrides the default filter"
unset SHELLKIT_RETRY_ON

# 参数校验
assert_exit_code 2 retry 0 echo hi
assert_exit_code 2 retry abc echo hi
assert_exit_code 2 retry
