#!/usr/bin/env bash
#
# 生成 llms.txt —— 给 AI 直读的站点索引。
#
#   bash tools/llms_txt.sh
#
# 产物：site/.vuepress/public/llms.txt（中文）与 site/.vuepress/public/en/llms.txt（英文）。
#
# 为什么要有：AI 拿到一个站点，只能自己抓首页再顺着链接找；llms.txt 是
# 一份「页面清单 + 一句话说明」，一个文件读完整个站点的地图。
#
# 清单是**扫出来的**（站点里真实存在的页面），不是手抄的：手抄的那份必然
# 跟站点分叉 —— 加了页面忘了改 llms.txt，AI 就永远看不到新页面。
# 唯一手写的是「哪些页面排在前面」，那只是顺序偏好，漏掉的页会按字母序补在后面。
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SITE="$ROOT/site"
BASE="${SHELLKIT_SITE_BASE:-https://yi-nology.github.io/shellkit}"
BASE="${BASE%/}"

[ -d "$SITE" ] || {
  printf 'llms_txt: missing %s\n' "$SITE" >&2
  exit 3
}

die() {
  printf 'llms_txt: %s\n' "$1" >&2
  exit "${2:-1}"
}

# _title FILE —— 页面标题：frontmatter 的 title，没有就用首个一级标题
_title() {
  local __f=$1 __t
  __t=$(sed -n 's/^title:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' "$__f" | sed -n '1p')
  if [ -z "$__t" ]; then
    __t=$(awk '/^# / { sub(/^# +/, ""); print; exit }' "$__f")
  fi
  printf '%s' "$__t"
}

# _summary FILE —— 一句话说明：正文的第一段
_summary() {
  local __f=$1 __s
  __s=$(awk '
    NR == 1 && $0 ~ /^---/ { fm = 1; next }
    fm && $0 ~ /^---/ { fm = 0; next }
    fm { next }
    /^```/ { inb = !inb; next }
    inb { next }
    /^#/ { next }
    /^>/ { next }
    /^\[/ { next }
    /^\|/ { next }
    /^!/ { next }
    /^:::/ { next }
    /^<!--/ { next }
    /^$/ { next }
    { print; exit }
  ' "$__f")
  printf '%s' "$__s"
}

# _entry REL —— 输出一行条目；页面不存在就跳过
_entry() {
  local __rel=$1 __f="$SITE/$1" __url __title __sum
  [ -f "$__f" ] || return 0
  __url="$BASE/${__rel%.md}.html"
  __title=$(_title "$__f")
  __sum=$(_summary "$__f")
  if [ -n "$__sum" ]; then
    printf -- '- [%s](%s): %s\n' "$__title" "$__url" "$__sum"
  else
    printf -- '- [%s](%s)\n' "$__title" "$__url"
  fi
}

# _guide_entries LANG —— 指南页：常用页面在前，其余按字母序补在后面
_guide_entries() {
  local __lang=$1 __prefix __f __name
  if [ "$__lang" = "en" ]; then
    __prefix="en/guide/"
  else
    __prefix="guide/"
  fi
  for __name in index installation quickstart conventions bash32 modules \
    cookbook cli i18n testing ai examples man migrating releasing \
    contributing troubleshooting faq; do
    _entry "$__prefix$__name.md"
  done
  # 剩下的页面按字母序补上：新加的页面不会因为「不在优先列表里」而消失
  __known=" index installation quickstart conventions bash32 modules cookbook cli i18n testing ai examples man migrating releasing contributing troubleshooting faq "
  for __f in "$SITE/$__prefix"*.md; do
    [ -f "$__f" ] || continue
    __name=$(basename "$__f" .md)
    case "$__known" in
      *" $__name "*) continue ;;
    esac
    _entry "$__prefix$__name.md"
  done
}

# _reference_entries LANG —— API 参考页
_reference_entries() {
  local __lang=$1 __prefix __f __name
  if [ "$__lang" = "en" ]; then
    __prefix="en/reference/"
  else
    __prefix="reference/"
  fi
  _entry "${__prefix}index.md"
  for __f in "$SITE/$__prefix"*.md; do
    [ -f "$__f" ] || continue
    __name=$(basename "$__f" .md)
    [ "$__name" = "index" ] && continue
    _entry "${__prefix}$__name.md"
  done
}

mkdir -p "$SITE/.vuepress/public/en" || die "cannot create the public directory" 1

# ---------- 中文版 ----------

{
  printf '# shellkit\n\n'
  printf '> 写运维 shell 的起点：一个约束清晰的 Bash 库、一个脚手架生成器、一套 CLI 框架。基线 Bash 3.2+。\n\n'
  printf 'stdout 只给数据，日志一律 stderr；失败有固定退出码；同一条命令跑一百遍和跑一遍结果一样。\n\n'

  printf '## 开始\n\n'
  _guide_entries zh

  printf '\n## API 参考\n\n'
  printf '每个公开函数的签名与退出码，由源码注释生成，不会和代码漂移。\n\n'
  _reference_entries zh

  printf '\n## 英文文档\n\n'
  printf -- '- [Guide](%s/en/guide/index.html)\n' "$BASE"
  printf -- '- [API reference](%s/en/reference/index.html)\n' "$BASE"
} >"$SITE/.vuepress/public/llms.txt.tmp.$$" || die "cannot write llms.txt" 1
mv -f "$SITE/.vuepress/public/llms.txt.tmp.$$" "$SITE/.vuepress/public/llms.txt" || die "cannot write llms.txt" 1

# ---------- 英文版 ----------

{
  printf '# shellkit\n\n'
  printf '> A Bash library, project generator and CLI framework with explicit constraints. Baseline: Bash 3.2+.\n\n'
  printf 'stdout carries data only, logs go to stderr; failures have fixed exit codes; running a command a hundred times gives the same result.\n\n'

  printf '## Getting started\n\n'
  _guide_entries en

  printf '\n## API reference\n\n'
  printf 'Signatures and exit codes of every public function, generated from the source comments.\n\n'
  _reference_entries en
} >"$SITE/.vuepress/public/en/llms.txt.tmp.$$" || die "cannot write en/llms.txt" 1
mv -f "$SITE/.vuepress/public/en/llms.txt.tmp.$$" "$SITE/.vuepress/public/en/llms.txt" || die "cannot write en/llms.txt" 1

printf 'llms_txt: wrote %s and %s\n' \
  "$SITE/.vuepress/public/llms.txt" "$SITE/.vuepress/public/en/llms.txt" >&2
exit 0
