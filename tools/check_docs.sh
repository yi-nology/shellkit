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
#   bash tools/check_docs.sh          # 0 通过；1 有不合格之处
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/shellkit-docs.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# 公开函数集合：REFERENCE 里每个 ### `name` 就是一条
awk '/^### `/{ s=$0; sub(/^### `/, "", s); sub(/`.*/, "", s); print s }' \
  "$ROOT/docs/REFERENCE.md" >"$TMP/allowed"

if [ -f "$ROOT/tools/check_docs.allow" ]; then
  grep -v '^[[:space:]]*#' "$ROOT/tools/check_docs.allow" | grep -v '^[[:space:]]*$' >>"$TMP/allowed"
fi
sort -u "$TMP/allowed" -o "$TMP/allowed"

bad=0
nblock=0

check_block() {
  local __file=$1 __block=$2 __id
  if ! bash -n "$__block" 2>"$TMP/err"; then
    printf '%s: bash syntax error\n' "$__file" >&2
    sed 's/^/    /' "$TMP/err" >&2
    bad=1
    return 0
  fi

  # 同一块里自定义的函数也算已知（示例常写 cmd_deploy() 这类）
  grep -oE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)' "$__block" 2>/dev/null |
    sed 's/[[:space:]]*()//; s/^[[:space:]]*//' >>"$TMP/defined"

  # 只看「命令位置」的标识符：赋值的右边、local 声明、字符串里的名字都不算。
  # 否则 unit_path=/etc/x 这种变量会被当成不存在的函数。
  sed -e 's/[[:space:]]#.*$//' -e 's/^#.*$//' "$__block" |
    awk '
      # 引号里的内容不参与判断
      { gsub(/"[^"]*"/, """") }
      # 整行赋值 / 声明不是命令
      /^[[:space:]]*(local|export|readonly|declare)[[:space:]]/ { next }
      /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]+=/, /^[[:space:]]*\[/ { next }
      {
        gsub(/\|\||&&|;|\|/, "\n")
        n = split($0, seg, "\n")
        for (i = 1; i <= n; i++) {
          s = seg[i]
          sub(/^[[:space:]]+/, "", s)
          while (s ~ /^(if|then|else|elif|do|while|until|!|time)[[:space:]]+/) {
            sub(/^(if|then|else|elif|do|while|until|!|time)[[:space:]]+/, "", s)
          }
          sub(/[[:space:]].*$/, "", s)
          if (s ~ /^[a-z][a-z0-9]*(_[a-z0-9]+)+$/) print s
        }
      }' | sort -u >"$TMP/ids"

  while IFS= read -r __id; do
    [ -n "$__id" ] || continue
    grep -qxF "$__id" "$TMP/allowed" && continue
    grep -qxF "$__id" "$TMP/defined" && continue
    printf '%s: unknown function `%s` (not in docs/REFERENCE.md)\n' "$__file" "$__id" >&2
    bad=1
  done <"$TMP/ids"
}

while IFS= read -r f; do
  nblock=0
  inb=0
  : >"$TMP/defined"
  while IFS= read -r line; do
    if [ "$inb" -eq 0 ]; then
      case "$line" in
        '```bash' | '```sh')
          inb=1
          nblock=$((nblock + 1))
          : >"$TMP/blk.sh"
          ;;
      esac
      continue
    fi
    case "$line" in
      '```')
        inb=0
        check_block "$f" "$TMP/blk.sh"
        ;;
      *) printf '%s\n' "$line" >>"$TMP/blk.sh" ;;
    esac
  done <"$f"
  # docs/superpowers/ 是设计档案，不是给人照抄的示例，不纳入校验
done < <(find "$ROOT" -name '*.md' -not -path '*/.git/*' -not -path '*/.upstream/*' \
  -not -path '*/docs/superpowers/*' | sort)

if [ "$bad" -ne 0 ]; then
  printf 'check_docs: found problems in documentation\n' >&2
  exit 1
fi
printf 'check_docs: ok\n'
