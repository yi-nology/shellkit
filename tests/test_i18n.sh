#!/usr/bin/env bash
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"

mo="$TEST_ROOT/locale/zh_CN/LC_MESSAGES/shellkit.mo"

# 译文是否"真的生效"取决于系统 locale：装了 zh_CN 且 gettext 正常时走精确断言；
# 否则（CI 上常见的组合差异）退化为结构断言——验 .mo 里确实编进了译文。
# 环境差异不该把测试判红，但译文缺失必须红。
if [ -n "${SK_GETTEXT:-}" ] && [ -f "$mo" ]; then
  msg=""
  if locale -a 2>/dev/null | grep -qi '^zh_CN'; then
    msg=$(LC_ALL=zh_CN.UTF-8 LANG=zh_CN.UTF-8 bash -c '. "$1/lib/bootstrap.sh"; _t "Usage"' _ "$TEST_ROOT")
  fi
  if [ "$msg" = "用法" ]; then
    assert_eq "用法" "$msg" "zh_CN translation applies"
  else
    assert_contains "$(cat "$mo")" "用法" "zh_CN .mo carries the compiled translation"
  fi
fi

# 没有 gettext 时降级为英文，且不报错
msg=$(SHELLKIT_NO_GETTEXT=1 bash -c '. "$1/lib/bootstrap.sh"; _t "Usage"' _ "$TEST_ROOT")
assert_eq "Usage" "$msg" "SHELLKIT_NO_GETTEXT degrades to the English msgid"

# _tn：n=1 用单数，其余用复数
assert_eq "one" "$(_tn "one" "many" 1)" "_tn singular"
assert_eq "many" "$(_tn "one" "many" 0)" "_tn plural"

# 复数分支也必须经过 gettext：否则 .po 里的复数译文永远查不到。
# 用 PATH 前置的假 gettext 断言「确实调用了 gettext」，不依赖系统有没有 zh_CN。
_nd=$(tmpdir)
_fakebin="$_nd/fakebin"
mkdir -p "$_fakebin"
{
  printf '#!/bin/sh\n'
  printf '%s\n' 'printf "T[%s]" "$1"'
} >"$_fakebin/gettext"
chmod +x "$_fakebin/gettext"
out=$(PATH="$_fakebin:$PATH" bash -c '. "$1/lib/bootstrap.sh"; _tn "one item" "many items" 2' _ "$TEST_ROOT")
assert_eq "T[many items]" "$out" "_tn sends the plural form through gettext"
out=$(PATH="$_fakebin:$PATH" bash -c '. "$1/lib/bootstrap.sh"; _tn "one item" "many items" 1' _ "$TEST_ROOT")
assert_eq "T[one item]" "$out" "_tn sends the singular form through gettext"

# pot 与源码必须一致：否则新增的 msgid 根本进不了译文目录
if command -v xgettext >/dev/null 2>&1; then
  assert_exit_code 0 bash "$TEST_ROOT/po/messages.sh" --check

  # 生成时间不算「消息变了」：把 pot 的日期改旧之后必须仍然通过。
  # 否则这条检查过一分钟就自己红，挂进门禁只会逼人把它关掉。
  _i18n_root=$(tmpdir)
  mkdir -p "$_i18n_root/po"
  cp -R "$TEST_ROOT/lib" "$TEST_ROOT/templates" "$_i18n_root/" || _fail "cannot stage the i18n root"
  cp "$TEST_ROOT/shellkit" "$TEST_ROOT/VERSION" "$_i18n_root/"
  cp "$TEST_ROOT/po/messages.sh" "$_i18n_root/po/"
  # pot 落在 locale/ 下，不在 po/ 下
  mkdir -p "$_i18n_root/locale"
  cp "$TEST_ROOT/locale/shellkit.pot" "$_i18n_root/locale/"
  sed -i.bak 's/^"POT-Creation-Date:.*/"POT-Creation-Date: 2000-01-01 00:00+0000\\n"/' \
    "$_i18n_root/locale/shellkit.pot"
  assert_exit_code 0 bash "$_i18n_root/po/messages.sh" --check
fi

# zh_CN 里除文件头外不允许有空 msgstr —— 新增 msgid 忘了翻译会在这里红
po="$TEST_ROOT/locale/zh_CN/LC_MESSAGES/shellkit.po"
if [ -f "$po" ]; then
  empty=$(grep -c '^msgstr ""$' "$po")
  assert_eq "1" "$empty" "every msgid in zh_CN has a translation (only the header may be empty)"
fi
