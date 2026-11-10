#!/usr/bin/env bash
#
# 门禁自测：check_versions.sh 的「裸版本号」检查必须覆盖 README.md ——
# 正文里写死的版本号发版后与 VERSION 不一致，此前只有 4 个站点页被查，
# README 里的同类漏改活过发版也没人拦（issue #34）。
# 同时守住判据的形状：IP 这类四段点分数字不是版本号，不该被误拦。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

GATE="$TEST_ROOT/tools/check_versions.sh"
FAKE="$TEST_TMP_ROOT/fake-root"

mkdir -p "$FAKE/site/guide" "$FAKE/site/en/guide" "$FAKE/locale" || _fail "mkdir failed"
cp "$GATE" "$FAKE/tools_gate.sh" 2>/dev/null || {
  mkdir -p "$FAKE"
  cp "$GATE" "$FAKE/tools_gate.sh"
}
for f in VERSION README.md CHANGELOG.md \
  site/index.md site/en/index.md \
  site/guide/installation.md site/en/guide/installation.md \
  locale/shellkit.pot; do
  cp "$TEST_ROOT/$f" "$FAKE/$f" || _fail "cannot copy $f"
done

run_gate() {
  SHELLKIT_CHECK_ROOT="$FAKE" bash "$FAKE/tools_gate.sh" 2>&1
}

# 好树：所有引用一致，必须绿
out=$(run_gate) || _fail "一致的树应该通过，实际输出：$out"

# 坏树 1：README 里的裸版本号 —— 必须红，且点名 README
cp "$FAKE/README.md" "$FAKE/README.md.bak"
printf '\n当前版本 0.9.9\n' >>"$FAKE/README.md"
out=$(run_gate) && _fail "README 里的裸版本号门禁必须红"
case "$out" in
  *README*stray* | *README*0.9.9*) ;;
  *) _fail "门禁没有说明是 README 漂移：$out" ;;
esac

# 坏树 2：站点首页的裸版本号（原有覆盖面的回归）
mv "$FAKE/README.md.bak" "$FAKE/README.md"
cp "$FAKE/site/index.md" "$FAKE/site/index.md.bak"
printf '\n当前版本 0.9.8\n' >>"$FAKE/site/index.md"
out=$(run_gate) && _fail "站点首页里的裸版本号门禁必须红"
mv "$FAKE/site/index.md.bak" "$FAKE/site/index.md"

# 形状判据：四段点分数字是 IP（README 的 /etc/hosts 示例），不是版本号 —— 不拦
printf 'fs_ensure_line /etc/hosts "10.0.0.5 db"\n' >>"$FAKE/README.md"
out=$(run_gate) || _fail "IP 形态的四段数字不该被当成裸版本号：$out"

# 还原之后必须重新变绿
out=$(run_gate) || _fail "修好之后应该重新通过，实际输出：$out"
