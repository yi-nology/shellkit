#!/usr/bin/env bash
#
# 发布签名（minisign，可选）—— issue #66。
#
# sha256 只证明「下载没被改」，不证明「这个包是我们发的」：SHA256SUMS 和 tarball
# 走同一个下载通道，中间人可以一起换掉。签名把信任锚到一把公钥上。
#
#   bash tools/sign_release.sh [--dist DIR]
#
# 有私钥就签，没私钥就跳过并明确提示；绝不伪造签名产物、绝不在仓库里放密钥。
# 签名对象：SHA256SUMS 里列出的每个文件 + SHA256SUMS 自身 + install.sh
#   （install.sh 是 curl | bash 的入口，签了它，离线路径才能先验它再执行）。
# 产出：每个被签文件旁的 <file>.minisig，以及 $dist/shellkit.minisign.pub（公钥）。
#
# 环境变量：
#   SHELLKIT_MINISIGN_KEY       私钥文件路径，或私钥文件的完整内容
#                               （CI secret 用「内容」形态；本地用路径形态）
#   SHELLKIT_MINISIGN_PUBKEY    公钥（.pub 文件路径或 base64 内容，可选；
#                               不给则用 minisign -R 从私钥重建一份发布）
#
# 退出码：0 成功（或按策略跳过）/ 1 一般错误 / 2 用法错 /
#         3 配了私钥却缺 minisign / 私钥不可读（前置条件不满足）
set -u

PROG=sign_release.sh
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dist=dist
tmp=""

say() { printf '[sign] %s\n' "$*" >&2; }
ok() { printf '[ OK ] %s\n' "$*" >&2; }
die() {
  printf '[FAIL] %s\n' "$1" >&2
  exit "${2:-1}"
}

usage() {
  printf 'Usage: bash %s [--dist DIR]\n' "$PROG" >&2
}

while [ "$#" -gt 0 ]; do
  case $1 in
    --dist)
      [ "$#" -ge 2 ] || {
        usage
        exit 2
      }
      dist=$2
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf '%s: unknown option: %s\n' "$PROG" "$1" >&2
      usage
      exit 2
      ;;
  esac
  shift
done

cd "$ROOT" || die "cannot cd into $ROOT" 1
[ -d "$dist" ] || die "dist directory not found: $dist (run tools/package_tarball.sh first)" 3

# ---------------------------------------------------------------- 私钥解析
key_value=${SHELLKIT_MINISIGN_KEY:-}
if [ -z "$key_value" ]; then
  say "skipped: SHELLKIT_MINISIGN_KEY is not set — this release will ship unsigned."
  say "         (generate a key pair and configure the secret; see docs/TRUST.md)"
  exit 0
fi

keyfile=""
if [ -f "$key_value" ]; then
  keyfile=$key_value
else
  # CI secret 里放的是私钥文件的内容（路径在 runner 上不存在）
  case $key_value in
    untrusted\ comment:*)
      tmp=$(mktemp -d "${TMPDIR:-/tmp}/shellkit-sign.XXXXXX") || die "cannot create a temporary directory" 1
      trap 'rm -rf "${tmp:?}"' EXIT INT TERM
      keyfile="$tmp/shellkit.key"
      printf '%s\n' "$key_value" >"$keyfile" || die "cannot write the key material to a temp file" 1
      chmod 600 "$keyfile" || die "cannot chmod the key file" 1
      ;;
    *)
      die "SHELLKIT_MINISIGN_KEY is neither a readable file nor minisign secret key content" 3
      ;;
  esac
fi

command -v minisign >/dev/null 2>&1 ||
  die "minisign is required to sign, but SHELLKIT_MINISIGN_KEY is configured (apt-get install minisign / brew install minisign)" 3

# ---------------------------------------------------------------- 收集签名对象
# SHA256SUMS 每行「哈希  文件名」：里面列出的每个文件都要有签名，
# 否则「清单有、签名无」会变成验签时的死角。
files=()
if [ -f "$dist/SHA256SUMS" ]; then
  while read -r __hash __name; do
    [ -n "$__name" ] || continue
    __name=${__name#\*}
    [ -n "$__name" ] || continue
    files[${#files[@]}]="$dist/$__name"
  done <"$dist/SHA256SUMS"
else
  say "warning: $dist/SHA256SUMS not found — only SHA256SUMS itself and install.sh will be signed"
fi
files[${#files[@]}]="$dist/SHA256SUMS"
if [ -f install.sh ]; then
  files[${#files[@]}]="install.sh"
fi

# ---------------------------------------------------------------- 签
signed=()
for __f in ${files[@]+"${files[@]}"}; do
  [ -f "$__f" ] || die "file listed for signing does not exist: $__f" 1
  minisign -S -s "$keyfile" -m "$__f" >&2 || die "minisign failed to sign $__f" 1
  [ -f "$__f.minisig" ] || die "minisign reported success but $__f.minisig is missing" 1
  signed[${#signed[@]}]="$__f.minisig"
done

# ---------------------------------------------------------------- 公钥发布件
pub_out="$dist/shellkit.minisign.pub"
pub_src=${SHELLKIT_MINISIGN_PUBKEY:-}
if [ -n "$pub_src" ]; then
  if [ -f "$pub_src" ]; then
    cp -p "$pub_src" "$pub_out" || die "cannot copy the public key to $pub_out" 1
  else
    printf '%s\n' "$pub_src" >"$pub_out" || die "cannot write the public key to $pub_out" 1
  fi
  chmod 644 "$pub_out" || die "cannot chmod $pub_out" 1
  ok "public key published at $pub_out (from SHELLKIT_MINISIGN_PUBKEY)"
elif minisign -R -f -s "$keyfile" -p "$pub_out" >&2; then
  chmod 644 "$pub_out" || die "cannot chmod $pub_out" 1
  ok "public key recreated from the secret key at $pub_out (minisign -R)"
else
  say "warning: could not derive the public key — publish it manually in docs/TRUST.md"
fi

ok "signed ${#signed[@]} file(s)"
# stdout 只给数据：新产出的签名文件路径，一行一个
for __s in ${signed[@]+"${signed[@]}"}; do
  printf '%s\n' "$__s"
done
exit 0
