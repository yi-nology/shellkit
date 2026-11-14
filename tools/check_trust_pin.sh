#!/usr/bin/env bash
#
# 门禁：TRUST.md 钉入的公钥必须与本次发布的公钥一致（路线图 v0.22.0 供应链可信发布）。
#
# 公钥有三个核对渠道（docs/TRUST.md「公钥从哪来」），其中「钉进 git 的这一份」是
# 跨渠道核对的锚点 —— 钉的值与实际签名用的公钥漂移，用户按文档验签必然失败。
# 正式启用（配置了 SHELLKIT_MINISIGN_KEY）之后，「钉入且一致」是发布的一部分。
#
# 用法：
#   bash tools/check_trust_pin.sh [--pub FILE] [--trust FILE]
#   --pub    本次发布的公钥文件（.pub 两行格式或单行 base64），默认 dist/shellkit.minisign.pub
#   --trust  含钉入值的文档，默认 docs/TRUST.md
#
# 退出码：0 一致 / 1 不一致 / 2 用法错 / 3 缺文件或文档里找不到钉入的公钥
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pub="$ROOT/dist/shellkit.minisign.pub"
trust="$ROOT/docs/TRUST.md"

usage() { printf 'usage: bash %s [--pub FILE] [--trust FILE]\n' "${0##*/}" >&2; }
die() {
  printf 'check_trust_pin: %s\n' "$1" >&2
  exit "${2:-1}"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --pub)
      shift
      [ "$#" -gt 0 ] || {
        usage
        exit 2
      }
      pub=$1
      ;;
    --trust)
      shift
      [ "$#" -gt 0 ] || {
        usage
        exit 2
      }
      trust=$1
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf 'check_trust_pin: unknown option: %s\n' "$1" >&2
      usage
      exit 2
      ;;
  esac
  shift
done

[ -f "$pub" ] || die "public key file not found: $pub" 3
[ -f "$trust" ] || die "trust document not found: $trust" 3

# 钉入值：「### 当前公钥」标题之后、下一个标题之前的第一个「像 base64 的长串」。
# 长度与字符集判据不依赖 awk 的区间表达式（BSD awk 老版本不支持 {n,m}）。
pin=$(awk '
  /^### 当前公钥/ { f = 1; next }
  f && /^#/ { exit }
  f && length($0) >= 40 && $0 ~ /^[A-Za-z0-9+\/=]+$/ { print; exit }
' "$trust")
[ -n "$pin" ] || die "no pinned public key under '### 当前公钥' in $trust" 3

# 发布件里的公钥：兼容「.pub 两行格式」与「单行 base64」两种形态，取最后一个非空行
cur=$(awk 'NF { last = $0 } END { print last }' "$pub")
[ -n "$cur" ] || die "cannot read a public key from $pub" 3

if [ "$pin" != "$cur" ]; then
  die "pinned key does not match the signing key — update the '### 当前公钥' section in $trust (pinned: ${pin:0:16}…, signing: ${cur:0:16}…)" 1
fi
printf 'check_trust_pin: ok\n'
exit 0
