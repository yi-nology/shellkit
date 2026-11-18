#!/usr/bin/env bash
#
# CHANGELOG 选「上一个已发布版本」的口径（issue #142）。
#
# 缺陷：原来用 git tag --sort=v:refname —— 字典序会把预发布 tag
# （v1.0.0-rc.1）排在正式版（v1.0.0）**之后** ⇒ GA 发版时选到 RC，
# 生成的小节只含「RC 之后」的提交 —— RC 与 GA 同批时那一段是**空的**，
# 看起来像「这版什么都没改」（v1.0.0 的 CHANGELOG 段就是这样空的）。
#
# 判据：临时 git 仓库里造 tag，直接测选择结果。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

PREV="$TEST_ROOT/tools/changelog_prev.sh"
REPO="$TEST_TMP_ROOT/prev-repo"

assert_file() { [ -f "$1" ] || _fail "missing file: $1"; }
assert_file "$PREV"

# 造一个带 tag 的临时仓库
mkdir -p "$REPO" || _fail "mkdir failed"
git -C "$REPO" init -q 2>/dev/null || _fail "git init failed"
git -C "$REPO" config user.email t@t.t || _fail "git config failed"
git -C "$REPO" config user.name t || _fail "git config failed"
printf 'x\n' >"$REPO/f" || _fail "write failed"
git -C "$REPO" add f || _fail "git add failed"
git -C "$REPO" commit -q -m init || _fail "git commit failed"
for t in v0.27.0 v1.0.0 v1.0.0-rc.1 v1.1.0; do
  git -C "$REPO" tag "$t" || _fail "git tag failed: $t"
done

# 在临时仓库里跑（脚本用 git tag -l ⇒ 必须在该仓库的上下文里跑）
prev_in() {
  ( cd "$REPO" && bash "$PREV" "$1" 2>/dev/null ) || true
}

# CASE: GA 发版 ⇒ 基准是上一个**正式版**（跳过 RC）
#   v1.1.0 的上一个正式版是 v1.0.0 —— 不是 v1.0.0-rc.1（字典序会选到它）
assert_eq "v1.0.0" "$(prev_in 1.1.0)" \
  "a GA release must use the previous GA tag as the changelog base"

# CASE: GA 发版且 RC 是最近的那个 tag ⇒ 也不能选 RC
#   仓库里有 v1.0.0-rc.1（refname 字典序排在 v1.0.0 之后）——
#   GA 1.0.0 的基准必须是 v0.27.0，不是 v1.0.0-rc.1
assert_eq "v0.27.0" "$(prev_in 1.0.0)" \
  "a GA release must skip prerelease tags even when they are newer in refname order"

# CASE: 预发布发版 ⇒ 基准是上一个已发布版本（含预发布）
assert_eq "v0.27.0" "$(prev_in 1.0.0-rc.1)" \
  "a prerelease must use the previous released tag as the changelog base"

# CASE: 没有任何更早的 tag ⇒ 输出空（不是最后一个 tag）
assert_eq "" "$(prev_in 0.1.0)" \
  "there is no previous tag before 0.1.0"

# CASE: 更后面的正式版存在时，取最新的那个正式版
assert_eq "v1.1.0" "$(prev_in 1.2.0)" \
  "the changelog base must be the newest release older than the version being released"

exit 0
