#!/usr/bin/env bash
#
# 从源码抽取 msgid 并编译译文。
#
#   bash po/messages.sh            # 重新生成 pot + 合并既有 po + 编译 mo
#   bash po/messages.sh --check    # 只检查：不写文件，缺 msgfmt 时跳过
#
# msgid 一律英文（源码里 _t '...' 的原样），译文只进 locale/<lang>/LC_MESSAGES。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"
POT="$ROOT/locale/shellkit.pot"
CHECK_ONLY=0

if [ "${1:-}" = "--check" ]; then
  CHECK_ONLY=1
fi

if ! command -v xgettext >/dev/null 2>&1; then
  printf 'po: xgettext not found, skipping message extraction\n' >&2
  exit 0
fi

sources=()
for f in "$ROOT/lib/bootstrap.sh" "$ROOT"/lib/core/*.sh "$ROOT/shellkit" "$ROOT"/templates/bin/__NAME__ "$ROOT"/templates/lib/app.sh "$ROOT"/templates/commands/__CMD__.sh; do
  if [ -f "$f" ]; then
    sources[${#sources[@]}]="$f"
  fi
done

if [ "$CHECK_ONLY" = "1" ]; then
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' EXIT
  xgettext --language=Shell --keyword=_t --from-code=UTF-8 \
    --package-name=shellkit --package-version="$(tr -d '[:space:]' <"$ROOT/VERSION")" \
    -o "$tmp" "${sources[@]}"
  # 只比内容。注释行（#: 行号）与 POT-Creation-Date 每次生成都会变，
  # 把它们算进来，这条检查在隔了一分钟之后必然报「消息变了」，等于永远过不了。
  strip_header() { grep -v '^#' "$1" | grep -v '^"POT-Creation-Date:'; }
  if [ -f "$POT" ] && ! diff -q <(strip_header "$POT") <(strip_header "$tmp") >/dev/null; then
    printf 'po: messages changed, run bash po/messages.sh\n' >&2
    exit 1
  fi
  exit 0
fi

xgettext --language=Shell --keyword=_t --from-code=UTF-8 \
  --package-name=shellkit --package-version="$(tr -d '[:space:]' <"$ROOT/VERSION")" \
  --add-comments=TRANSLATORS \
  -o "$POT" "${sources[@]}"
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
    exit 0
  fi
  for po in "$ROOT"/locale/*/LC_MESSAGES/shellkit.po; do
    if [ ! -f "$po" ]; then
      continue
    fi
    msgfmt --check -o "${po%.po}.mo" "$po"
    printf 'po: compiled %s\n' "${po#"$ROOT"/}"
  done
fi
