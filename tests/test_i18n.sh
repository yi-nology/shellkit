#!/usr/bin/env bash
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"

# 译文必须真的生效：用子进程带上 LANG，避免污染当前 shell
if [ -n "${SK_GETTEXT:-}" ] && [ -f "$TEST_ROOT/locale/zh_CN/LC_MESSAGES/shellkit.mo" ]; then
  msg=$(LANG=zh_CN.UTF-8 bash -c '. "$1/lib/bootstrap.sh"; _t "Usage"' _ "$TEST_ROOT")
  assert_eq "用法" "$msg" "zh_CN translation applies"
fi

# 没有 gettext 时降级为英文，且不报错
msg=$(SHELLKIT_NO_GETTEXT=1 bash -c '. "$1/lib/bootstrap.sh"; _t "Usage"' _ "$TEST_ROOT")
assert_eq "Usage" "$msg" "SHELLKIT_NO_GETTEXT degrades to the English msgid"

# _tn：n=1 用单数，其余用复数
assert_eq "one" "$(_tn "one" "many" 1)" "_tn singular"
assert_eq "many" "$(_tn "one" "many" 0)" "_tn plural"

# zh_CN 里除文件头外不允许有空 msgstr —— 新增 msgid 忘了翻译会在这里红
po="$TEST_ROOT/locale/zh_CN/LC_MESSAGES/shellkit.po"
if [ -f "$po" ]; then
  empty=$(grep -c '^msgstr ""$' "$po")
  assert_eq "1" "$empty" "every msgid in zh_CN has a translation (only the header may be empty)"
fi
