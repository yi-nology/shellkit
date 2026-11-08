#!/usr/bin/env bash
# AI 说明与文档门禁的测试。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

# 产物与源一致（四份：REFERENCE / AGENTS / templates/AGENTS / skills/SKILL）
assert_exit_code 0 bash "$TEST_ROOT/shellkit" docs --check

# 模块序列在两个文件里各有一份，改了不同步会让文档缺模块却没人发现
boot=$(sed -n 's/^for _sk_module in \(.*\); do$/\1/p' "$TEST_ROOT/lib/bootstrap.sh")
doc=$(sed -n 's/^MODULES="\(.*\)"$/\1/p' "$TEST_ROOT/tools/shdoc.sh")
assert_eq "$boot" "$doc" "module list drift between bootstrap.sh and shdoc.sh"

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
