#!/usr/bin/env bash
#
# 发布资产上传（不可变，issue #87）。
#
# gh release upload --clobber 会静默覆盖同 tag 已发布的资产 —— 同一版本的
# 下载内容可被替换。sha256 与 minisign 防的是下载链路，防不了发布账号被
# 攻破后的整体替换；资产不可变是把「替换」变成显式人工动作的最后防线。
# 这里的纪律：
#   - 资产不存在 ⇒ 上传（不传 --clobber：存在即拒绝，不存在才写）；
#   - 资产已存在且摘要一致 ⇒ 跳过上传（发布流水线重跑幂等，不产生写入）；
#   - 资产已存在但摘要不同 ⇒ 拒绝覆盖并退出 1，指路人工处理 —— 真要重发
#     同一版本，先手工删掉旧资产（或整个 release）再跑。
#
#   bash tools/release_assets.sh <tag> <asset> [<asset>...]
#
# minisign 签名产物（.minisig / .minisign.pub）与普通资产走同一套判据。
# 退出码：0 上传/跳过完成 / 1 有资产摘要不一致（拒绝覆盖）/
#         2 用法错 / 3 前置条件不满足（release 不存在、gh 不可用）
set -u

PROG=release_assets.sh
say() { printf '[assets] %s\n' "$*" >&2; }
ok() { printf '[ OK ] %s\n' "$*" >&2; }
die() {
  printf '[FAIL] %s\n' "$1" >&2
  exit "${2:-1}"
}

usage() {
  printf 'Usage: bash %s <tag> <asset> [<asset>...]\n' "$PROG" >&2
}

[ "$#" -ge 2 ] || {
  usage
  exit 2
}
tag=$1
shift

if ! command -v gh >/dev/null 2>&1; then
  die "gh is required to upload release assets" 3
fi

# _sha FILE —— 文件的 sha256；macOS 没有 sha256sum，用 shasum 兜底
_sha() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    die "neither sha256sum nor shasum is available to compare asset digests" 3
  fi
}

# release 必须已存在：创建带标题与 generate-notes，是 release.yml 的活，
# 这里只管「往已存在的 release 上放资产」这一件事。
gh release view "$tag" >/dev/null 2>&1 ||
  die "release $tag does not exist yet — create it first (gh release create)" 3

# 已发布资产的名字清单（逐行精确匹配，不做 glob）。
# 查不到清单按「没有已发布资产」处理：上传照常走，重名交给 gh 自己拒绝。
__names=$(gh release view "$tag" --json assets --jq '.assets[].name' 2>/dev/null) || __names=""

for __f in "$@"; do
  [ -f "$__f" ] || die "asset does not exist: $__f" 2
  __name=${__f##*/}
  __local=$(_sha "$__f")
  __have=0
  if [ -n "$__names" ]; then
    while IFS= read -r __n; do
      if [ "$__n" = "$__name" ]; then
        __have=1
        break
      fi
    done <<EOF
$__names
EOF
  fi
  if [ "$__have" -eq 0 ]; then
    if ! gh release upload "$tag" "$__f" >&2; then
      say "upload failed: $__name"
      exit 1
    fi
    ok "uploaded: $__name"
    continue
  fi
  # 资产已在：下载回来对摘要 —— 同则跳过，异则拒绝（不可变纪律）。
  # 每个资产一个全新的临时目录，不用 --clobber 也绝不覆盖本地任何东西。
  __tmp=$(mktemp -d "${TMPDIR:-/tmp}/shellkit-assets.XXXXXX") ||
    die "cannot create a temporary directory" 1
  if gh release download "$tag" --dir "$__tmp" --pattern "$__name" >/dev/null 2>&1 &&
    [ -f "$__tmp/$__name" ]; then
    __remote=$(_sha "$__tmp/$__name")
    if [ "$__remote" = "$__local" ]; then
      ok "skip (same digest already published): $__name"
    else
      say "refusing to overwrite: $__name on $tag has a different digest"
      say "  local  sha256: $__local"
      say "  remote sha256: $__remote"
      say "  published assets are immutable; delete the asset (or the whole release) by hand first"
      rm -rf "$__tmp" 2>/dev/null || true
      exit 1
    fi
  else
    # 名字在资产列表里却下载不回来：对不了摘要 = 当作不一致（fail-closed）
    say "refusing to overwrite: $__name is listed on $tag but could not be downloaded for comparison"
    rm -rf "$__tmp" 2>/dev/null || true
    exit 1
  fi
  rm -rf "$__tmp" 2>/dev/null || true
done
exit 0
