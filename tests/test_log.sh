#!/usr/bin/env bash
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"

_probe_info() {
  log_info "hello info"
  log_warn "hello warn"
}

# 日志必须写 stderr，stdout 保持干净
assert_stdout_empty _probe_info

err=$(_probe_info 2>&1 1>/dev/null)
assert_contains "$err" "hello info"
assert_contains "$err" "hello warn"
assert_contains "$err" "WARN"

# log_error 记录到 SK_ERRMSG
log_error "boom" 2>/dev/null
assert_eq "boom" "$SK_ERRMSG" "SK_ERRMSG"

# log_debug 默认静默
out=$(log_debug "should not appear" 2>&1)
assert_eq "" "$out" "log_debug must be silent by default"

# 颜色控制
SHELLKIT_COLOR=never
# 直接固定颜色开关，避免测试依赖终端
# shellcheck disable=SC2034
SK_COLOR_ON=0
out=$(log_error "plain" 2>&1)
assert_not_contains "$out" "033" "no escape codes when color is off"
