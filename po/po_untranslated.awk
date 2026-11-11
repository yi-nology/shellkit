# 数 .po 里「没有译文」的条目。
#
#   awk -f po/po_untranslated.awk locale/zh_CN/LC_MESSAGES/shellkit.po
#
# 每行输出一个没译文的 msgid（文件头不算）—— 行数就是「缺译文的条目数」。
#
# 为什么不用 msgattrib --untranslated：
# gettext 的版本之间对「折行译文」（msgstr "" + 续行）的判定不一致 ——
# 0.21（Ubuntu/CI）把它当没译文，1.0（macOS/Homebrew）不当。
# 同一份 po 在 CI 上数出 2 个「没译文」，本机数 0 ⇒ 假红。
# 译文在不在，得由我们自己解折行来判，不能交给一个会变脸的外部工具。
#
# 处理要点：
#   1. msgid / msgstr 可以跨多行（续行以 " 开头），拼起来再判
#   2. msgid 为空的是文件头，不算「缺译文的条目」
#   3. 复数条目看 msgstr[0]

BEGIN {
  state = ""
}

/^#/ { next }

/^msgctxt[ \t]+"/ { next }

/^msgid_plural/ { next }

/^msgid[ \t]+"/ {
  flush()
  msgid = unquote($0)
  msgstr = ""
  state = "id"
  next
}

/^msgstr\[0\][ \t]+"/ {
  msgstr = unquote($0)
  state = "str"
  next
}

/^msgstr\[[1-9]/ { next }

/^msgstr[ \t]+"/ {
  msgstr = unquote($0)
  state = "str"
  next
}

/^"/ {
  if (state == "id") msgid = msgid unquote($0)
  else if (state == "str") msgstr = msgstr unquote($0)
  next
}

END {
  flush()
}

# flush —— 收掉当前条目：msgid 非空（不是文件头）且 msgstr 为空 ⇒ 缺译文
function flush() {
  if (msgid != "" && msgstr == "") {
    print msgid
  }
  msgid = ""
  msgstr = ""
  state = ""
}

# unquote —— 取引号里的原文（转义留着，够用来认人）
function unquote(s,   t) {
  t = s
  sub(/^[^"]*"/, "", t)
  sub(/"[ \t]*$/, "", t)
  return t
}
