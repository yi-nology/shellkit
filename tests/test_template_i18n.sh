#!/usr/bin/env bash
#
# 模板 i18n：生成工程的 Makefile 用户可见文案跟着「生成那一刻」的语言走。
#
# 背景：这些文案（make help 的说明行、找不到 shellkit / 没有库副本等报错）
# 以前硬编码中文。运行期翻译不可行 —— 「找不到 shellkit」这条恰恰在库不可用
# 时打印，_t 还不存在。所以文案由生成器在生成/升级工程时按自己的语言塞进
# MSG_* 模板变量（--set MSG_*=... 仍可覆盖）。
#
# 断言纪律：断完整文案不断单词；目录名只用编号；SHELLKIT_LANG 由 helper 固定 en，
# 要测多语言行为的用例自己用 env 前缀覆盖。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

# 造一座可用的模板目录（upgrade 需要可写模板路径，与 test_upgrade.sh 同惯例）
tpl="$TEST_TMP_ROOT/tpl"
cp -R "$TEST_ROOT/templates" "$tpl" || _fail "cannot copy templates"

# CASE: 英文生成 —— help 与报错全是英文（完整文案断言）
p1=$(tmpdir) || _fail "cannot create tmpdir"
SHELLKIT_LANG=en "$TEST_ROOT/shellkit" new --name app1 "$p1" --cmd run --yes >"$TEST_TMP_ROOT/new1.log" 2>&1 || _fail "new (en) failed: $(tail -3 "$TEST_TMP_ROOT/new1.log")"
help=$(make -C "$p1" help 2>/dev/null)
assert_contains "$help" "make test        run all tests" "en help must show the English description"
assert_contains "$help" "make upgrade     upgrade the project to the current template" "en help: upgrade line"
assert_not_contains "$help" "跑全部测试" "en help must not contain hardcoded Chinese"
# new 会把库 vendor 进工程 —— 报错路径要先摘掉 vendor
rm -rf "$p1/vendor"
# 报错：没有 vendor 的工程跑 make version ⇒ 英文报错（recipe exit 3，
# GNU make 自己一律以 2 报告失败 —— 断 2 与文案，不断 recipe 码）
assert_exit_code 2 make -C "$p1" version
out=$(make -C "$p1" version 2>&1) && _fail "make version should fail without vendor" || true
assert_contains "$out" "no library copy in this project: run make vendor first" "en error message must be English"
# 报错：没有 vendor 也没有 PATH shellkit ⇒ make upgrade 报英文的找不到 shellkit
out=$(cd "$p1" && env PATH="/usr/bin:/bin" make upgrade 2>&1) && _fail "make upgrade should fail" || true
assert_contains "$out" "shellkit not found: install one first (shellkit install-self), or keep vendor/shellkit/shellkit in this project" "en: shellkit-not-found message"

# CASE: 中文生成 —— 文案与旧版硬编码逐字一致（中文用户零变化）
p2=$(tmpdir) || _fail "cannot create tmpdir"
SHELLKIT_LANG=zh_CN "$TEST_ROOT/shellkit" new --name app2 "$p2" --cmd run --yes >/dev/null 2>&1 || _fail "new (zh) failed"
help=$(make -C "$p2" help 2>/dev/null)
assert_contains "$help" "make test        跑全部测试" "zh help must byte-match the old hardcoded text"
assert_contains "$help" "make lint        shellcheck 静态检查" "zh help: lint line"
assert_contains "$help" "make fmt         shfmt 格式检查（只检查不改）" "zh help: fmt line"
assert_contains "$help" "make upgrade     把工程升级到当前模板" "zh help: upgrade line"
assert_contains "$help" "make completion  输出 bash 补全脚本" "zh help: completion line"
assert_contains "$help" "make version     打印工程用的库版本" "zh help: version line"
assert_contains "$help" "make vendor      把库镜像进 vendor/shellkit" "zh help: vendor line"
# new 会把库 vendor 进工程 —— 报错路径要先摘掉 vendor
rm -rf "$p2/vendor"
out=$(make -C "$p2" version 2>&1) && _fail "make version should fail without vendor" || true
assert_contains "$out" "工程里没有库副本：先跑 make vendor" "zh: no-vendor message"
out=$(cd "$p2" && env PATH="/usr/bin:/bin" make upgrade 2>&1) && _fail "make upgrade should fail" || true
assert_contains "$out" "找不到 shellkit：先装一个（shellkit install-self），或在工程里保留 vendor/shellkit/shellkit" "zh: shellkit-not-found message"
assert_contains "$out" "找不到 shellkit" "zh message sanity"

# CASE: --set 覆盖内置文案
p3=$(tmpdir) || _fail "cannot create tmpdir"
SHELLKIT_LANG=en "$TEST_ROOT/shellkit" new --name app3 "$p3" --cmd run --yes \
  --set "MSG_HELP_TEST=do the thing" >/dev/null 2>&1 || _fail "new (--set) failed"
help=$(make -C "$p3" help 2>/dev/null)
assert_contains "$help" "make test        do the thing" "--set must override the built-in message"

# CASE: 升级时按升级器的语言重刷文案，且不剩 {{MSG_ 占位符
out=$(SHELLKIT_LANG=zh_CN "$TEST_ROOT/shellkit" upgrade "$p1" --template "$tpl" 2>&1) || _fail "upgrade failed: $out"
help=$(make -C "$p1" help 2>/dev/null)
assert_contains "$help" "make test        跑全部测试" "upgrade under zh_CN must rewrite the Makefile text"
assert_not_contains "$help" "{{MSG_" "no placeholder may survive rendering"

exit 0
