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
  # 不加 -q：grep -q 命中即退，locale 会被 SIGPIPE 打死，pipefail 下这条判断就成了假绿
  if locale -a 2>/dev/null | grep -i '^zh_CN' >/dev/null; then
    # SHELLKIT_LANG= 空值 = 「不设」：这条要的就是「按系统 locale 选语言」，
    # 而 test_helper.sh 统一把 SHELLKIT_LANG 设成 en 了 —— 这里必须显式放开。
    msg=$(SHELLKIT_LANG='' LC_ALL=zh_CN.UTF-8 LANG=zh_CN.UTF-8 bash -c '. "$1/lib/bootstrap.sh"; _t "Usage"' _ "$TEST_ROOT")
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

# ---------------------------------------------------------------------------
# 不设任何新环境变量时，_t 的输出必须与改动前逐字一致。
#
# 改动前的 _t 就是「裸跑 gettext」（域名取 TEXTDOMAIN，目录取 TEXTDOMAINDIR）。
# 所以判据是：同一个环境下，_t 的输出跟裸跑 gettext 逐字相同。
# 三种环境各来一遍 —— 尤其 LANGUAGE=en LC_ALL=zh_CN.UTF-8 这一组：
# gettext 自己的语言优先级是 LANGUAGE > LC_ALL，动手改就会把英文变成中文。
# ---------------------------------------------------------------------------
if [ -n "${SK_GETTEXT:-}" ]; then
  # 同样要放开 SHELLKIT_LANG：这三条比的就是「按系统 locale 选语言」的行为
  for _env in "SHELLKIT_LANG= LANGUAGE=en LC_ALL=zh_CN.UTF-8" "SHELLKIT_LANG= LC_ALL=zh_CN.UTF-8" "SHELLKIT_LANG= LANGUAGE=zh_CN LC_ALL=C"; do
    _ref=$(env $_env TEXTDOMAIN=shellkit TEXTDOMAINDIR="$TEST_ROOT/locale" gettext 'Usage' || true)
    _got=$(env $_env "$BASH" -c '. "$1/lib/bootstrap.sh"; _t "Usage"' _ "$TEST_ROOT")
    assert_eq "$_ref" "$_got" "_t matches plain gettext byte for byte ($_env)"
  done
fi

# PATH 上没有 gettext 的机器：原样输出 msgid，不报错（与改动前一致）
_minbin=$(tmpdir)
mkdir -p "$_minbin/bin"
for _c in tr dirname; do
  _p=$(command -v "$_c" 2>/dev/null) || continue
  ln -s "$_p" "$_minbin/bin/$_c"
done
out=$(PATH="$_minbin/bin" /bin/bash -c '. "$1/lib/bootstrap.sh"; _t "Usage"' _ "$TEST_ROOT" 2>/dev/null)
assert_eq "Usage" "$out" "without gettext on PATH _t degrades to the English msgid"

# ---------------------------------------------------------------------------
# 多域查找 + 纯 bash 兜底表
# ---------------------------------------------------------------------------

# 自建一张「另一个域」的兜底表（域名的函数名后缀规则由 i18n.sh 决定）
_d=$(tmpdir)
mkdir -p "$_d/locale/zh_CN/messages"
cat >"$_d/locale/zh_CN/messages/other.sh" <<'EOF'
_sk_msg_lookup_other() {
  case "$1" in
    'probe message') printf '%s' '探针消息' ;;
    *) return 1 ;;
  esac
}
EOF

out=$(SHELLKIT_LANG=zh_CN SHELLKIT_I18N_DOMAIN=other \
  SHELLKIT_I18N_DIRS="$_d/locale" _t 'probe message')
assert_eq "探针消息" "$out" "i18n falls back to the pure-bash table"

# 未命中的 msgid 原样返回
out=$(SHELLKIT_LANG=zh_CN SHELLKIT_I18N_DOMAIN=other \
  SHELLKIT_I18N_DIRS="$_d/locale" _t 'not translated')
assert_eq "not translated" "$out" "i18n returns msgid when nothing matches"

# 域名与目录在 bootstrap 之后才设 —— 兜底表必须按当前配置惰性载入
out=$("$BASH" -c '. "$1/lib/bootstrap.sh"; export SHELLKIT_LANG=zh_CN SHELLKIT_I18N_DOMAIN=other SHELLKIT_I18N_DIRS="$2"; _t "probe message"' \
  _ "$TEST_ROOT" "$_d/locale")
assert_eq "探针消息" "$out" "i18n picks up the domain and dirs set after bootstrap"

# 缓存键必须包含语言：换一门语言不能拿上一门的译文
out=$(SHELLKIT_LANG=zh_CN _t 'invalid command name')
assert_eq "非法的命令名" "$out" "the zh_CN table answers"
out=$(SHELLKIT_LANG=zh_Hant _t 'invalid command name')
assert_eq "非法的指令名稱" "$out" "switching the language reloads the table"

# SHELLKIT_NO_GETTEXT=1 + SHELLKIT_LANG：走纯 bash 兜底表
out=$(SHELLKIT_NO_GETTEXT=1 SHELLKIT_LANG=zh_CN "$BASH" -c '. "$1/lib/bootstrap.sh"; _t "Usage"' _ "$TEST_ROOT")
assert_eq "用法" "$out" "the pure-bash fallback table answers when gettext is off"

# 多域：.mo 也要能按目录找到（不只有兜底表）
# gettext 在 C/POSIX locale 下压根不查译文，所以这条只在系统真的装了那个 locale 时成立
if command -v msgfmt >/dev/null 2>&1; then
  _mo=$(tmpdir)
  mkdir -p "$_mo/locale/zh_CN/LC_MESSAGES"
  cat >"$_mo/other.po" <<'EOF'
msgid ""
msgstr ""
"Content-Type: text/plain; charset=UTF-8\n"

msgid "mo probe"
msgstr "mo 探针"
EOF
  msgfmt -o "$_mo/locale/zh_CN/LC_MESSAGES/other.mo" "$_mo/other.po"
  if locale -a 2>/dev/null | grep -i '^zh_CN' >/dev/null; then
    out=$(SHELLKIT_LANG='' LC_ALL=zh_CN.UTF-8 SHELLKIT_I18N_DOMAIN=other SHELLKIT_I18N_DIRS="$_mo/locale" \
      "$BASH" -c '. "$1/lib/bootstrap.sh"; _t "mo probe"' _ "$TEST_ROOT")
    assert_eq "mo 探针" "$out" "i18n finds the .mo of another domain"
  fi
fi

# ---------------------------------------------------------------------------
# 兜底表是生成物：必须与 po/messages.sh 生成的结果逐字节一致
# ---------------------------------------------------------------------------
if command -v awk >/dev/null 2>&1; then
  _gen=$(tmpdir)
  awk -f "$TEST_ROOT/po/po_to_sh.awk" -v domain=shellkit \
    "$TEST_ROOT/locale/zh_CN/LC_MESSAGES/shellkit.po" >"$_gen/shellkit.sh"
  if ! cmp -s "$_gen/shellkit.sh" "$TEST_ROOT/locale/zh_CN/messages/shellkit.sh"; then
    _fail "the committed zh_CN fallback table is stale (run bash po/messages.sh)"
  fi
  # 生成出来的表必须是合法 bash，且能查到已知译文
  bash -n "$TEST_ROOT/locale/zh_CN/messages/shellkit.sh" ||
    _fail "the generated fallback table is not valid bash"
  out=$(bash -c '. "$1"; _sk_msg_lookup_shellkit "invalid command name"' \
    _ "$TEST_ROOT/locale/zh_CN/messages/shellkit.sh")
  assert_eq "非法的命令名" "$out" "the generated fallback table answers a known msgid"

  # 转义：msgid 里有单引号与通配符时，表必须原样匹配
  _esc=$(tmpdir)
  cat >"$_esc/esc.po" <<'EOF'
msgid ""
msgstr ""
"Content-Type: text/plain; charset=UTF-8\n"

msgid "it's a *glob* [x]"
msgstr "引号与通配符：it's ok"
EOF
  awk -f "$TEST_ROOT/po/po_to_sh.awk" -v domain=esc "$_esc/esc.po" >"$_esc/esc.sh"
  bash -n "$_esc/esc.sh" || _fail "the generated table with quotes is not valid bash"
  _msgid="it's a *glob* [x]"
  out=$(bash -c '. "$1"; _sk_msg_lookup_esc "$2"' _ "$_esc/esc.sh" "$_msgid")
  assert_eq "引号与通配符：it's ok" "$out" \
    "the fallback table escapes quotes and glob characters"
fi

# ---------------------------------------------------------------------------
# --check 必须抓得住「表与生成物不一致」
# ---------------------------------------------------------------------------
if command -v xgettext >/dev/null 2>&1; then
  _drift=$(tmpdir)
  mkdir -p "$_drift/po" "$_drift/locale/zh_CN/LC_MESSAGES" "$_drift/locale/zh_CN/messages"
  cp -R "$TEST_ROOT/lib" "$TEST_ROOT/templates" "$_drift/" || _fail "cannot stage the drift root"
  cp "$TEST_ROOT/shellkit" "$TEST_ROOT/VERSION" "$_drift/"
  cp "$TEST_ROOT/po/messages.sh" "$TEST_ROOT/po/po_to_sh.awk" "$_drift/po/"
  cp "$TEST_ROOT/locale/zh_CN/LC_MESSAGES/shellkit.po" "$_drift/locale/zh_CN/LC_MESSAGES/"
  cp "$TEST_ROOT/locale/zh_CN/messages/shellkit.sh" "$_drift/locale/zh_CN/messages/"
  printf '\n# stale\n' >>"$_drift/locale/zh_CN/messages/shellkit.sh"
  _msg=$(bash "$_drift/po/messages.sh" --check 2>&1 || true)
  assert_contains "$_msg" "fallback table is stale" \
    "--check catches a stale fallback table"
fi

# pot 与源码必须一致：否则新增的 msgid 根本进不了译文目录
if command -v xgettext >/dev/null 2>&1; then
  assert_exit_code 0 bash "$TEST_ROOT/po/messages.sh" --check

  # 生成时间不算「消息变了」：把 pot 的日期改旧之后必须仍然通过。
  # 否则这条检查过一分钟就自己红，挂进门禁只会逼人把它关掉。
  _i18n_root=$(tmpdir)
  mkdir -p "$_i18n_root/po"
  cp -R "$TEST_ROOT/lib" "$TEST_ROOT/templates" "$_i18n_root/" || _fail "cannot stage the i18n root"
  cp "$TEST_ROOT/shellkit" "$TEST_ROOT/VERSION" "$_i18n_root/"
  cp "$TEST_ROOT/po/messages.sh" "$TEST_ROOT/po/po_to_sh.awk" "$_i18n_root/po/"
  # pot 落在 locale/ 下，不在 po/ 下
  mkdir -p "$_i18n_root/locale"
  cp "$TEST_ROOT/locale/shellkit.pot" "$_i18n_root/locale/"
  sed -i.bak 's/^"POT-Creation-Date:.*/"POT-Creation-Date: 2000-01-01 00:00+0000\\n"/' \
    "$_i18n_root/locale/shellkit.pot"
  assert_exit_code 0 bash "$_i18n_root/po/messages.sh" --check
fi

# zh_CN 里除文件头外不允许有空 msgstr —— 新增 msgid 忘了翻译会在这里红
#
# 数「真的没译文的条目」不能靠 grep 'msgstr ""'：折行的译文第一行也是
# msgstr ""（折行是 msgmerge 按行宽做的，跟有没有译文无关）。
#
# 也不能靠 msgattrib --untranslated：**gettext 的版本之间对折行译文的判定
# 不一致** —— 0.21（Ubuntu/CI）把折行译文当成没译文，1.0（macOS/Homebrew）
# 不当。同一份 po 在 CI 上数出 2 个「没译文」、本机数 0 ⇒ 假红。
# 折行由 po/po_untranslated.awk 自己解开，结论不随外部工具的版本变。
po="$TEST_ROOT/locale/zh_CN/LC_MESSAGES/shellkit.po"
if [ -f "$po" ] && command -v awk >/dev/null 2>&1 &&
  [ -f "$TEST_ROOT/po/po_untranslated.awk" ]; then
  missing=$(awk -f "$TEST_ROOT/po/po_untranslated.awk" "$po")
  empty=$(printf '%s\n' "$missing" | grep -c . || true)
  if [ "$empty" != "0" ]; then
    printf 'missing translations:\n%s\n' "$missing" >&2
  fi
  assert_eq "0" "$empty" "every msgid in zh_CN has a translation (only the header may be empty)"
fi

# 计数本身必须自证：把「折行译文」和「真的没译文」两种 po 各造一份 ——
# 折行的必须数出 0（这正是 CI 假红的那个坑），没译文的必须数出 1。
# 两个数一样 ⇒ 这个计数没有判据能力。
if command -v awk >/dev/null 2>&1 && [ -f "$TEST_ROOT/po/po_untranslated.awk" ]; then
  _cnt=$(tmpdir)
  cat >"$_cnt/folded.po" <<'EOF'
msgid ""
msgstr ""
"Content-Type: text/plain; charset=UTF-8\n"

msgid ""
"a long english message that gets folded "
"across two lines"
msgstr ""
"a folded chinese translation"
EOF
  assert_eq "0" "$(awk -f "$TEST_ROOT/po/po_untranslated.awk" "$_cnt/folded.po" | grep -c . || true)" \
    "the untranslated counter does not mistake a folded translation for a missing one"
  cat >"$_cnt/missing.po" <<'EOF'
msgid ""
msgstr ""
"Content-Type: text/plain; charset=UTF-8\n"

msgid "untranslated message"
msgstr ""
EOF
  assert_eq "1" "$(awk -f "$TEST_ROOT/po/po_untranslated.awk" "$_cnt/missing.po" | grep -c . || true)" \
    "the untranslated counter reports a genuinely missing translation"
fi

# fuzzy 译文必须为 0。
# msgmerge 会把新 msgid「模糊匹配」到不相干的旧条目上，
# 于是 "invalid concurrency" 会继承 "无效的选择" 这种译文 —— 而上一条断言只看
# msgstr 非空，垃圾译文照样过门。模糊标记是唯一的线索，必须清干净。
for _lang in zh_CN zh_Hant; do
  _po="$TEST_ROOT/locale/$_lang/LC_MESSAGES/shellkit.po"
  [ -f "$_po" ] || continue
  _fuzzy=$(grep -c '^#, fuzzy' "$_po" || true)
  assert_eq "0" "$_fuzzy" "no fuzzy translation survives in $_lang"
done

# ---------------------------------------------------------------------------
# issue #23：xgettext 会把传给它的文件名原样写进 `#:` 注释。
# 传绝对路径时，pot 里嵌着本机的 /Users/xxx，换台机器一跑 messages-check 就红；
# 而且行号注释每改一次代码就整片漂移 —— 假红会逼人把这条门禁关掉。
# ---------------------------------------------------------------------------
if [ -f "$TEST_ROOT/locale/shellkit.pot" ]; then
  loc=$(grep -c '^#:' "$TEST_ROOT/locale/shellkit.pot" || true)
  assert_eq "0" "$loc" "the pot file carries no location comments"
  abs=$(grep -c '^#: /' "$TEST_ROOT/locale/shellkit.pot" || true)
  assert_eq "0" "$abs" "the pot file leaks no absolute paths"
  abs=$(grep -cF "$TEST_ROOT" "$TEST_ROOT/locale/shellkit.pot" || true)
  assert_eq "0" "$abs" "the pot file does not mention the checkout path"
fi

# _tf：译文当 printf 格式串用（占位符按参数填上）
assert_eq "hello world" "$(_tf 'hello %s' "world")" "_tf fills the %s placeholder"
assert_eq "a b" "$(_tf '%s %s' "a" "b")" "_tf fills two placeholders"
assert_eq "no placeholder" "$(_tf 'no placeholder')" "_tf works without arguments"

# 少给参数时不崩：printf 的标准语义是「占位符填空」，不是报错也不是
# 把参数原样吐出来。译文侧的占位符个数由 msgfmt --check 保证与原文一致。
assert_eq "x " "$(_tf 'x %s')" "_tf does not crash when a placeholder has no argument"

# 译文必须真的经过 gettext —— 否则 .po 里写的译文永远用不上。
# 假 gettext 回的是「T[msgid]」，所以这里能看出译文确实被当成了格式串：
# msgid 里的 %s 被参数填掉，输出 T[one x]（不是 T[one %s] x）。
_tf_out=$(PATH="$_fakebin:$PATH" bash -c '. "$1/lib/bootstrap.sh"; _tf "one %s" "x"' _ "$TEST_ROOT")
assert_eq "T[one x]" "$_tf_out" "_tf sends the format string through gettext"
