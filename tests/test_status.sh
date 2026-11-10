#!/usr/bin/env bash
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"

# 人类模式：打印人类文案
out=$(status_emit not_installed "未安装")
assert_eq "未安装" "$out" "human mode prints the human message"

# 机器模式：打印规范字段
out=$(SHELLKIT_STATUS_MODE=machine status_emit not_installed "未安装")
assert_eq "STATE=not_installed" "$out" "machine mode prints STATE="

out=$(SHELLKIT_STATUS_MODE=machine status_version 1.2.3)
assert_eq "VERSION=1.2.3" "$out" "machine mode prints VERSION="

out=$(SHELLKIT_STATUS_MODE=machine status_extra registry=https://example.com)
assert_eq "EXTRA=registry=https://example.com" "$out" "machine mode prints EXTRA="

# 人类模式下 version/extra 不输出（不重复）
assert_stdout_empty status_version 1.2.3
assert_stdout_empty status_extra k=v

# 状态码有限集
assert_true status_state_valid not_installed
assert_true status_state_valid installed
assert_true status_state_valid installed:running
assert_true status_state_valid installed:stopped
assert_true status_state_valid configured
assert_true status_state_valid not_configured
assert_true status_state_valid n/a
assert_false status_state_valid whatever
assert_false status_state_valid ""

# 机器模式判定
assert_exit_code 1 status_is_machine
export SHELLKIT_STATUS_MODE=machine
assert_exit_code 0 status_is_machine
unset SHELLKIT_STATUS_MODE

# 人类模式要解释颜色转义序列（unix_script 的颜色变量是字面 ESC 序列）
out=$(status_emit installed '\033[0;32m已安装\033[0m')
assert_eq $'\033[0;32m已安装\033[0m' "$out" "human mode interprets color escapes"

# 机器模式忽略人类文案
out=$(SHELLKIT_STATUS_MODE=machine status_emit installed "已安装")
assert_eq "STATE=installed" "$out" "machine mode ignores the human message"

# 缺参数也不炸
assert_exit_code 0 status_emit
assert_exit_code 0 status_version
assert_exit_code 0 status_extra
