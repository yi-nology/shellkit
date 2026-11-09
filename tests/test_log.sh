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

# ---- 级别过滤 ----

out=$(SHELLKIT_LOG_LEVEL=warn log_info "hidden info" 2>&1)
assert_eq "" "$out" "log_info is silenced at level warn"
out=$(SHELLKIT_LOG_LEVEL=warn log_warn "shown warn" 2>&1)
assert_contains "$out" "shown warn" "log_warn passes at level warn"
out=$(SHELLKIT_LOG_LEVEL=error log_warn "hidden warn" 2>&1)
assert_eq "" "$out" "log_warn is silenced at level error"
out=$(SHELLKIT_LOG_LEVEL=error log_error "shown error" 2>&1)
assert_contains "$out" "shown error" "log_error passes at level error"

# debug 有两个开关：SHELLKIT_LOG_LEVEL=debug 或 SHELLKIT_DEBUG=1
out=$(SHELLKIT_LOG_LEVEL=debug log_debug "shown debug" 2>&1)
assert_contains "$out" "shown debug" "log_debug appears at level debug"
out=$(SHELLKIT_DEBUG=1 log_debug "shown debug" 2>&1)
assert_contains "$out" "shown debug" "SHELLKIT_DEBUG=1 still enables log_debug"
out=$(log_debug "hidden debug" 2>&1)
assert_eq "" "$out" "log_debug stays silent without either switch"

# 级别比较不区分大小写
out=$(SHELLKIT_LOG_LEVEL=WARN log_warn "shown warn" 2>&1)
assert_contains "$out" "shown warn" "the log level is case insensitive"

# ---- JSON 格式 ----

json=$(SHELLKIT_LOG_FORMAT=json log_info "plain message" 2>&1)
assert_contains "$json" '"level":"INFO"' "json mode emits the level field"
assert_contains "$json" '"msg":"plain message"' "json mode emits the message field"
assert_contains "$json" '"ts":"' "json mode emits the timestamp field"

# 消息里的引号与换行必须被转义，否则 JSON 行会被打断
json=$(SHELLKIT_LOG_FORMAT=json log_info 'has "quotes" and
a newline' 2>&1)
lines=$(printf '%s\n' "$json" | wc -l | tr -d ' ')
assert_eq "1" "$lines" "json mode keeps one log on one line"
assert_contains "$json" '\"quotes\"' "json mode escapes double quotes"
assert_contains "$json" '\n' "json mode escapes newlines"

# 有 python3 时这行必须能被真的解析
if command -v python3 >/dev/null 2>&1; then
  SHELLKIT_LOG_FORMAT=json log_info 'parse "me"' 2>&1 | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["msg"]=="parse \"me\"", d' >/dev/null 2>&1
  assert_eq "0" "$?" "json mode output must be valid JSON"
fi

# log_section 在 json 模式下不输出：JSON 行要一行一条记录
out=$(SHELLKIT_LOG_FORMAT=json log_section "a section" 2>&1)
assert_eq "" "$out" "log_section stays silent in json mode"

# ---- 日志文件 ----

logf="$TEST_TMP_ROOT/shellkit.log"
SHELLKIT_LOG_FILE="$logf" log_info "to the file" >/dev/null 2>&1
if [ ! -f "$logf" ]; then
  _fail "the log file is created"
fi
assert_contains "$(cat "$logf")" "to the file" "the log file receives the message"

jsonf="$TEST_TMP_ROOT/shellkit.json.log"
SHELLKIT_LOG_FILE="$jsonf" SHELLKIT_LOG_FORMAT=json log_info "json to the file" >/dev/null 2>&1
assert_contains "$(cat "$jsonf")" '"msg":"json to the file"' "the log file receives json lines"

# 父目录不存在时只报错，不崩
rc=0
out=$(SHELLKIT_LOG_FILE="$TEST_TMP_ROOT/no/such/dir/x.log" log_info "nowhere" 2>&1) || rc=$?
assert_eq "0" "$rc" "an unwritable log file must not fail the script"
