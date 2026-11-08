#!/usr/bin/env bash
#
# 拼装给 AI 读的说明：场景头部 + 共用契约。
#   bash tools/ai_doc.sh repo|project|skill    # markdown 输出到 stdout
#
# 为什么拼装而不是各写一份：三份产物里有大段完全相同的事实（禁用语法、退出码、
# 任务落点）。各写一份必然漂移，而漂移的 AI 说明比没有更糟 —— 它会让人写出错的代码。
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

case "${1:-}" in
  repo | project | skill) __head="$1.head.md" ;;
  *)
    printf 'usage: ai_doc.sh repo|project|skill\n' >&2
    exit 2
    ;;
esac

[ -f "$ROOT/docs/ai/$__head" ] || {
  printf 'ai_doc.sh: missing %s\n' "$ROOT/docs/ai/$__head" >&2
  exit 1
}
[ -f "$ROOT/docs/ai/contract.md" ] || {
  printf 'ai_doc.sh: missing %s\n' "$ROOT/docs/ai/contract.md" >&2
  exit 1
}

cat "$ROOT/docs/ai/$__head" || exit 1
printf '\n'
cat "$ROOT/docs/ai/contract.md" || exit 1
