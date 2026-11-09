#!/usr/bin/env bash
#
# 门禁：文档里写的「N 个模块」必须与 lib/modules.txt 里的实际模块数一致。
#
# 为什么需要这道门：模块数在 README、首页、模块地图、FAQ、迁移指南里各手抄了一份。
# 加一个模块要改六个地方，漏一处的后果不是报错，而是网页上写着「17 个模块」、
# 实际已经是 18 个 —— 读者按这句话去找模块会少一个。
# 这跟「Cookbook 场景数」是同一类腐化：承诺与事实错位，所以同样用门禁钉住。
#
# 真相源：lib/modules.txt 第一列的非空、非注释行数。
#
#   bash tools/check_module_count.sh   # 0 通过；5 对不上
set -u

# SHELLKIT_CHECK_ROOT 只给自测用：在一棵假的树副本上跑本门禁。
ROOT="${SHELLKIT_CHECK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)}"
MANIFEST="$ROOT/lib/modules.txt"

if [ ! -f "$MANIFEST" ]; then
  printf 'check_module_count: %s not found\n' "$MANIFEST" >&2
  exit 1
fi

n=0
while IFS= read -r __line || [ -n "$__line" ]; do
  __line="${__line%%#*}"
  case "$__line" in
    '' | ' '*) continue ;;
  esac
  __name="${__line%%[[:space:]]*}"
  [ -n "$__name" ] || continue
  n=$((n + 1))
done <"$MANIFEST"

if [ "$n" -eq 0 ]; then
  printf 'check_module_count: cannot count modules in %s\n' "$MANIFEST" >&2
  exit 1
fi

bad=0

# 期望写法：中文页写「N 个模块」，英文页写「N modules」。
# 文件里压根没提数量就不管（不是每个页面都非得报数）。
check() {
  local __file=$1
  [ -f "$__file" ] || return 0
  grep -qE '个模块|modules' "$__file" || return 0
  if ! grep -qF "$n 个模块" "$__file"; then
    printf '%s: 模块数应为 %s 个（中文页写「%s 个模块」）\n' "${__file#"$ROOT"/}" "$n" "$n" >&2
    bad=1
  fi
}

for __f in \
  "$ROOT/README.md" \
  "$ROOT/docs/MIGRATING.md" \
  "$ROOT/site/index.md" \
  "$ROOT/site/guide/index.md" \
  "$ROOT/site/guide/modules.md" \
  "$ROOT/site/guide/faq.md"; do
  check "$__f"
done

# 英文页：写了模块数就必须也是同一个数
for __f in "$ROOT"/site/en/*.md "$ROOT"/site/en/guide/*.md; do
  [ -f "$__f" ] || continue
  grep -qE '[0-9]+ modules' "$__f" || continue
  if ! grep -qF "$n modules" "$__f"; then
    printf '%s: 模块数应为 %s（英文页写「%s modules」）\n' "${__file#"$ROOT"/}" "$n" "$n" >&2
    bad=1
  fi
done

if [ "$bad" -ne 0 ]; then
  printf 'check_module_count: 文档里的模块数与 lib/modules.txt 对不上\n' >&2
  exit 5
fi
printf 'check_module_count: ok (%s modules)\n' "$n"
exit 0
