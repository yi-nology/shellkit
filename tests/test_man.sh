#!/usr/bin/env bash
#
# shellkit man 的测试：页面从注册表与函数注释生成，不另维护清单。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"

# ---- 模块清单 ----
mods=$(man_modules)
[ -n "$mods" ] || _fail "man_modules lists the modules"
n_mods=$(printf '%s\n' "$mods" | grep -c '.')
[ "$n_mods" -ge 1 ] || _fail "man_modules returns at least one module"

# ---- 第 3 节：模块页 ----
page=$(man_module_page str)
assert_contains "$page" ".TH SHELLKIT-STR 3" "module page has a TH header"
assert_contains "$page" ".SH FUNCTIONS" "module page has a FUNCTIONS section"
assert_contains "$page" "str_trim" "module page lists the module's functions"
assert_contains "$page" "EXIT" "module page carries the exit codes"

# 模块说明只取文件头首行摘要：多段式文件头不该被摊成一堵文字墙
desc_lines=$(printf '%s\n' "$page" | awk '/^\.SH DESCRIPTION$/{f=1; next} /^\.SH /{f=0} f' | grep -c '.')
assert_eq "1" "$desc_lines" "the module description is a single line"

# 私有函数不进 man 页
assert_not_contains "$page" "_sk_is_name" "private helpers stay out of the man page"

# 模块不存在 / 名字非法 → 2
assert_exit_code 2 man_module_page no-such-module
assert_exit_code 2 man_module_page "bad/name"
assert_exit_code 2 man_module_page ""

# ---- 写出全部页面 ----
d=$(tmpdir)
assert_exit_code 0 man_write_all "$d"
[ -f "$d/shellkit.1" ] || _fail "shellkit.1 is written"
n_pages=$(find "$d" -name 'shellkit-*.3' | grep -c '.')
assert_eq "$n_mods" "$n_pages" "one page per module"

# 目录不存在 → 3
assert_exit_code 3 man_write_all "$d/nope"

# ---- 命令行 ----
out=$(bash "$TEST_ROOT/shellkit" man 2>/dev/null)
assert_contains "$out" ".TH SHELLKIT 1" "shellkit man prints the section 1 page"
assert_contains "$out" ".SH COMMANDS" "the page has a COMMANDS section"
# 命令来自注册表：CLI 自己注册过的命令都要在页面上
for c in new upgrade doctor list vendor docs completion install-self update man; do
  assert_contains "$out" ".B $c" "the page lists the '$c' command"
done

d2=$(tmpdir)
assert_exit_code 0 bash "$TEST_ROOT/shellkit" man --out "$d2"
[ -f "$d2/shellkit.1" ] || _fail "shellkit man --out writes shellkit.1"

assert_exit_code 2 bash "$TEST_ROOT/shellkit" man --bogus
assert_exit_code 2 bash "$TEST_ROOT/shellkit" man --out
assert_exit_code 3 bash "$TEST_ROOT/shellkit" man --out "$d2/nope"
