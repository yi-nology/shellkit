#!/usr/bin/env bash
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"

mo="$TEST_ROOT/locale/zh_CN/LC_MESSAGES/shellkit.mo"

# 译文是否真的生效，取决于系统装没装 zh_CN 这个 locale：
#   - 装了：直接验 LANG=zh_CN.UTF-8 下 _t 的输出
#   - 没装（CI 的 ubuntu 就是这种）：退化为验 .mo 里确实编进了译文
#   - 没有 gettext：只验降级路径
if [ -n "${SK_GETTEXT:-}" ] && [ -f "$mo" ]; then
  if locale -a 2>/dev/null | grep -qi '^zh_CN'; then
    msg=$(LANG=zh_CN.UTF-8 bash -c '. "$1/lib/bootstrap.sh"; _t "Usage"' _ "$TEST_ROOT")
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

# zh_CN 里除文件头外不允许有空 msgstr —— 新增 msgid 忘了翻译会在这里红
po="$TEST_ROOT/locale/zh_CN/LC_MESSAGES/shellkit.po"
if [ -f "$po" ]; then
  empty=$(grep -c '^msgstr ""$' "$po")
  assert_eq "1" "$empty" "every msgid in zh_CN has a translation (only the header may be empty)"
fi
