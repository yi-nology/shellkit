#!/usr/bin/env bash
# 示例工程的测试：全程走真实二进制，不 source 内部函数。
set -u
SK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
. "$SK_ROOT/tests/test_helper.sh"

BIN="$TEST_ROOT/examples/deploy-service/bin/deploy-service"
d=$(mktemp -d "$TEST_TMP_ROOT/dep.XXXXXX") || _fail "mktemp failed"
export DEPLOY_ROOT="$d"

assert_exit_code 0 "$BIN" deploy web
assert_file_mode "$d/web.service" "644"
assert_contains "$(cat "$d/web.service")" "ExecStart=/usr/local/bin/web"

# 幂等：再跑一次，内容逐字不变
before=$(cat "$d/web.service")
assert_exit_code 0 "$BIN" deploy web
assert_eq "$before" "$(cat "$d/web.service")" "deploy must be idempotent"

# status 只把数据写到 stdout，所以命令替换拿到的是干净值
assert_eq "installed" "$("$BIN" status web 2>/dev/null)" "status prints data only"
assert_exit_code 1 "$BIN" status nosuch

# 缺参数是用法错（2），不是一般错误（1）
assert_exit_code 2 "$BIN" deploy
assert_exit_code 2 "$BIN" nosuchcmd
