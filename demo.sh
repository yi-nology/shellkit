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
# 未认证的 release API 配额是 60 次/小时**每个 IP** —— 共享出口（公司 NAT、云主机、
# CI runner）很容易把它用光 ⇒ 403 ⇒ **新用户连装都装不上**（实测 2026-11-21）。
# 这条是 /releases/latest 的重定向地址，**不吃 API 配额**，查不到时拿它兜底。
RELEASE_LATEST="${SHELLKIT_RELEASE_LATEST:-https://github.com/yi-nology/shellkit/releases/latest}"
RELEASE_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

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
# fetch_release_api URL DEST —— 取 release API 的 JSON；带了 token 就是认证请求
#
# 未认证的 API 配额是 60 次/小时每个 IP；认证请求是 5000 次/小时。
fetch_release_api() {
  local __url=$1 __dest=$2
  if [ -z "$RELEASE_TOKEN" ]; then
    fetch "$__url" "$__dest"
    return $?
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 15 --max-time 60 -H "Authorization: Bearer $RELEASE_TOKEN" \
      -o "$__dest" "$__url" || return 1
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 60 -t 2 --header="Authorization: Bearer $RELEASE_TOKEN" \
      -O "$__dest" "$__url" || return 1
  else
    die "curl or wget is required to download" "$SK_PRECOND"
  fi
  return 0
}

# latest_via_redirect —— 从 /releases/latest 的重定向里取版本号（不带 v）
#
# 为什么需要它：查「最新版本」这件事**根本不需要 API**。/releases/latest 会
# 302 到 .../releases/tag/vX.Y.Z ⇒ 从 Location 头里就能拿到版本号，
# 而这条路**不吃 API 配额**（实测 2026-11-21：配额用光时只有它还能走通）。
latest_via_redirect() {
  local __out="" __tag=""
  if command -v curl >/dev/null 2>&1; then
    __out=$(curl -sI --connect-timeout 15 --max-time 60 "$RELEASE_LATEST" 2>/dev/null || true)
  elif command -v wget >/dev/null 2>&1; then
    __out=$(wget -q -S --max-redirect=0 --timeout=60 -O /dev/null "$RELEASE_LATEST" 2>&1 || true)
  else
    return 1
  fi
  # 取第一行匹配，但不让 head 提前退出把 sed 打死（SIGPIPE → 141）
  __tag=$(printf '%s\n' "$__out" |
    sed -n 's/.*[Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn]:[[:space:]]*.*\/tag\/\([^/[:space:]]*\).*/\1/p' |
    sed -n '1p')
  [ -n "$__tag" ] || return 1
  printf '%s' "${__tag#v}"
  return 0
}

# latest_version DIR —— 最新版本号（不带 v），打印到 stdout
#
# 两道取法：① release API（带 token ⇒ 5000 次/小时）；② /releases/latest 的
# 重定向（不吃配额）。①失败或没取到 tag 时走 ②。
latest_version() {
  local __dir=${1:-} __tag=""
  if [ -n "$__dir" ] && fetch_release_api "$RELEASE_API" "$__dir/release.json"; then
    # 取第一行匹配，但不让 head 提前退出把 sed 打死（SIGPIPE → 141）
    __tag=$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$__dir/release.json")
    __tag=${__tag%%$'\n'*}
  fi
  if [ -n "$__tag" ]; then
    printf '%s' "${__tag#v}"
    return 0
  fi
  latest_via_redirect || return 1
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
  SHELLKIT_RELEASE_LATEST 查最新版本的备用端点（/releases/latest 重定向，不吃 API 配额）
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
  ver=$(latest_version "$tmp") ||
    die "cannot determine the latest version (API $RELEASE_API and redirect $RELEASE_LATEST both failed)" "$SK_VERIFY"
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
