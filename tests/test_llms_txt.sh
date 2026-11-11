#!/usr/bin/env bash
# llms.txt（给 AI 直读的站点索引）的测试。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

# CASE: 站点同步会生成 llms.txt
bash "$TEST_ROOT/tools/site_sync.sh" >/dev/null 2>&1 || _fail "site_sync.sh failed"
llms="$TEST_ROOT/site/.vuepress/public/llms.txt"
assert_true test -s "$llms"
assert_true test -s "$TEST_ROOT/site/.vuepress/public/en/llms.txt"

# CASE: 条目够多，且链接是绝对的
# 相对链接在站点之外（被别的工具 fetch）时是坏的 —— 那是这个文件存在的理由。
n=$(grep -c '^- \[' "$llms" 2>/dev/null || true)
case "$n" in
  '' | *[!0-9]*) n=0 ;;
esac
if [ "$n" -lt 10 ]; then
  _fail "llms.txt lists only $n entries"
fi
rel=$(grep '^- \[' "$llms" | grep -v 'https://' | head -1 || true)
assert_eq "" "$rel" "llms.txt entries must use absolute URLs"

# CASE: 站点上有的页面，llms.txt 里必须有
# 漏一个页面，AI 就永远看不到那一页 —— 而清单是人手写的，漏是必然的。
missing=""
for f in "$TEST_ROOT"/site/guide/*.md; do
  [ -f "$f" ] || continue
  base=$(basename "$f" .md)
  if ! grep -q "guide/$base.html" "$llms"; then
    missing="$missing $base"
  fi
done
assert_eq "" "$missing" "llms.txt is missing guide pages"
