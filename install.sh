#!/usr/bin/env bash
#
# shellkit 一键安装脚本。
#
#   curl -fsSL https://raw.githubusercontent.com/yi-nology/shellkit/main/install.sh | bash
#   curl -fsSL .../install.sh | PREFIX="$HOME/.local" bash
#   ./install.sh --prefix /opt/shellkit --version 0.4.0
#   ./install.sh --uninstall
#
# 这个脚本自己不往 PREFIX 里放任何文件：它只负责取版本、下载、校验、解包，
# 然后把控制权交给包内自带的 `shellkit install-self`。安装逻辑只有一份。
#
# 可选验签（issue #66）：配了 minisign 公钥就验 tarball 与 SHA256SUMS 的签名，
# 不配公钥则完全跳过、行为与从前一致。本脚本不验它自己（curl | bash 形态
# 决定的），验什么 / 不验什么 / 离线怎么验，全在 docs/TRUST.md。
#
# 退出码：0 成功 / 1 一般错误 / 2 用法 / 3 前置条件 / 4 网络 / 5 校验。
#
# 在 git 检出版本里直接跑，装的是当前工作树（不联网）；curl | bash 走 release。
set -u

SK_OK=0
SK_ERR=1
SK_USAGE=2
SK_PRECOND=3
SK_NET=4
SK_VERIFY=5

PROG=install.sh
RELEASE_API="${SHELLKIT_RELEASE_API:-https://api.github.com/repos/yi-nology/shellkit/releases/latest}"
RELEASE_BASE="${SHELLKIT_RELEASE_BASE:-https://github.com/yi-nology/shellkit/releases/download}"
# 未认证的 release API 配额是 60 次/小时**每个 IP** —— 共享出口（公司 NAT、云主机、
# CI runner）很容易把它用光 ⇒ 403 ⇒ **新用户连装都装不上**（实测 2026-11-21）。
# 这条是 /releases/latest 的重定向地址，**不吃 API 配额**，查不到时拿它兜底。
RELEASE_LATEST="${SHELLKIT_RELEASE_LATEST:-https://github.com/yi-nology/shellkit/releases/latest}"
RELEASE_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

say() { printf '%s\n' "$*" >&2; }
ok() { printf '[ OK ] %s\n' "$*" >&2; }
warn() { printf '[WARN] %s\n' "$*" >&2; }

die() {
  local __msg=$1 __code=${2:-$SK_ERR}
  printf '[FAIL] %s\n' "$__msg" >&2
  exit "$__code"
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
# 超时**不复用 fetch 的 900 秒**：那是给下载 tarball 定的，而这一问只是「查个
# 版本号」—— 主路径卡 900 秒才轮到 /releases/latest 兜底，等于把兜底路径废掉
# （网络挂起时要白等 15 分钟）。一律 60 秒，与重定向那一问同口径。
fetch_release_api() {
  local __url=$1 __dest=$2
  if command -v curl >/dev/null 2>&1; then
    if [ -n "$RELEASE_TOKEN" ]; then
      curl -fsSL --connect-timeout 15 --max-time 60 -H "Authorization: Bearer $RELEASE_TOKEN" \
        -o "$__dest" "$__url" || return 1
    else
      curl -fsSL --connect-timeout 15 --max-time 60 -o "$__dest" "$__url" || return 1
    fi
  elif command -v wget >/dev/null 2>&1; then
    if [ -n "$RELEASE_TOKEN" ]; then
      wget -q -T 60 -t 2 --header="Authorization: Bearer $RELEASE_TOKEN" \
        -O "$__dest" "$__url" || return 1
    else
      wget -q -T 60 -t 2 -O "$__dest" "$__url" || return 1
    fi
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
#
# 退出码（**两类失败不许抹平成一个**）：
#   0 取到了版本号；
#   4 网络/接口层失败 —— 两条路都**没拿到东西**（连不上、超时、403/404）；
#   5 服务器答了但没给版本号（落地页 HTML、被限流的 JSON、字段改了名）。
# ★ 为什么 4 与 5 要分开：仓库的退出码约定是「4 = 网络失败，重试可能有用；
#   5 = 校验失败，重试同一个地址永远不会成功」（docs/API-FREEZE.md）。
#   加了兜底路径之后若一律报 5，「断网」就被说成「这个版本号不可信」——
#   调用方的重试与告警都跟着走错。这是「加一条兜底」时最容易顺手弄丢的东西。
latest_version() {
  local __dir=${1:-} __tag=""
  local __api_failed=0
  if [ -n "$__dir" ] && fetch_release_api "$RELEASE_API" "$__dir/release.json"; then
    # 取第一行匹配，但不让 head 提前退出把 sed 打死（SIGPIPE → 141）
    __tag=$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$__dir/release.json")
    __tag=${__tag%%$'\n'*}
  else
    # 这一问**没拿到东西**：可能是连不上（网络），也可能是 403/404（服务器答了，
    # 只是没给版本）。先记下来 —— 两条路都没结果时，用它决定退 4 还是退 5。
    __api_failed=1
  fi
  if [ -n "$__tag" ]; then
    printf '%s' "${__tag#v}"
    return 0
  fi
  latest_via_redirect && return 0
  if [ "$__api_failed" = "1" ]; then
    return "$SK_NET"
  fi
  return "$SK_VERIFY"
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
# sig_pub_configured —— 是否配了验签公钥（两个环境变量任一即可）
sig_pub_configured() {
  [ -n "${SHELLKIT_MINISIGN_PUBKEY:-}" ] || [ -n "${SHELLKIT_MINISIGN_PUBKEY_FILE:-}" ]
}

# sig_verify FILE —— 验 FILE 同目录 <FILE>.minisig 的 minisign 签名。
# 前置（minisign 存在、公钥文件可读）由调用方先挡；-q 只留退出码，提示自己打。
# 返回码：0 通过 / 1 不通过
sig_verify() {
  local __file=$1
  if [ -n "${SHELLKIT_MINISIGN_PUBKEY:-}" ]; then
    minisign -Vm "$__file" -P "$SHELLKIT_MINISIGN_PUBKEY" -q >/dev/null 2>&1
  else
    minisign -Vm "$__file" -p "$SHELLKIT_MINISIGN_PUBKEY_FILE" -q >/dev/null 2>&1
  fi
}

usage() {
  printf 'Usage: %s [options]\n' "$PROG" >&2
  cat >&2 <<'EOF'

  --prefix DIR     装到 DIR（默认：能写 /usr/local 就用它，否则用 ~/.local）
  --version VER    装指定版本（默认取最新 release）
  --remote         即使当前目录是 git 检出，也从 release 下载（默认装本地树）
  --check          只报告最新版本，不改动任何文件
  --uninstall      卸载 --prefix 下的 shellkit
  -h, --help       显示本帮助

环境变量（优先级低于同名参数）：
  PREFIX                 同 --prefix
  VERSION                同 --version
  SHELLKIT_RELEASE_API   取最新版本号的端点（默认 GitHub release API）
  SHELLKIT_RELEASE_BASE  release 资产前缀，走镜像时换这个
  SHELLKIT_RELEASE_LATEST 查最新版本的备用端点（/releases/latest 重定向，不吃 API 配额）
  SHELLKIT_MINISIGN_PUBKEY      配了就验 minisign 签名（公钥 base64 串）
  SHELLKIT_MINISIGN_PUBKEY_FILE 同上，用 .pub 文件路径（两者都给时优先前者）

装完把 PREFIX/bin 加进 PATH 即可。本脚本不覆盖 PREFIX 下的无关文件：
它只在 PREFIX/share/shellkit 放一份完整子树，并写 MANIFEST 供 --uninstall 用。
EOF
}

# _default_prefix —— 未显式给 PREFIX 时的安装位置
_default_prefix() {
  if [ -n "${PREFIX:-}" ]; then
    printf '%s' "${PREFIX%/}"
  elif [ -w /usr/local/bin ] || [ "$(id -u)" = "0" ]; then
    printf '/usr/local'
  else
    printf '%s/.local' "${HOME:-/tmp}"
  fi
}

# _self_tree —— 本脚本旁边的 shellkit 源码树；管道执行时为空
_self_tree() {
  local __src=${BASH_SOURCE[0]:-} __dir
  if [ -z "$__src" ] || [ ! -f "$__src" ]; then
    return 1
  fi
  __dir=$(cd -P "$(dirname "$__src")" 2>/dev/null && pwd) || return 1
  if [ -f "$__dir/shellkit" ] && [ -d "$__dir/lib" ]; then
    printf '%s' "$__dir"
    return 0
  fi
  return 1
}

prefix=$(_default_prefix)
want_version=${VERSION:-}
mode=install
force_remote=0

while [ "$#" -gt 0 ]; do
  case $1 in
    --prefix)
      [ "$#" -ge 2 ] || die "--prefix requires a value" "$SK_USAGE"
      prefix=${2%/}
      shift
      ;;
    --prefix=*)
      prefix=${1#*=}
      prefix=${prefix%/}
      ;;
    --version)
      [ "$#" -ge 2 ] || die "--version requires a value" "$SK_USAGE"
      want_version=${2#v}
      shift
      ;;
    --version=*)
      want_version=${1#*=}
      want_version=${want_version#v}
      ;;
    --remote) force_remote=1 ;;
    --check) mode=check ;;
    --uninstall) mode=uninstall ;;
    -h | --help)
      usage
      exit "$SK_OK"
      ;;
    *)
      die "unknown option: $1 (try --help)" "$SK_USAGE"
      ;;
  esac
  shift
done

[ -n "$prefix" ] || die "the install prefix is empty" "$SK_USAGE"

# ---------- 卸载 / 查版本 ----------

if [ "$mode" = uninstall ]; then
  for cand in "$prefix/bin/shellkit" "$prefix/share/shellkit/shellkit"; do
    if [ -x "$cand" ]; then
      # 删除谁最清楚？装在里面的那份自己最清楚（它读 MANIFEST）
      "$cand" uninstall-self --prefix "$prefix"
      exit $?
    fi
  done
  die "shellkit does not look installed under $prefix" "$SK_PRECOND"
fi

if [ "$mode" = check ]; then
  cur=""
  if [ -f "$prefix/share/shellkit/VERSION" ]; then
    cur=$(tr -d '[:space:]' <"$prefix/share/shellkit/VERSION")
  fi
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/shellkit-check.XXXXXX") || die "cannot create a temporary directory" "$SK_ERR"
  trap 'rm -rf "${tmp:?}"' EXIT INT TERM
  # "$?" 就是 latest_version 的退出码：网络/接口层失败是 4，服务器答了但没给
  # 版本号是 5 —— 两类要分开（docs/API-FREEZE.md 的退出码约定），不能一律报 5。
  latest=$(latest_version "$tmp") ||
    die "cannot determine the latest version (API $RELEASE_API and redirect $RELEASE_LATEST both failed)" "$?"
  # stdout 只给数据：这一行就是脚本能拿去做判断的东西
  printf '%s\n' "$latest"
  if [ -z "$cur" ]; then
    say "shellkit is not installed under $prefix; latest is $latest"
  elif [ "$cur" = "$latest" ]; then
    ok "already up to date: $cur"
  else
    say "installed $cur, latest $latest; run this script again to update"
  fi
  exit "$SK_OK"
fi

# ---------- 安装 ----------

tree=""
ver=$want_version
tmp=""

if [ "$force_remote" != "1" ] && [ -z "$want_version" ] && tree=$(_self_tree); then
  say "installing from the working tree: $tree"
else
  tree=""
  need tar mktemp
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/shellkit-install.XXXXXX") || die "cannot create a temporary directory" "$SK_ERR"
  trap 'rm -rf "${tmp:?}"' EXIT INT TERM
  if [ -z "$ver" ]; then
    ver=$(latest_version "$tmp") ||
      die "cannot determine the latest version (API $RELEASE_API and redirect $RELEASE_LATEST both failed)" "$?"
  fi
  base="${RELEASE_BASE%/}/v$ver"
  say "downloading shellkit $ver"
  fetch "$base/shellkit-$ver.tar.gz" "$tmp/pkg.tar.gz" || die "download failed: $base/shellkit-$ver.tar.gz" "$SK_NET"
  fetch "$base/SHA256SUMS" "$tmp/SHA256SUMS" || die "download failed: $base/SHA256SUMS" "$SK_NET"
  # 可选验签：先锚「清单与包是不是我们发的」，再信 sha256 ——
  # sha256 只能防「下载没被改」，防不住清单和包被一起换掉（issue #66）。
  # 没配公钥就整段跳过：现有用户的默认行为一个字节都不变。
  if sig_pub_configured; then
    need minisign
    if [ -n "${SHELLKIT_MINISIGN_PUBKEY_FILE:-}" ] && [ ! -f "$SHELLKIT_MINISIGN_PUBKEY_FILE" ]; then
      die "public key file not found: $SHELLKIT_MINISIGN_PUBKEY_FILE" "$SK_PRECOND"
    fi
    # 缺签名资产算校验失败（5），与「SHA256SUMS 里没有校验和」同一口径
    fetch "$base/SHA256SUMS.minisig" "$tmp/SHA256SUMS.minisig" ||
      die "missing or unreachable signature: $base/SHA256SUMS.minisig" "$SK_VERIFY"
    sig_verify "$tmp/SHA256SUMS" ||
      die "signature verification failed for SHA256SUMS (minisign)" "$SK_VERIFY"
    fetch "$base/shellkit-$ver.tar.gz.minisig" "$tmp/pkg.tar.gz.minisig" ||
      die "missing or unreachable signature: $base/shellkit-$ver.tar.gz.minisig" "$SK_VERIFY"
    sig_verify "$tmp/pkg.tar.gz" ||
      die "signature verification failed for shellkit-$ver.tar.gz (minisign)" "$SK_VERIFY"
    ok "signature verified: SHA256SUMS, shellkit-$ver.tar.gz"
  else
    say "signature verification skipped (no public key configured); docs/TRUST.md explains how to enable it"
  fi
  expect=$(awk -v n="shellkit-$ver.tar.gz" '$2==n{print $1}' "$tmp/SHA256SUMS")
  [ -n "$expect" ] || die "no checksum for shellkit-$ver.tar.gz in SHA256SUMS" "$SK_VERIFY"
  actual=$(sha256 "$tmp/pkg.tar.gz")
  if [ "$actual" != "$expect" ]; then
    die "checksum mismatch for shellkit-$ver.tar.gz (expected $expect, got $actual)" "$SK_VERIFY"
  fi
  ok "checksum verified: $actual"
  mkdir -p "$tmp/src"
  tar -C "$tmp/src" -xzf "$tmp/pkg.tar.gz" || die "cannot extract shellkit-$ver.tar.gz" "$SK_VERIFY"
  for d in "$tmp/src"/*/; do
    if [ -f "${d}shellkit" ] && [ -d "${d}lib" ]; then
      tree=${d%/}
    fi
  done
  if [ -z "$tree" ] && [ -f "$tmp/src/shellkit" ] && [ -d "$tmp/src/lib" ]; then
    tree=$tmp/src
  fi
  [ -n "$tree" ] || die "the archive does not look like a shellkit release" "$SK_VERIFY"
fi

bash "$tree/shellkit" install-self --prefix "$prefix" || die "install-self failed under $prefix" "$SK_ERR"

got=$("$prefix/bin/shellkit" --version 2>/dev/null) || got=""
[ -n "$got" ] || die "installed, but $prefix/bin/shellkit does not run" "$SK_ERR"
ok "shellkit $got is at $prefix/bin/shellkit"

case ":${PATH:-}:" in
  *":$prefix/bin:"*) ;;
  *) warn "add it to PATH: export PATH=\"$prefix/bin:\$PATH\"" ;;
esac

exit "$SK_OK"
