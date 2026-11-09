#!/usr/bin/env bash
#
# 门禁：文档里写的「Cookbook 有多少个场景」必须与实际场景数一致。
#
# 为什么需要这条：README、首页、指南页都写着「N 个场景」。加一个场景时，
# 忘记改这几个手抄的数字，读者点进去数一遍发现对不上 —— 这是最廉价的一种
# 文档腐化：不是内容错，是承诺与事实错位。
#
# 场景数只有一个真相源：docs/COOKBOOK.md 里「## N. 标题」的个数。
#
#   bash tools/check_cookbook_count.sh   # 0 通过；1 对不上
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COOKBOOK="$ROOT/docs/COOKBOOK.md"

if [ ! -f "$COOKBOOK" ]; then
  printf 'check_cookbook_count: %s not found\n' "$COOKBOOK" >&2
  exit 1
fi

n=$(grep -c '^## [0-9][0-9]*\.' "$COOKBOOK" 2>/dev/null || true)
case "$n" in
  '' | *[!0-9]*)
    printf 'check_cookbook_count: cannot count scenarios in %s\n' "$COOKBOOK" >&2
    exit 1
    ;;
esac

bad=0

# 期望写法：中文页写「N 个场景」，英文页写「N scenarios」。
# 文件里压根没提数量就不管（不是每个页面都非得报数）。
check() {
  local __file=$1 __pat=$2
  [ -f "$__file" ] || return 0
  grep -qE '个场景|scenarios' "$__file" || return 0
  if ! grep -qF "$__pat" "$__file"; then
    printf '%s: 场景数应为 %s，实际写的不是这个数\n' "${__file#"$ROOT"/}" "$n" >&2
    bad=1
  fi
}

check "$ROOT/README.md" "$n 个场景"
check "$ROOT/site/index.md" "$n 个场景"
check "$ROOT/site/guide/index.md" "$n 个场景"
check "$ROOT/site/en/guide/index.md" "$n scenarios"

if [ "$bad" -ne 0 ]; then
  printf 'check_cookbook_count: the documented scenario count is out of date\n' >&2
  exit 1
fi
printf 'check_cookbook_count: ok (%s scenarios)\n' "$n"
exit 0
