#!/usr/bin/env bash
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

# 门禁的覆盖面也是接口的一部分：没被 make 收进去的脚本，
# 语法错、shellcheck 警告、格式漂移都只会在用户手里才暴露。
# 没装 make 的机器上这条测不了 —— 跳过，不要报成「门禁没覆盖」。
if ! command -v make >/dev/null 2>&1; then
  printf 'skip: make is not installed, the Makefile coverage cases are not run\n' >&2
  exit 0
fi

syntax=$(cd "$TEST_ROOT" && make -n syntax 2>/dev/null)
assert_contains "$syntax" "install.sh" "make syntax covers install.sh"
assert_contains "$syntax" "tools/shdoc.sh" "make syntax covers tools/*.sh"

lint=$(cd "$TEST_ROOT" && make -n lint 2>/dev/null)
assert_contains "$lint" "install.sh" "make lint covers install.sh"
assert_contains "$lint" "tools/shdoc.sh" "make lint covers tools/*.sh"

fmt=$(cd "$TEST_ROOT" && make -n fmt 2>/dev/null)
assert_contains "$fmt" "install.sh" "make fmt covers install.sh"

# msgid 漂移必须在门禁里，否则 pot 头能落后一个版本还没人发现
check=$(cd "$TEST_ROOT" && make -n check 2>/dev/null)
assert_contains "$check" "po/messages.sh --check" "make check verifies the message catalogue"
