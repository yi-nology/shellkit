#!/usr/bin/env bash
# AI 说明与文档门禁的测试。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

# 产物与源一致（四份：REFERENCE / AGENTS / templates/AGENTS / skills/SKILL）
assert_exit_code 0 bash "$TEST_ROOT/shellkit" docs --check

# 模块序列只有一份真相源：lib/modules.txt。bootstrap.sh 与 shdoc.sh 都从它读，
# 所以「两处顺序不一致」这个漂移源已经消除 —— 这里守住新的不变量。
#
# 1) modules.txt 里列的每个模块都要有对应源码文件
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    '' | '#'*) continue ;;
  esac
  # 清单是两列的：第一列模块名，第二列它依赖的模块。模块名取第一列。
  m="${line%%[[:space:]]*}"
  case "$m" in
    '' | '#'*) continue ;;
  esac
  if [ ! -f "$TEST_ROOT/lib/core/$m.sh" ]; then
    _fail "module listed in modules.txt has no source: $m"
  fi
done <"$TEST_ROOT/lib/modules.txt"

# 2) 两个加载方都必须从 modules.txt 读，不能再各自写死一份清单
assert_contains "$(cat "$TEST_ROOT/lib/bootstrap.sh")" "lib/modules.txt" \
  "bootstrap.sh must load the module list from lib/modules.txt"
assert_contains "$(cat "$TEST_ROOT/tools/shdoc.sh")" "lib/modules.txt" \
  "shdoc.sh must read the module list from lib/modules.txt"

# 3) 依赖顺序门禁本身要绿：某个模块调用了还没加载的模块的函数必须被抓住
assert_exit_code 0 bash "$TEST_ROOT/tools/check_module_order.sh"

# 文档门禁本身
assert_exit_code 0 bash "$TEST_ROOT/tools/check_docs.sh"

d=$(mktemp -d "$TEST_TMP_ROOT/ai.XXXXXX") || _fail "mktemp failed"

# 生成的工程自带 AGENTS.md，且没有任何模板占位符残留
bash "$TEST_ROOT/shellkit" new "$d/proj" --cmd start >/dev/null 2>&1 || _fail "shellkit new failed"
assert_true test -f "$d/proj/AGENTS.md"
assert_contains "$(cat "$d/proj/AGENTS.md")" "proj" "AGENTS.md should carry the project name"
# vendor/ 是库的镜像，不含占位符；要查的是工程自己的文件
left=$(find "$d/proj" -path "$d/proj/vendor" -prune -o -type f -name '*' -print 2>/dev/null | while IFS= read -r f; do
  grep -lq '{{' "$f" 2>/dev/null && printf '%s\n' "$f"
done)
assert_eq "" "$left" "generated project still contains template placeholders"

# 在隔离副本里验两件失败：文档漂移、文档里出现不存在的函数
copy="$d/copy"
mkdir -p "$copy" || _fail "mkdir failed"
for p in shellkit VERSION lib locale templates tools docs; do
  cp -R "$TEST_ROOT/$p" "$copy/$p" || _fail "copy $p failed"
done

printf '\n```bash\nconf_require FOO\n```\n' >"$copy/docs/FAKE.md"
rc=0
bash "$copy/tools/check_docs.sh" >/dev/null 2>&1 || rc=$?
assert_eq "1" "$rc" "check_docs must reject a function that does not exist"

printf '\n<!-- drift -->\n' >>"$copy/docs/ai/contract.md"
rc=0
bash "$copy/shellkit" docs --check >/dev/null 2>&1 || rc=$?
assert_eq "5" "$rc" "docs --check must fail when a source is out of date"
