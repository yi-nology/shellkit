# 把 .po 翻译表编译成纯 bash 查表函数。
#
#   awk -f po_to_sh.awk -v domain=shellkit locale/zh_CN/LC_MESSAGES/shellkit.po \
#     > locale/zh_CN/messages/shellkit.sh
#
# 为什么要有这一步：gettext 不是所有机器都有（macOS 默认没有）。
# 缺 gettext 时 _t 会回落成英文 msgid —— 对「中文优先」的产品就是整片输出变英文。
# 这张表是纯 bash 的兜底：一个巨型 case，查一次 O(1)，不依赖任何外部工具。
#
# 处理要点：
#   1. msgid / msgstr 可以跨多行（续行以 " 开头），要拼起来
#   2. msgstr 为空的条目跳过（未翻译，让它回落成 msgid）
#   3. fuzzy 条目跳过（gettext 也不认 fuzzy 译文，两边行为必须一致）
#   4. case 的 pattern 里 * ? [ ] \ 是元字符，必须转义
#   5. 单引号要转成 '\'' 才能安全放进 shell 单引号串
#
# 域名的函数名后缀：非 [a-z0-9_] 一律换成 _
# （规则和 lib/core/i18n.sh 的 _sk_i18n_fn_suffix 保持一致）

BEGIN {
  if (domain == "") domain = "shellkit"
  fn = "_sk_msg_lookup_" suffix(domain)
  print "# 本文件由 po/messages.sh 生成，请勿手改。"
  print "# 纯 bash 兜底查表：没有 gettext 时 _t 用它出译文。"
  print "# 域：" domain
  print fn "() {"
  print "  case \"$1\" in"
}

# 注释行：#, fuzzy 标的是「还没定稿的译文」，gettext 也不认它
/^#/ {
  if ($0 ~ /fuzzy/) fuzzy = 1
  next
}

# 带上下文的条目（msgctxt）：这张表按 msgid 单键查，存不下，跳过
/^msgctxt/ {
  pending_ctxt = 1
  next
}

# 复数形式：msgid_plural 不单独查；msgstr[0] 才是单数译文
/^msgid_plural/ {
  next
}

/^msgid[ \t]+"/ {
  # 先把上一条收尾（用的是上一条自己的 fuzzy 标记）
  flush()
  entry_fuzzy = fuzzy
  fuzzy = 0
  have_ctxt = pending_ctxt
  pending_ctxt = 0
  msgid = unescape(unquote($0))
  msgstr = ""
  state = "id"
  next
}

/^msgstr\[0\][ \t]+"/ {
  msgstr = unescape(unquote($0))
  state = "str"
  next
}

/^msgstr\[[1-9]/ {
  state = "ignore"
  next
}

/^msgstr[ \t]+"/ {
  msgstr = unescape(unquote($0))
  state = "str"
  next
}

/^"/ {
  if (state == "id") msgid = msgid unescape(unquote($0))
  else if (state == "str") msgstr = msgstr unescape(unquote($0))
  next
}

END {
  flush()
  print "    *) return 1 ;;"
  print "  esac"
  print "}"
}

# flush —— 收掉当前条目
# 空 msgstr（没翻译）与 fuzzy 条目都跳过：让它们回落成 msgid，
# 和 gettext 的行为一致（fuzzy 译文 gettext 也不认）。
function flush() {
  if (msgid != "" && msgstr != "" && !entry_fuzzy && !have_ctxt) {
    printf "    %s) printf '%%s' %s ;;\n", pat(msgid), sq(msgstr)
  }
  msgid = ""
  msgstr = ""
  state = ""
  entry_fuzzy = 0
  have_ctxt = 0
}

# unquote —— 取引号里的原文（转义留着，交给 unescape）
function unquote(s,   t) {
  t = s
  sub(/^[^"]*"/, "", t)
  sub(/"[ \t]*$/, "", t)
  return t
}

# unescape —— 解开 po 的转义：\n \t \r \" \\
function unescape(s,   out, i, c, n) {
  out = ""
  n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c == "\\" && i < n) {
      i++
      c = substr(s, i, 1)
      if (c == "n") out = out "\n"
      else if (c == "t") out = out "\t"
      else if (c == "r") out = out "\r"
      else if (c == "\"") out = out "\""
      else if (c == "\\") out = out "\\"
      else out = out c
    } else {
      out = out c
    }
  }
  return out
}

# pat —— case 的 pattern：* ? [ ] \ 是元字符，必须转义
# 单引号也要转（pattern 外面套的是 shell 单引号串）—— 交给 sq 处理
function pat(s,   out, lit, i, c) {
  out = ""
  lit = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == "*" || c == "?" || c == "[" || c == "]" || c == "\\") {
      # 通配符要脱引号 + 反斜杠转义：bash 的 case pattern 里，
      # 被引号包住的部分按字面匹配，没被引号包住的才是通配符。
      # 整串都用单引号包住的话转义就失效了（'a\*b' 匹配的是带反斜杠的字面量）。
      if (lit != "") {
        out = out sq(lit)
        lit = ""
      }
      out = out "\\" c
    } else {
      lit = lit c
    }
  }
  if (lit != "") out = out sq(lit)
  return out
}

# sq —— shell 单引号串：单引号写成 '\''
function sq(s,   out, i, c) {
  out = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == "'") {
      out = out "'\\''"
    } else {
      out = out c
    }
  }
  return "'" out "'"
}

# suffix —— 域名 -> 函数名后缀（非 [a-z0-9_] 一律换成 _）
function suffix(s,   out, i, c, j) {
  out = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    j = index("ABCDEFGHIJKLMNOPQRSTUVWXYZ", c)
    if (j > 0) {
      out = out substr("abcdefghijklmnopqrstuvwxyz", j, 1)
    } else if (index("abcdefghijklmnopqrstuvwxyz0123456789_", c) > 0) {
      out = out c
    } else {
      out = out "_"
    }
  }
  return out
}
