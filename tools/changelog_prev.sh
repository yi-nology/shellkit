#!/usr/bin/env bash
#
# 选「上一个已发布版本」—— 给 CHANGELOG 生成用。
#
#   bash tools/changelog_prev.sh VER
#
# 输出：上一个已发布版本的 tag（vX.Y.Z），没有则输出空。
#
# 为什么不能用 git tag --sort=v:refname：那是**字典序**，会把预发布 tag
# （v1.0.0-rc.1）排在正式版（v1.0.0）**之后** ⇒ GA 发版时选到 RC，
# 生成的小节只含「上一轮 RC 之后」的提交 —— RC 与 GA 常常是同一批功能，
# 那一段就是**空的**，看起来像「这版什么都没改」（2026-11-18 的 v1.0.0 就是这样）。
#
# 口径（与 tools/ver_semver.sh 同一份实现，不许有两份）：
#   - semver：正式版 > 预发布；数字段按数值；数字段 < 非数字段
#   - GA 发版（VER 不带后缀）时**跳过预发布 tag** ⇒ 基准是上一个正式版
#   - 预发布发版（VER 带后缀）时基准是上一个已发布版本（含预发布）
#
# 用法：
#   prev=$(bash tools/changelog_prev.sh 1.1.0)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VER="${1:-}"

if [ -z "$VER" ]; then
  printf 'usage: changelog_prev.sh VER\n' >&2
  exit 2
fi

# shellcheck source=tools/ver_semver.sh
. "$ROOT/tools/ver_semver.sh"

best=""
for t in $(git tag -l 'v[0-9]*'); do
  tv=${t#v}
  [ "$tv" = "$VER" ] && continue
  # 严格大于当前版本的排除
  _ver_gt "$tv" "$VER" && continue
  # GA 发版时跳过预发布 tag（RC 与 GA 同批 ⇒ 拿 RC 当基准会得到空段）
  case "$VER" in
    *-*) ;;
    *) case "$tv" in *-*) continue ;; esac ;;
  esac
  # 剩下的是 <= VER，取其中最大的
  if [ -z "$best" ] || _ver_gt "$tv" "$best"; then
    best=$tv
  fi
done

if [ -n "$best" ]; then
  printf 'v%s' "$best"
fi
