#!/usr/bin/env bash
# 命令行脱敏的回归。
#
# 守的是两件事：
#   ① 敏感的东西不能进日志（口令、令牌、请求头）
#   ② **不该脱敏的别脱敏** —— 过度脱敏会让日志失去排障价值，那也是一种回归。
#
# 命令失败时会把命令行写进日志，所以「让命令失败」就是这里观察日志的入口。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"

# failed_line —— 让命令失败，拿到日志里那一行命令行
failed_line() {
  local __out=""
  __out=$(run --no-die "$@" 2>&1) || true
  printf '%s' "$__out"
}

# ---------------------------------------------------------------- 启发式
# 请求头：头名像敏感字段就把值遮掉
out=$(failed_line false -H 'X-Api-Key: abc123')
assert_not_contains "$out" "abc123" "an api key header must never reach the log"
assert_contains "$out" "X-Api-Key" "the header name itself should stay readable"

out=$(failed_line false -H 'Cookie: sid=abc123')
assert_not_contains "$out" "abc123" "a cookie header must never reach the log"

out=$(failed_line false -H 'Set-Cookie: sid=abc123')
assert_not_contains "$out" "abc123" "a set-cookie header must never reach the log"

out=$(failed_line false -H 'Proxy-Authorization: Basic abc123')
assert_not_contains "$out" "abc123" "a proxy-authorization header must never reach the log"

# 短选项：curl 的 -u 是 user:password
out=$(failed_line false -u user:pass123)
assert_not_contains "$out" "pass123" "the -u value must never reach the log"

out=$(failed_line false -uuser:pass123)
assert_not_contains "$out" "pass123" "an attached -u value must never reach the log"

# 长选项 --user
out=$(failed_line false --user user:pass123)
assert_not_contains "$out" "pass123" "the --user value must never reach the log"

# 值里夹着敏感键名（--data password=xxx）
out=$(failed_line false --data 'password=xxx123')
assert_not_contains "$out" "xxx123" "a sensitive key inside a value must never reach the log"

# --token 早就该遮
out=$(failed_line false --token abc123)
assert_not_contains "$out" "abc123" "a token value must never reach the log"

# ---------------------------------------------------------------- 显式声明
# --secret-arg N：第 N 个参数（命令名不算）必遮
out=$(run --no-die --secret-arg 1 -- false SECRETVALUE 2>&1) || true
assert_not_contains "$out" "SECRETVALUE" "the declared argument must never reach the log"

out=$(run --no-die --secret-arg 2 -- false plain SECRETVALUE 2>&1) || true
assert_not_contains "$out" "SECRETVALUE" "the declared argument must never reach the log"
assert_contains "$out" "plain" "the arguments that were not declared must stay readable"

# 环境变量：SHELLKIT_SECRET_ARGS="2,3"
out=$(SHELLKIT_SECRET_ARGS="1" run --no-die false SECRETVALUE 2>&1) || true
assert_not_contains "$out" "SECRETVALUE" "the environment-declared argument must never reach the log"

out=$(SHELLKIT_SECRET_ARGS="1,2" run --no-die false SECRETVALUE OTHERVALUE 2>&1) || true
assert_not_contains "$out" "SECRETVALUE" "the environment-declared argument must never reach the log"
assert_not_contains "$out" "OTHERVALUE" "every environment-declared argument must be masked"

# --redact-value：按值脱敏（令牌夹在参数中间也遮得到）
out=$(run --no-die --redact-value 'my-pass' -- false -H 'X-Custom: my-pass' 2>&1) || true
assert_not_contains "$out" "my-pass" "the declared value must never reach the log"
assert_contains "$out" "X-Custom" "the rest of the argument must stay readable"

# 序号不合法要报错，不能当成「没声明」悄悄放过
rc=0
run --no-die --secret-arg 0 -- false >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "a zero index must be rejected"
rc=0
run --no-die --secret-arg abc -- false >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "a non-numeric index must be rejected"
rc=0
run --no-die --secret-arg >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "a missing index must be rejected"

# ---------------------------------------------------------------- 反向用例
# 过度脱敏也是回归：日志没了细节就没法排障
out=$(failed_line false --verbose --count 3 plainid)
assert_contains "$out" "--verbose" "an ordinary option must stay readable"
assert_contains "$out" "--count" "an ordinary option must stay readable"
assert_contains "$out" "plainid" "an ordinary argument must stay readable"

out=$(failed_line false ID=123 COUNT=5 monkey=banana)
assert_contains "$out" "ID=123" "an ordinary assignment must stay readable"
assert_contains "$out" "COUNT=5" "an ordinary assignment must stay readable"
assert_contains "$out" "monkey=banana" "a word that merely ends in key must stay readable"

out=$(failed_line false --username=john)
assert_contains "$out" "--username=john" "a username option must stay readable"

# 声明只对这一次调用有效：不能漏到后面的 run
run --no-die --secret-arg 1 -- false SECRETVALUE >/dev/null 2>&1 || true
out=$(failed_line false SECRETVALUE)
assert_contains "$out" "SECRETVALUE" "a declaration must not leak into the next run"

exit 0
