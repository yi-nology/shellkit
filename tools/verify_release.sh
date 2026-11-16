#!/usr/bin/env bash
#
# 发布资产独立验签：把「发出去的那份」重新取回来，用固定公钥验一遍。
#
#   bash tools/verify_release.sh --dist DIR [--pub FILE]   # 验本地/已下载的资产
#   bash tools/verify_release.sh <tag> [--pub FILE]        # 从 GitHub Release 取回再验
#
# 为什么要有这一步（路线图 v0.27.0）：签名只有在「别人能独立验」时才算供应链保证。
# 发布流水线里的验签发生在**自己刚生成的 dist/ 上** —— 那证明不了「下载到的那份」
# 与签名对得上，也证明不了公钥没被换过。这里从 Release 重新取回资产再验，口径与
# 用户按 docs/TRUST.md 手动验签完全一致。
#
# 判据（全部满足才返回 0）：
#   1. 每个应签资产都有同名 .minisig（缺一份就是「可静默替换」的口子）
#   2. 每个 .minisig 用公钥验签通过
#   3. SHA256SUMS 里列出的每个文件的摘要与实物逐字节一致
#   4. 公钥与 docs/TRUST.md 钉的 base64 一致（交给 tools/check_trust_pin.sh）
#
# 退出码：0 全过 / 1 校验失败 / 2 用法错 / 3 缺工具、或资产取不回来
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dist=""
tag=""
pub=""

say() { printf '[verify] %s\n' "$*" >&2; }
die() {
  printf '[verify] FAIL: %s\n' "$1" >&2
  exit "${2:-1}"
}

while [ $# -gt 0 ]; do
  case $1 in
    --dist)
      shift
      [ $# -gt 0 ] || die "--dist needs a directory" 2
      dist=$1
      ;;
    --dist=*) dist=${1#*=} ;;
    --pub)
      shift
      [ $# -gt 0 ] || die "--pub needs a file" 2
      pub=$1
      ;;
    --pub=*) pub=${1#*=} ;;
    -h | --help)
      printf 'usage: %s --dist DIR [--pub FILE]\n       %s TAG [--pub FILE]\n' "${0##*/}" "${0##*/}"
      exit 0
      ;;
    -*) die "unknown option: $1" 2 ;;
    *)
      [ -z "$tag" ] || die "only one tag may be given" 2
      tag=$1
      ;;
  esac
  shift
done

command -v minisign >/dev/null 2>&1 || die "minisign is required to verify (apt-get install minisign / brew install minisign)" 3

tmp=""
cleanup() {
  [ -n "$tmp" ] && rm -rf "$tmp"
  return 0
}
trap cleanup EXIT INT TERM HUP

if [ -n "$tag" ]; then
  [ -n "$dist" ] && die "give either a tag or --dist, not both" 2
  command -v gh >/dev/null 2>&1 || die "gh is required to download the release assets" 3
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/shellkit-verify.XXXXXX") || die "cannot create a temp dir" 3
  dist="$tmp"
  say "downloading the published assets of $tag"
  gh release download "$tag" --dir "$dist" --clobber >/dev/null 2>&1 ||
    die "cannot download the assets of $tag" 3
fi

[ -n "$dist" ] || die "give a tag or --dist DIR" 2
[ -d "$dist" ] || die "not a directory: $dist" 2

# 公钥：优先 --pub，其次资产里的 shellkit.minisign.pub
if [ -z "$pub" ]; then
  pub="$dist/shellkit.minisign.pub"
fi
[ -s "$pub" ] || die "no public key at $pub (the release must publish shellkit.minisign.pub)" 1

# 公钥必须是「.pub 文件第 2 行」那种 base64；minisign -P 只吃这一段
pubkey=$(sed -n '2p' "$pub" | tr -d '[:space:]')
[ -n "$pubkey" ] || die "cannot read the base64 key from $pub" 1

# 4) 与 TRUST.md 钉的锚点一致 —— 漂移了，用户照文档验签必失败
# 只在「验已发布的那份」时强制：--dist 模式是本地自检（可能用一次性密钥做往返
# 验证），拿钉住的锚点去比必然失败，那不是这一步要判的东西。
if [ -n "$tag" ] && [ -f "$ROOT/tools/check_trust_pin.sh" ]; then
  bash "$ROOT/tools/check_trust_pin.sh" --pub "$pub" || die "the published public key does not match docs/TRUST.md" 1
fi

# 1) 每个应签资产都要有 .minisig
signed=0
for f in "$dist"/*.tar.gz "$dist"/install.sh "$dist"/SHA256SUMS; do
  [ -f "$f" ] || continue
  signed=$((signed + 1))
  [ -f "$f.minisig" ] || die "unsigned asset: $(basename "$f") (every published asset must be signed)"
done
[ "$signed" -gt 0 ] || die "no signable assets found in $dist" 1

# 2) 逐个验签
for f in "$dist"/*.minisig; do
  [ -f "$f" ] || continue
  target=${f%.minisig}
  [ -f "$target" ] || die "a signature without its file: $(basename "$f")" 1
  minisign -Vm "$target" -P "$pubkey" >/dev/null 2>&1 ||
    die "signature does not verify: $(basename "$target")"
  say "signature ok: $(basename "$target")"
done

# 3) SHA256SUMS 与实物一致
sums="$dist/SHA256SUMS"
if [ -f "$sums" ]; then
  while read -r want name; do
    [ -n "${want:-}" ] || continue
    [ -n "${name:-}" ] || continue
    [ -f "$dist/$name" ] || die "SHA256SUMS lists a missing file: $name"
    got=$(sha256sum "$dist/$name" 2>/dev/null | awk '{print $1}')
    [ -n "$got" ] || got=$(shasum -a 256 "$dist/$name" 2>/dev/null | awk '{print $1}')
    [ "$want" = "$got" ] || die "checksum mismatch for $name"
  done <"$sums"
  say "checksums ok"
fi

say "ok: every published asset is signed and verifiable"
exit 0
