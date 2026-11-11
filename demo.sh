#!/usr/bin/env bash
#
# shellkit 五分钟上手：一条命令跑一个真工程。
#
#   curl -fsSL https://github.com/yi-nology/shellkit/releases/latest/download/demo.sh | bash
#   ./demo.sh ./my-demo
#
# 这个脚本不往你的机器上装任何东西：它下载 release、校验 sha256、解包到临时目录，
# 用解包出来的 shellkit 生成一个工程、跑一遍工程自己的测试，然后把导览打出来。
# 临时目录随进程退出清掉，留下的只有那个演示工程。
#
# 退出码：0 成功 / 1 一般错误 / 2 用法 / 3 前置条件 / 4 网络 / 5 校验。
set -u

SK_OK=0
SK_ERR=1
SK_USAGE=2
SK_PRECOND=3
SK_NET=4
SK_VERIFY=5

PROG=demo.sh
RELEASE_API="${SHELLKIT_RELEASE_API:-https://api.github.com/repos/yi-nology/shellkit/releases/latest}"
RELEASE_BASE="${SHELLKIT_RELEASE_BASE:-https://github.com/yi-nology/shellkit/releases/download}"

say() { printf '%s\n' "$*" >&2; }
ok() { printf '[ OK ] %s\n' "$*" >&2; }
die() {
  printf '[FAIL] %s\n' "$1" >&2
  exit "${2:-$SK_ERR}"
}

need() {
  local __c
  for __c in "$@"; do
    if ! command -v "$__c" >/dev/null 2>&1; then
      die "missing required command: $__c" "$SK_PRECOND"
    fi
  done
}

# fetch URL DEST —— curl 优先，wget 兜底
fetch() {
  local __url=$1 __dest=$2
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 15 --max-time 900 -o "$__dest" "$__url" || return 1
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 60 -t 2 -O "$__dest" "$__url" || return 1
  else
    die "curl or wget is required to download" "$SK_PRECOND"
  fi
  return 0
}

# sha256 FILE —— 三种工具里挑一个能用的，输出纯十六进制串
sha256() {
  local __f=$1
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$__f" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$__f" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$__f" | awk '{print $NF}'
  else
    die "no sha256 tool found (sha256sum, shasum or openssl)" "$SK_PRECOND"
  fi
}

usage() {
  printf 'Usage: %s [DIR]\n' "$PROG" >&2
  cat >&2 <<'EOF'

  DIR             演示工程放在哪（默认：./shellkit-demo）

环境变量：
  VERSION                指定版本（默认取最新 release）
  SHELLKIT_RELEASE_API   取最新版本号的端点（默认 GitHub release API）
  SHELLKIT_RELEASE_BASE  release 资产前缀，走镜像时换这个
EOF
}

want_version="${VERSION:-}"
demo_dir=""

while [ "$#" -gt 0 ]; do
  case $1 in
    -h | --help)
      usage
      exit "$SK_OK"
      ;;
    -*)
      die "unknown option: $1 (try --help)" "$SK_USAGE"
      ;;
    *)
      if [ -n "$demo_dir" ]; then
        die "only one directory is allowed" "$SK_USAGE"
      fi
      demo_dir=$1
      ;;
  esac
  shift
done

need tar mktemp awk

tmp=$(mktemp -d "${TMPDIR:-/tmp}/shellkit-demo.XXXXXX") || die "cannot create a temporary directory" "$SK_ERR"
trap 'rm -rf "${tmp:?}"' EXIT INT TERM

ver=$want_version
if [ -z "$ver" ]; then
  fetch "$RELEASE_API" "$tmp/release.json" || die "cannot reach the release API: $RELEASE_API" "$SK_NET"
  # 取第一行匹配，但不让 head 提前退出把 sed 打死（SIGPIPE → 141）
  tag=$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$tmp/release.json")
  tag=${tag%%$'\n'*}
  ver=${tag#v}
  [ -n "$ver" ] || die "cannot read the version from $RELEASE_API" "$SK_VERIFY"
fi

base="${RELEASE_BASE%/}/v$ver"
say "downloading shellkit $ver"
fetch "$base/shellkit-$ver.tar.gz" "$tmp/pkg.tar.gz" || die "download failed: $base/shellkit-$ver.tar.gz" "$SK_NET"
fetch "$base/SHA256SUMS" "$tmp/SHA256SUMS" || die "download failed: $base/SHA256SUMS" "$SK_NET"
expect=$(awk -v n="shellkit-$ver.tar.gz" '$2==n{print $1}' "$tmp/SHA256SUMS")
[ -n "$expect" ] || die "no checksum for shellkit-$ver.tar.gz in SHA256SUMS" "$SK_VERIFY"
actual=$(sha256 "$tmp/pkg.tar.gz")
if [ "$actual" != "$expect" ]; then
  die "checksum mismatch for shellkit-$ver.tar.gz (expected $expect, got $actual)" "$SK_VERIFY"
fi
ok "checksum verified: $actual"

mkdir -p "$tmp/src"
tar -C "$tmp/src" -xzf "$tmp/pkg.tar.gz" || die "cannot extract shellkit-$ver.tar.gz" "$SK_VERIFY"
tree=""
for d in "$tmp/src"/*/; do
  if [ -f "${d}shellkit" ] && [ -d "${d}lib" ]; then
    tree=${d%/}
  fi
done
if [ -z "$tree" ] && [ -f "$tmp/src/shellkit" ] && [ -d "$tmp/src/lib" ]; then
  tree="$tmp/src"
fi
[ -n "$tree" ] || die "the archive does not look like a shellkit release" "$SK_VERIFY"

if [ -n "$demo_dir" ]; then
  bash "$tree/shellkit" demo "$demo_dir"
  rc=$?
else
  bash "$tree/shellkit" demo
  rc=$?
fi

exit "$rc"
