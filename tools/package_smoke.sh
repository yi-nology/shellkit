#!/usr/bin/env bash
#
# 系统包冒烟：装上 → 逐项点名自检（含真跑 shellkit --version）→ 卸掉 →
# 断言装过的东西一个不剩（issue #65 验收：「装上、跑通、卸掉」）。
#
#   bash tools/package_smoke.sh [--tarball FILE] dist/shellkit-1.2.3.deb
#   bash tools/package_smoke.sh [--tarball FILE] dist/shellkit-1.2.3.rpm
#
# --tarball 给了就在装后做「与 tarball 逐字节一致」比对（同一真相源的终验）。
# 需要 root：本来就是 root 就直接跑，否则用 sudo（CI 里是免密 sudo）。
#
# 退出码：0 全过 / 1 一般错误 / 2 用法错 / 3 缺工具或没有提权手段 /
#         5 装后自检不过、或卸载后有残留
set -u

PROG=package_smoke.sh
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tarball=""
pkg=""
rc=0

say() { printf '[smoke] %s\n' "$*" >&2; }
die() {
  printf '[FAIL] %s\n' "$1" >&2
  exit "${2:-1}"
}

usage() {
  printf 'Usage: bash %s [--tarball FILE] <pkg.deb|pkg.rpm>\n' "$PROG" >&2
}

while [ "$#" -gt 0 ]; do
  case $1 in
    --tarball)
      [ "$#" -ge 2 ] || {
        usage
        exit 2
      }
      tarball=$2
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      printf '%s: unknown option: %s\n' "$PROG" "$1" >&2
      usage
      exit 2
      ;;
    *)
      [ -z "$pkg" ] || {
        printf '%s: unexpected argument: %s\n' "$PROG" "$1" >&2
        usage
        exit 2
      }
      pkg=$1
      ;;
  esac
  shift
done

[ -n "$pkg" ] || {
  usage
  exit 2
}
[ -f "$pkg" ] || die "package not found: $pkg" 3
[ -z "$tarball" ] || [ -f "$tarball" ] || die "tarball not found: $tarball" 3

# _sudo CMD... —— root 直跑，非 root 走 sudo，两者都没有就明说缺前置
_sudo() {
  if [ "$(id -u)" = "0" ]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    die "need root to install/remove the package (neither root nor sudo)" 3
  fi
}

# _post_checks —— 装后逐项点名自检（含与 tarball 的一致性、真跑 --version）
_post_checks() {
  local -a __args
  __args=(--verify-prefix /usr)
  if [ -n "$tarball" ]; then
    __args[${#__args[@]}]="--tarball"
    __args[${#__args[@]}]="$tarball"
  fi
  bash "$ROOT/tools/package_syspkg.sh" ${__args[@]+"${__args[@]}"}
}

case $pkg in
  *.deb)
    command -v dpkg >/dev/null 2>&1 || die "dpkg not found (this is a .deb)" 3
    command -v dpkg-deb >/dev/null 2>&1 || die "dpkg-deb not found" 3
    say "installing $pkg (dpkg -i)"
    _sudo dpkg -i "$pkg" >&2 || die "dpkg -i failed" 1

    _post_checks || rc=$?

    say "removing the package (dpkg -r shellkit)"
    if ! _sudo dpkg -r shellkit >&2; then
      [ "$rc" -ne 0 ] || rc=1
    fi
    ;;
  *.rpm)
    command -v rpm >/dev/null 2>&1 || die "rpm not found (this is a .rpm; apt-get install rpm)" 3
    # --nodeps：deb 系发行版的 rpm 数据库是空的，文件级依赖（bash、/usr/bin/env）
    # 永远解析不出来 —— 它们由后面「真跑 shellkit --version」的判据兜底：缺了当场红。
    # 在真 rpm 系（Fedora/Rocky）上依赖本来就可解析，跳过它不改变「装上跑通」的判据。
    say "installing $pkg (rpm -i --nodeps)"
    _sudo rpm -i --nodeps "$pkg" >&2 || die "rpm -i failed" 1

    _post_checks || rc=$?

    say "removing the package (rpm -e shellkit)"
    if ! _sudo rpm -e shellkit >&2; then
      [ "$rc" -ne 0 ] || rc=1
    fi
    ;;
  *)
    die "unknown package type: $pkg (want *.deb or *.rpm)" 2
    ;;
esac

# ---------------------------------------------------------------- 卸干净了吗
# 两类残留都要点名：文件残留（删了包但文件还在）与登记残留（dpkg/rpm 还认它）。
_leftover=0
if [ -e /usr/lib/shellkit ]; then
  printf 'smoke: leftover after removal: /usr/lib/shellkit\n' >&2
  _leftover=1
fi
if [ -e /usr/bin/shellkit ]; then
  printf 'smoke: leftover after removal: /usr/bin/shellkit\n' >&2
  _leftover=1
fi
case $pkg in
  *.deb)
    __st=$(dpkg-query -f '${Status}' -W shellkit 2>/dev/null || true)
    case $__st in
      *'install ok installed'*)
        printf 'smoke: still registered in dpkg after removal (status: %s)\n' "$__st" >&2
        _leftover=1
        ;;
    esac
    ;;
  *.rpm)
    __st=$(rpm -q shellkit 2>/dev/null || true)
    case $__st in
      shellkit-*)
        printf 'smoke: still registered in rpm after removal (query: %s)\n' "$__st" >&2
        _leftover=1
        ;;
    esac
    ;;
esac

if [ "$_leftover" -ne 0 ]; then
  [ "$rc" -ne 0 ] || rc=5
  die "the uninstall is not clean ($_leftover leftover(s); first failure code: $rc)" 5
fi

[ "$rc" -eq 0 ] || exit "$rc"
say "passed: install -> named checks (tarball consistency + shellkit --version) -> remove -> clean"
exit 0
