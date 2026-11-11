#!/usr/bin/env bash
#
# 构建产物链接门禁。
#
# 为什么需要它：@vuepress/theme-default 自带的 links-check 实测**不会**让坏链导致构建
# 失败（构建照样 rc=0），所以「页面 404 而 CI 全绿」是完全可能的。这道门在产物上跑：
# 每个内部 href/src 都必须命中真实文件。
#
# 顺带校验首页上的版本号 —— 站点是最容易「挂着上一版下载按钮」的地方。
#
#   bash tools/site_links.sh [dist 目录]   # 0 通过；3 没有产物；5 有问题
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="${SITE_BASE:-/shellkit/}"
DIST="${1:-$ROOT/site/.vuepress/dist}"

_die() {
  printf '[site-links] ERROR: %s\n' "$*" >&2
  exit "${2:-5}"
}

[ -d "$DIST" ] || _die "no build output at $DIST; run npm run build first" 3

TMP=$(mktemp -d "${TMPDIR:-/tmp}/shellkit-links.XXXXXX") || _die 'mktemp failed' 3
trap 'rm -rf "$TMP"' EXIT

find "$DIST" -type f -name '*.html' >"$TMP/pages" || _die 'find failed' 3
__npages=$(wc -l <"$TMP/pages" | tr -d ' ')
[ "$__npages" -gt 0 ] || _die "no html files under $DIST" 5

# 每条链接连同它所在页面的目录一起记下来，否则相对路径没法判定
while IFS= read -r __f; do
  __rel=${__f#"$DIST"/}
  __dir=$(dirname "$__rel")
  [ "$__dir" != '.' ] || __dir=''
  grep -oE '(href|src)="[^"]+"' "$__f" | sed -E 's/^(href|src)="//; s/"$//' |
    while IFS= read -r __l; do
      printf '%s\t%s\n' "$__dir" "$__l"
    done
done <"$TMP/pages" >"$TMP/raw"

LC_ALL=C sort -u "$TMP/raw" >"$TMP/links"

__nlinks=0
__bad=0

while IFS=$'\t' read -r __dir __link; do
  case "$__link" in
    '' | '#'*) continue ;;
    http://* | https://* | //* | mailto:* | data:* | javascript:*) continue ;;
  esac

  __path=${__link%%#*}
  __path=${__path%%\?*}
  [ -n "$__path" ] || continue

  case "$__path" in
    /*)
      case "$__path" in
        "$BASE"*) __path=${__path#"$BASE"} ;;
        *) __path=${__path#/} ;;
      esac
      ;;
    *)
      if [ -n "$__dir" ]; then
        __path="$__dir/$__path"
      fi
      ;;
  esac

  __path=${__path%%/}
  [ -n "$__path" ] || __path='index.html'

  __nlinks=$((__nlinks + 1))
  [ -f "$DIST/$__path" ] && continue
  [ -f "$DIST/$__path.html" ] && continue
  [ -f "$DIST/$__path/index.html" ] && continue

  __bad=$((__bad + 1))
  if [ "$__bad" -le 20 ]; then
    printf '[site-links] missing: %s (from %s)\n' "$__link" "${__dir:-/}" >&2
  fi
done <"$TMP/links"

# 首页版本号：释放按钮是手抄的，发版漏改只看门禁是绿的
__ver=$(tr -d '[:space:]' <"$ROOT/VERSION")
for __pair in 'index.html:下载 ' 'en/index.html:Download '; do
  __file=${__pair%%:*}
  __needle=${__pair#*:}
  if [ ! -f "$DIST/$__file" ]; then
    printf '[site-links] missing page: %s\n' "$__file" >&2
    __bad=$((__bad + 1))
    continue
  fi
  if ! grep -qF "$__needle$__ver" "$DIST/$__file"; then
    printf '[site-links] %s: no "%s%s" (VERSION says %s)\n' \
      "$__file" "$__needle" "$__ver" "$__ver" >&2
    __bad=$((__bad + 1))
  fi
  # VERSION= 出现在代码块里，prism 会把它切成 VERSION / = / 值 三个 span，
  # 所以这一条要在剥掉标签之后的文本上匹配，否则永远判定为缺失。
  sed 's/<[^>]*>//g' "$DIST/$__file" >"$TMP/page.txt"
  if ! grep -qF "VERSION=$__ver" "$TMP/page.txt"; then
    printf '[site-links] %s: no "VERSION=%s"\n' "$__file" "$__ver" >&2
    __bad=$((__bad + 1))
  fi
done

# llms.txt 必须真的在产物里：它是给 AI 直读的入口，少了它整条链路断在最后一步。
# 顺带数条目：空文件或只剩一两行的 llms.txt 同样是坏的（页面清单没生成出来）。
for __llms in llms.txt en/llms.txt; do
  if [ ! -s "$DIST/$__llms" ]; then
    printf '[site-links] missing: %s\n' "$__llms" >&2
    __bad=$((__bad + 1))
    continue
  fi
  __n=$(grep -c '^- \[' "$DIST/$__llms" 2>/dev/null || true)
  case "$__n" in
    '' | *[!0-9]*) __n=0 ;;
  esac
  if [ "$__n" -lt 10 ]; then
    printf '[site-links] %s lists only %s entries\n' "$__llms" "$__n" >&2
    __bad=$((__bad + 1))
  fi
done

if [ "$__bad" -ne 0 ]; then
  printf 'site-links: %s problem(s) across %s pages\n' "$__bad" "$__npages" >&2
  exit 5
fi

printf 'site-links: ok (%s pages, %s internal links)\n' "$__npages" "$__nlinks"
exit 0
