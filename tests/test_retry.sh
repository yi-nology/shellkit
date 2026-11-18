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

# ---------------------------------------------------------------------------
# issue #22：SHELLKIT_RETRY_MAX_DELAY 以前只管后退之后的值，首次延迟按原值睡。
# 于是「上限 5 秒」配「初始 100 秒」时，第一次就睡 100 秒 —— 上限看着生效、实际没生效。
# ---------------------------------------------------------------------------
sd=$(tmpdir)
stub sleep --body "printf '%s\n' \"\$1\" >>'$sd/sleeps'"
cfail="$d/cfail"
_tryf() {
  printf 'x' >>"$cfail"
  return 1
}
SHELLKIT_RETRY_DELAY=100 SHELLKIT_RETRY_MAX_DELAY=5 assert_exit_code 1 retry 2 _tryf
assert_stub_called sleep 1
unstub sleep
assert_eq "5" "$(head -1 "$sd/sleeps")" "the first retry delay is clamped by SHELLKIT_RETRY_MAX_DELAY"

# ---------------------------------------------------------------------------
# issue #145：retry 必须区分「超时」与「失败」
#
# 处置方式完全不同：超时 = 链路抖 ⇒ 重试通常就好；失败 = 权限错/证书错 ⇒ 必须叫人。
# 压成同一个非零码，调用方就分不出「再试一次」与「得找人」。
# ---------------------------------------------------------------------------

# 分类口径：超时码默认 124（与 GNU timeout(1) 一致）
assert_eq "success" "$(retry_classify 0)" "a zero exit code is a success"
assert_eq "timeout" "$(retry_classify 124)" "the timeout code is classified as a timeout"
assert_eq "failure" "$(retry_classify 1)" "any other non-zero code is a failure"
assert_eq "failure" "$(retry_classify 2)" "a usage error is a failure, not a timeout"

# 分类函数的参数校验
assert_exit_code 2 retry_classify
assert_exit_code 2 retry_classify abc

# 超时码可配：换了口径，分类跟着换
assert_eq "timeout" "$(SHELLKIT_RETRY_TIMEOUT_CODE=99 retry_classify 99)" \
  "the timeout code is configurable"
assert_eq "failure" "$(SHELLKIT_RETRY_TIMEOUT_CODE=99 retry_classify 124)" \
  "the old timeout code is no longer a timeout once the convention changes"

# retry 跑完要留下「最后结果」：退出码 + 分类
_to() {
  return 124
}
rc=0
retry 2 _to || rc=$?
assert_eq "124" "$rc" "retry returns the command's exit code (124 = timeout)"
assert_eq "124" "$(retry_last_rc)" "retry_last_rc reports the last command's exit code"
assert_eq "timeout" "$(retry_last_class)" "retry_last_class reports a timeout"

_f() {
  return 1
}
rc=0
retry 2 _f || rc=$?
assert_eq "1" "$rc" "retry returns the command's exit code on failure"
assert_eq "failure" "$(retry_last_class)" "retry_last_class reports a failure"

retry 1 true
assert_eq "success" "$(retry_last_class)" "a successful retry is classified as a success"
assert_eq "0" "$(retry_last_rc)" "a successful retry leaves a zero exit code"

# 日志必须能区分：超时的重试提示与失败的重试提示不是同一句
_out=$(retry 2 _to 2>&1)
assert_contains "$_out" "attempt timed out, retrying" \
  "a timeout is reported as a timeout, not as a generic failure"
assert_not_contains "$_out" "attempt failed, retrying" \
  "the timeout log line does not reuse the failure wording"

_out=$(retry 2 _f 2>&1)
assert_contains "$_out" "attempt failed, retrying" \
  "a failure keeps the failure wording"
assert_not_contains "$_out" "attempt timed out, retrying" \
  "the failure log line does not claim a timeout"

_out=$(retry 1 _to 2>&1)
assert_contains "$_out" "giving up after retries (timed out)" \
  "giving up after a timeout says so"

_out=$(retry 1 _f 2>&1)
assert_contains "$_out" "giving up after retries" \
  "giving up after a failure still reports the plain wording"
assert_not_contains "$_out" "timed out" \
  "giving up after a failure does not claim a timeout"

# 超时要重试（链路抖 ⇒ 再试通常就好）；用法错不重试（参数错 ⇒ 重试没用）
_ct="$(tmpdir)/timeout-count"
_tc() {
  printf 'x' >>"$_ct"
  return 124
}
retry 3 _tc || true
assert_eq "3" "$(wc -c <"$_ct" | tr -d ' ')" "timeouts are retried"

# SHELLKIT_RETRY_ON 可以只放行超时：认证/权限类失败立即放弃
_cf="$(tmpdir)/fatal-count"
_fc() {
  printf 'x' >>"$_cf"
  return 1
}
SHELLKIT_RETRY_ON=124 retry 3 _fc || true
assert_eq "1" "$(wc -c <"$_cf" | tr -d ' ')" \
  "SHELLKIT_RETRY_ON=124 stops retrying a non-timeout failure"

exit 0
