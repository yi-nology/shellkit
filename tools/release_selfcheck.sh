#!/usr/bin/env bash
#
# 发布后自检：对着**已发布**的 Release 看资产清单，确认该有的都在。
#
#   bash tools/release_selfcheck.sh <tag> [--require-packages] [--no-require-signatures]
#
# 为什么要有这一步（v0.26.0 / v0.26.1 两版静默缺 deb/rpm）：旧 release.yml 把
# deb/rpm 放在**公开之后**的可选 job 里，那个 job 带 continue-on-error ——
# 它红了，整条 run 仍显示绿色，网页上只是「这一版没有系统包」。
# issue #127 起系统包已前移到公开之前并硬失败；这里仍从**已发布**的 Release
# 独立复核一遍资产清单（发布后可见面）——人的眼睛守不住每次发布，所以让脚本看。
#
# 判据（全部满足才返回 0）：
#   1. tag 与 VERSION 一致（防止查错版本）；
#   2. Release 不是 draft（对外可见的才值得验）；
#   3. 主资产齐全：tarball、skill 包、install.sh / repair.sh / demo.sh、SHA256SUMS；
#   4. 默认要求每个主资产都有 .minisig（正式发布必须签名，见 sign_release.sh --require）；
#   5. --require-packages 时还要求 .deb / .rpm 及其签名在案。
#
# 退出码：0 全过 / 1 校验失败 / 2 用法错 / 3 缺 gh、或取不回 Release
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG=""
REQUIRE_PACKAGES=0
REQUIRE_SIGNATURES=1

say() { printf '[selfcheck] %s\n' "$*" >&2; }
die() {
  printf '[selfcheck] FAIL: %s\n' "$1" >&2
  exit "${2:-1}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --require-packages) REQUIRE_PACKAGES=1 ;;
    --no-require-signatures) REQUIRE_SIGNATURES=0 ;;
    -h | --help)
      printf 'usage: %s <tag> [--require-packages] [--no-require-signatures]\n' "${0##*/}"
      exit 0
      ;;
    -*) die "unknown option: $1" 2 ;;
    *)
      [ -z "$TAG" ] || die "only one tag may be given" 2
      TAG=$1
      ;;
  esac
  shift
done

[ -n "$TAG" ] || die "a release tag is required" 2
command -v gh >/dev/null 2>&1 || die "gh is required to read the release assets" 3

ver=$(tr -d '[:space:]' <"$ROOT/VERSION" 2>/dev/null)
[ -n "$ver" ] || die "cannot read VERSION" 3
[ "$TAG" = "v$ver" ] || die "tag $TAG does not match VERSION v$ver (are you checking the release you just cut?)" 1

# isDraft 与资产名一次取回：gh 自带 jq，不额外依赖 jq。
if ! listing=$(gh release view "$TAG" --json isDraft,assets \
  --jq 'if .isDraft then "DRAFT" else "PUBLISHED" end, (.assets[].name)' 2>/dev/null); then
  die "cannot read the release $TAG (does it exist?)" 3
fi

draft=$(printf '%s\n' "$listing" | sed -n '1p')
names=$(printf '%s\n' "$listing" | sed -n '2,$p')
[ "$draft" = "PUBLISHED" ] || die "the release $TAG is still a draft (publish it before the self-check)" 1

_have() {
  local __nl=$'\n'
  case "$__nl$names$__nl" in
    *"$__nl$1$__nl"*) return 0 ;;
  esac
  return 1
}

missing=""
_probe() {
  if ! _have "$1"; then
    missing="$missing $1"
  fi
}

base_assets="shellkit-$ver.tar.gz shellkit-skill-$ver.tar.gz install.sh repair.sh demo.sh SHA256SUMS"
for a in $base_assets; do
  _probe "$a"
done

if [ "$REQUIRE_SIGNATURES" = "1" ]; then
  for a in $base_assets; do
    _probe "$a.minisig"
  done
fi

if [ "$REQUIRE_PACKAGES" = "1" ]; then
  for a in "shellkit-$ver.deb" "shellkit-$ver.rpm"; do
    _probe "$a"
  done
  if [ "$REQUIRE_SIGNATURES" = "1" ]; then
    for a in "shellkit-$ver.deb.minisig" "shellkit-$ver.rpm.minisig"; do
      _probe "$a"
    done
  fi
fi

if [ -n "$missing" ]; then
  say "the release $TAG is missing:$missing"
  say "  note: deb/rpm are built and signed before publish since #127; a missing package"
  say "        now means the release workflow regressed — this check makes it visible."
  exit 1
fi

say "ok: $TAG carries every expected asset"
printf '%s\n' "$names" >&2
exit 0
