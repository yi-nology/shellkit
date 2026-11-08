#!/usr/bin/env bash
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"

# 退出码是接口的一部分：die abc 不能被 bash 的 exit 静默截断成 255
assert_exit_code 4 bash -c '. "$1/lib/bootstrap.sh"; die 4 boom' _ "$TEST_ROOT"
assert_exit_code 5 bash -c '. "$1/lib/bootstrap.sh"; die 5 boom' _ "$TEST_ROOT"
assert_exit_code 0 bash -c '. "$1/lib/bootstrap.sh"; die 0 done' _ "$TEST_ROOT"

# 非数字 / 越界 / 缺参一律按用法错误处理，并说清哪个值不对
assert_exit_code 2 bash -c '. "$1/lib/bootstrap.sh"; die notanumber boom' _ "$TEST_ROOT"
assert_exit_code 2 bash -c '. "$1/lib/bootstrap.sh"; die 300 boom' _ "$TEST_ROOT"
assert_exit_code 2 bash -c '. "$1/lib/bootstrap.sh"; die' _ "$TEST_ROOT"
err=$(bash -c '. "$1/lib/bootstrap.sh"; die notanumber boom' _ "$TEST_ROOT" 2>&1 >/dev/null)
assert_contains "$err" "notanumber" "die names the invalid exit code"

# fail 只返回码，不退出；非法码同样返回 SK_USAGE
assert_exit_code 3 bash -c '. "$1/lib/bootstrap.sh"; fail 3 boom' _ "$TEST_ROOT"
assert_exit_code 7 bash -c '. "$1/lib/bootstrap.sh"; fail 7 boom; exit $?' _ "$TEST_ROOT"
assert_exit_code 2 bash -c '. "$1/lib/bootstrap.sh"; fail nope boom' _ "$TEST_ROOT"
assert_exit_code 2 bash -c '. "$1/lib/bootstrap.sh"; fail' _ "$TEST_ROOT"

# 正常分支不受影响：消息进 stderr，stdout 保持干净
out=$(bash -c '. "$1/lib/bootstrap.sh"; fail 3 boom' _ "$TEST_ROOT" 2>/dev/null)
assert_eq "" "$out" "fail writes to stderr only"
