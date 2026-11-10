#!/usr/bin/env bash
#
# 从源码抽取 msgid 并编译译文。
#
#   bash po/messages.sh            # 重新生成 pot + 合并既有 po + 编译 mo + 生成纯 bash 兜底表
#   bash po/messages.sh --check    # 只检查：不写文件，缺 msgfmt 时跳过
#
# msgid 一律英文（源码里 _t '...' 的原样），译文只进 locale/<lang>/LC_MESSAGES。
#
# 纯 bash 兜底表（locale/<lang>/messages/<domain>.sh）也在这里生成：
# 没有 gettext 的机器靠它出译文。表是生成物，但必须入库 ——
# --check 会把它跟现生成的表逐字节比对，漂了就红。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"
POT="$ROOT/locale/shellkit.pot"
PO_TO_SH="$ROOT/po/po_to_sh.awk"
CHECK_ONLY=0

if [ "${1:-}" = "--check" ]; then
  CHECK_ONLY=1
fi

# 临时目录：退出时清掉
TMP_CLEAN=""
cleanup() {
  if [ -n "${TMP_CLEAN:-}" ]; then
    rm -rf "$TMP_CLEAN"
  fi
}
trap cleanup EXIT

# 缺 xgettext 的机器上跳过抽取（跟原来一样不当失败），
# 但兜底表的比对照样要跑 —— 那一步只需要 awk。
HAVE_XGETTEXT=1
if ! command -v xgettext >/dev/null 2>&1; then
  printf 'po: xgettext not found, skipping message extraction\n' >&2
  HAVE_XGETTEXT=0
fi

cd "$ROOT"

if [ "$HAVE_XGETTEXT" = "1" ]; then
  sources=()
  for f in lib/bootstrap.sh lib/core/*.sh shellkit \
    templates/bin/__NAME__ templates/lib/app.sh templates/commands/__CMD__.sh; do
    if [ -f "$f" ]; then
      sources[${#sources[@]}]=$f
    fi
  done

  XGETTEXT_ARGS=(
    --language=Shell --keyword=_t --from-code=UTF-8 --no-location
    --package-name=shellkit --package-version="$(tr -d '[:space:]' <VERSION)"
  )

  if [ "$CHECK_ONLY" = "1" ]; then
    TMP_CLEAN="$(mktemp -d "${TMPDIR:-/tmp}/shellkit-po.XXXXXX")"
    tmp="$TMP_CLEAN/pot"
    xgettext "${XGETTEXT_ARGS[@]}" -o "$tmp" "${sources[@]}"
    # 只比内容。注释行（#: 行号）与 POT-Creation-Date 每次生成都会变，
    # 把它们算进来，这条检查在隔了一分钟之后必然报「消息变了」，等于永远过不了。
    strip_header() { grep -v '^#' "$1" | grep -v '^"POT-Creation-Date:'; }
    if [ -f "$POT" ] && ! diff -q <(strip_header "$POT") <(strip_header "$tmp") >/dev/null; then
      printf 'po: messages changed, run bash po/messages.sh\n' >&2
      exit 1
    fi
  else
    xgettext "${XGETTEXT_ARGS[@]}" --add-comments=TRANSLATORS -o "$POT" "${sources[@]}"
    printf 'po: wrote %s\n' "${POT#"$ROOT"/}"

    need_msgfmt=0
    for po in "$ROOT"/locale/*/LC_MESSAGES/shellkit.po; do
      if [ ! -f "$po" ]; then
        continue
      fi
      if command -v msgmerge >/dev/null 2>&1; then
        msgmerge --quiet --update --backup=none "$po" "$POT"
      fi
      need_msgfmt=1
    done

    if [ "$need_msgfmt" = "1" ]; then
      if ! command -v msgfmt >/dev/null 2>&1; then
        printf 'po: msgfmt not found, .mo files were not rebuilt\n' >&2
      else
        for po in "$ROOT"/locale/*/LC_MESSAGES/shellkit.po; do
          if [ ! -f "$po" ]; then
            continue
          fi
          msgfmt --check -o "${po%.po}.mo" "$po"
          printf 'po: compiled %s\n' "${po#"$ROOT"/}"
        done
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 纯 bash 兜底表：locale/<lang>/messages/<domain>.sh
#
# 表里是一个巨型 case：_sk_msg_lookup_<domain> MSG。
# 查一次 O(1)，不依赖任何外部工具 —— 没有 gettext 的机器靠它出译文。
# ---------------------------------------------------------------------------
if ! command -v awk >/dev/null 2>&1; then
  printf 'po: awk not found, skipping the pure-bash fallback tables\n' >&2
  exit 0
fi
if [ ! -f "$PO_TO_SH" ]; then
  printf 'po: %s not found, skipping the pure-bash fallback tables\n' "${PO_TO_SH#"$ROOT"/}" >&2
  exit 0
fi

# table_list —— 打印 "<lang> <domain> <po 路径>"（制表符分隔，路径里有空格也不怕）
table_list() {
  local __po __langdir __lang __domain
  for __po in "$ROOT"/locale/*/LC_MESSAGES/*.po; do
    [ -f "$__po" ] || continue
    __langdir="${__po%/*}"
    __langdir="${__langdir%/*}"
    __lang="${__langdir##*/}"
    __domain="${__po##*/}"
    __domain="${__domain%.po}"
    printf '%s\t%s\t%s\n' "$__lang" "$__domain" "$__po"
  done
}

TMP_CLEAN="$(mktemp -d "${TMPDIR:-/tmp}/shellkit-po.XXXXXX")"

if [ "$CHECK_ONLY" = "1" ]; then
  __bad=0
  while IFS=$'\t' read -r __lang __domain __po; do
    [ -n "$__lang" ] || continue
    __want="$TMP_CLEAN/table.sh"
    awk -f "$PO_TO_SH" -v domain="$__domain" "$__po" >"$__want"
    __have="$ROOT/locale/$__lang/messages/$__domain.sh"
    if [ ! -f "$__have" ]; then
      printf 'po: fallback table is missing: %s (run bash po/messages.sh)\n' "${__have#"$ROOT"/}" >&2
      __bad=1
      continue
    fi
    if ! cmp -s "$__want" "$__have"; then
      printf 'po: fallback table is stale: %s (run bash po/messages.sh)\n' "${__have#"$ROOT"/}" >&2
      __bad=1
    fi
  done < <(table_list)
  if [ "$__bad" -ne 0 ]; then
    exit 1
  fi
else
  while IFS=$'\t' read -r __lang __domain __po; do
    [ -n "$__lang" ] || continue
    mkdir -p "$ROOT/locale/$__lang/messages"
    __tmp="$TMP_CLEAN/table.sh"
    awk -f "$PO_TO_SH" -v domain="$__domain" "$__po" >"$__tmp"
    mv -f "$__tmp" "$ROOT/locale/$__lang/messages/$__domain.sh"
    printf 'po: wrote fallback table locale/%s/messages/%s.sh\n' "$__lang" "$__domain"
  done < <(table_list)
fi
