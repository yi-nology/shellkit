#!/usr/bin/env bash
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

work=$(tmpdir)
proj="$work/demo-tool"

out=$("$TEST_ROOT/shellkit" new "$proj" --cmd start --cmd stop 2>&1)
assert_true test -d "$proj"
assert_contains "$out" "project created" "new reports success"

# 结构完整
for p in bin/demo-tool lib/app.sh commands/start.sh commands/stop.sh \
  tests/run.sh tests/test_helper.sh tests/test_smoke.sh \
  config.example Makefile .shellcheckrc README.md \
  vendor/shellkit/lib/bootstrap.sh vendor/shellkit/VERSION; do
  if [ ! -e "$proj/$p" ]; then
    _fail "missing generated file: $p"
  fi
done

assert_file_mode "$proj/bin/demo-tool" "755"

# 占位符必须全部被替换
if grep -rq '{{NAME}}\|{{CMD}}\|{{SHELLKIT_VERSION}}' "$proj/bin" "$proj/lib" "$proj/commands" "$proj/tests" "$proj/README.md"; then
  _fail "unrendered placeholder left in generated project"
fi

# 生成物能跑：help / version / 两个命令 / 未知命令返回 2
assert_exit_code 0 "$proj/bin/demo-tool" --help
assert_exit_code 0 "$proj/bin/demo-tool" start
assert_exit_code 0 "$proj/bin/demo-tool" stop
assert_exit_code 2 "$proj/bin/demo-tool" nope

# stdout 只给数据：日志不能出现
out=$("$proj/bin/demo-tool" start 2>/dev/null)
assert_not_contains "$out" "[INFO]" "logs must go to stderr"

# 空目录可以复用，非空目录必须拒绝
assert_exit_code 3 "$TEST_ROOT/shellkit" new "$proj"

# 生成工程的测试套件必须当场通过
(cd "$proj" && bash tests/run.sh >/dev/null 2>&1) || _fail "generated project tests failed"
