#!/usr/bin/env bash
#
# 文档门禁。两件事：
#   1. markdown 里带 bash 标记的代码块必须能过 bash -n（片段必须语法自洽）
#   2. 块内出现的 shellkit 函数名必须真实存在 —— 要么在 docs/REFERENCE.md 里，
#      要么在同一个块里用 name() 定义过，要么在 tools/check_docs.allow 白名单里。
#
# 为什么需要第 2 条：函数改名后文档不会报错，只是悄悄变成错的；AI 抓到错的例子
# 会照抄，而且抄得很有信心。这条让文档跟着代码一起红。
#
# 实现：一次 awk 扫完所有 markdown，把每个 bash 代码块落盘、并算出「块内自定义的
# 函数名」与「疑似调用的函数名」；bash 只负责逐块 bash -n 与名字对账。
#   为什么不用「每块跑一遍管道」：原实现每个块要 fork 十几次（grep|sed 抽名字、
#   sed|awk|sort 抽候选、再每个候选两次 grep 查名单）—— 282 个块就是四千多次
#   fork，机器一忙就变成几十秒。改成「一次 awk + 每块一次 bash -n」后，
#   fork 数从四千多降到三百来次。判定口径与失败文案保持逐字不变。
#
#   bash tools/check_docs.sh          # 0 通过；1 有不合格之处
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/shellkit-docs.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# 反引号与代码围栏：用 printf 生成，不在源码里写字面量
BT=$(printf '\140')
FENCE=$(printf '\140\140\140')

# 公开函数集合：REFERENCE 里每个三级标题的函数名就是一条
awk -v bt="$BT" '
  index($0, "### " bt) == 1 {
    s = $0
    sub("^### " bt, "", s)
    sub(bt ".*", "", s)
    print s
  }
' "$ROOT/docs/REFERENCE.md" >"$TMP/allowed"

if [ -f "$ROOT/tools/check_docs.allow" ]; then
  grep -v '^[[:space:]]*#' "$ROOT/tools/check_docs.allow" | grep -v '^[[:space:]]*$' >>"$TMP/allowed"
fi

# POSIX 子集的公开函数也是库函数 —— 设备侧的文档示例会用到它们。
# REFERENCE.md 只收录 lib/core 的模块，POSIX 子集不在其中，所以这里直接
# 从源码扫：手抄的那份名单迟早会漂。
if [ -f "$ROOT/lib/posix/shellkit-posix.sh" ]; then
  awk '/^[A-Za-z_][A-Za-z0-9_]*\(\)[ \t]*\{/ {
    name = $0
    sub(/\(.*/, "", name)
    if (name !~ /^_/) print name
  }' "$ROOT/lib/posix/shellkit-posix.sh" >>"$TMP/allowed"
fi
sort -u "$TMP/allowed" -o "$TMP/allowed"

# 允许清单读进一个字符串：后面查名字用纯 bash 的模式匹配，不用每查一次 fork 一次
# grep（原来每个候选名两次 grep —— 几百个候选就是几百次 fork）。
__allowed_blob=$'\n'"$(cat "$TMP/allowed")"$'\n'

bad=0

# --------------------------------------------------------------------------
# 一次 awk：抽出所有 markdown 里的 bash 代码块，逐块落盘 + 算名字
# --------------------------------------------------------------------------
find "$ROOT" -name '*.md' -not -path '*/.git/*' -not -path '*/.upstream/*' \
  -not -path '*/.superpowers/*' \
  -not -path '*/docs/superpowers/*' -not -path '*/node_modules/*' \
  -not -path '*/site/.vuepress/dist/*' -not -path '*/site/.vuepress/.cache/*' \
  -not -path '*/site/.vuepress/.temp/*' \
  -not -path '*/skills/shellkit/*' | sort >"$TMP/mdfiles"

# 清单文件先建好：整棵树一个代码块都没有时，awk 不会去开它 ——
# 少了这一句，后面读清单就会报「No such file or directory」。
: >"$TMP/blocks.tsv"

awk -v tmp="$TMP" -v manifest="$TMP/blocks.tsv" -v listfile="$TMP/mdfiles" -v fence="$FENCE" '
  function flush_block(file,   i, j, s, t, seg, nseg, nc, key, bp, ip, dp) {
    # 1) 块内容落盘（bash -n 要用）
    bp = tmp "/blk-" bid ".sh"
    printf "" > bp
    for (i = 1; i <= nlines; i++) print body[i] > bp
    close(bp)

    # 2) 块内自定义的函数名（形如 name() 的行）
    dp = tmp "/def-" bid ".txt"
    printf "" > dp
    for (i = 1; i <= nlines; i++) {
      if (match(body[i], /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)/)) {
        s = substr(body[i], RSTART, RLENGTH)
        sub(/[[:space:]]*\(\)$/, "", s)
        sub(/^[[:space:]]+/, "", s)
        print s > dp
      }
    }
    close(dp)

    # 3) 疑似调用的函数名（只看命令位置）
    ip = tmp "/ids-" bid ".txt"
    printf "" > ip
    nc = 0
    for (i = 1; i <= nlines; i++) {
      s = body[i]
      sub(/[[:space:]]#.*$/, "", s)
      sub(/^#.*$/, "", s)
      gsub(/"[^"]*"/, "", s)
      if (s ~ /^[[:space:]]*(local|export|readonly|declare)[[:space:]]/) continue
      if (s ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]+=/) continue
      if (s ~ /^[[:space:]]*\[/) continue
      gsub(/\|\||&&|;|\|/, "\n", s)
      nseg = split(s, seg, "\n")
      for (j = 1; j <= nseg; j++) {
        t = seg[j]
        sub(/^[[:space:]]+/, "", t)
        while (t ~ /^(if|then|else|elif|do|while|until|!|time)[[:space:]]+/) {
          sub(/^(if|then|else|elif|do|while|until|!|time)[[:space:]]+/, "", t)
        }
        sub(/[[:space:]].*$/, "", t)
        if (t ~ /^[a-z][a-z0-9]*(_[a-z0-9]+)+$/) cand[++nc] = t
      }
    }
    # 排序去重（等价 sort -u）
    for (i = 2; i <= nc; i++) {
      key = cand[i]
      j = i - 1
      while (j >= 1 && cand[j] > key) { cand[j + 1] = cand[j]; j-- }
      cand[j + 1] = key
    }
    for (i = 1; i <= nc; i++) {
      if (i > 1 && cand[i] == cand[i - 1]) continue
      print cand[i] > ip
    }
    close(ip)

    print file "\t" bid "\t" bp "\t" ip "\t" dp > manifest
  }
  BEGIN {
    n = 0
    while ((getline f < listfile) > 0) if (f != "") files[++n] = f
    close(listfile)
    bid = 0
    for (fi = 1; fi <= n; fi++) {
      inb = 0
      nlines = 0
      # getline 的返回语义与 bash 的 read 一致：末尾没有换行的最后一行不算一行
      while ((getline line < files[fi]) > 0) {
        if (inb == 0) {
          if (line == fence "bash" || line == fence "sh") {
            inb = 1
            bid++
            nlines = 0
          }
          continue
        }
        if (line == fence) {
          inb = 0
          flush_block(files[fi])
          continue
        }
        body[++nlines] = line
      }
      close(files[fi])
      for (i in body) delete body[i]
    }
    close(manifest)
  }
'

# --------------------------------------------------------------------------
# 逐块检查：语法 + 名字对账
# --------------------------------------------------------------------------
__cur_file=""
# 名单用「首尾都带换行」的形式存，查名字时模式是 *\n名字\n* ——
# 少了开头的换行，第一个名字就永远匹配不上。
__defined_blob=$'\n'
while IFS=$'\t' read -r __f __bid __blk __ids __defs; do
  [ -n "$__f" ] || continue
  if [ "$__f" != "$__cur_file" ]; then
    # 「块内自定义的名字」是**按文件**累积的：同一文件里前一个块定义过的名字，
    # 后一个块里也算已知（与原实现一致）。
    __cur_file=$__f
    __defined_blob=$'\n'
  fi
  if ! bash -n "$__blk" 2>"$TMP/err"; then
    printf '%s: bash syntax error\n' "$__f" >&2
    while IFS= read -r __l; do printf '    %s\n' "$__l"; done <"$TMP/err" >&2
    bad=1
    continue
  fi
  while IFS= read -r __d; do
    [ -n "$__d" ] || continue
    __defined_blob="$__defined_blob$__d"$'\n'
  done <"$__defs"
  while IFS= read -r __id; do
    [ -n "$__id" ] || continue
    case "$__allowed_blob" in
      *$'\n'"$__id"$'\n'*) continue ;;
    esac
    case "$__defined_blob" in
      *$'\n'"$__id"$'\n'*) continue ;;
    esac
    printf '%s: unknown function %s%s%s (not in docs/REFERENCE.md)\n' "$__f" "$BT" "$__id" "$BT" >&2
    bad=1
  done <"$__ids"
done <"$TMP/blocks.tsv"

# --------------------------------------------------------------------------
# 乱码检查：文本文件里不许出现 U+FFFD 替换字符。
#
# 为什么需要：某个文件一旦被工具或编辑器以错误编码写过，中文注释里就会出现
# U+FFFD 替换符（也就是那些「方块问号」）。
# 这种损坏**不会让任何门禁变红** —— bash 照样解析，shellcheck 不看注释，
# 测试也不会因为注释变乱码而失败。但读代码的人看到的是乱码，想改回原意只能靠猜。
# 仓库里真的出现过一次（tools/release.sh 的一条注释），所以这道门是补的。
# --------------------------------------------------------------------------
bad_mojibake=0
while IFS= read -r mf; do
  [ -n "$mf" ] || continue
  printf 'mojibake (U+FFFD) in: %s\n' "${mf#"$ROOT"/}" >&2
  bad_mojibake=1
done < <(grep -rlI $'\xef\xbf\xbd' "$ROOT" \
  --include='*.sh' --include='*.awk' --include='*.md' --include='*.po' \
  --include='*.pot' --include='*.yml' --include='Makefile' \
  --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=dist \
  --exclude-dir=.cache --exclude-dir=.temp --exclude-dir=.upstream \
  2>/dev/null || true)
if [ "$bad_mojibake" -ne 0 ]; then
  bad=1
fi

if [ "$bad" -ne 0 ]; then
  printf 'check_docs: found problems in documentation\n' >&2
  exit 1
fi
printf 'check_docs: ok\n'
