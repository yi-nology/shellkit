#!/usr/bin/env bash
#
# 跨版本升级矩阵：用**已发布的旧版本**建工程，再用当前 CLI 升级它。
#
#   bash tools/upgrade_matrix.sh [--versions "0.20.0 0.23.0 0.24.1"] [--repo OWNER/NAME]
#
# 为什么（路线图 v0.25.0）：本仓库的升级用例都是「当前版本 → 当前版本」——
# 它们证明不了老工程能不能被新版本接住。真实世界里用户手上是 0.17/0.20/0.23
# 那种工程，清单 schema、模板、去掉的文件都可能不一样。这一组用例就是拿真发行包
# 造出那种现场。
#
# 判据（每个版本都要满足）：
#   1. 老版本 CLI 能建出工程（建不出来就是版本太老、跳过而不是判过）
#   2. 当前 CLI 升级后退出码 0
#   3. VERSION 变成当前版本
#   4. 用户自己写的文件字节不变
#   5. 没有 .shellkit-new / .shellkit-old 残骸，清单完整（无 .tmp 残骸）
#   6. 升级后再跑一次是「已经最新」（幂等）
#   7. 生命周期一圈（v0.27.0）：install-self → uninstall-self → 重装 → 用装出来的
#      CLI 再升一次 —— 卸载必须删掉 CLI 与安装清单，重装必须能立刻接着用。
#      这条守的是「升级链的另一头」：只验 upgrade 不验 install/uninstall，
#      等于假定用户永远不卸载重装。
#
# 离网时显式 SKIP 并返回 0 —— 绝不因为「下不到」而假绿。
#
# 退出码：0 全过（或全部跳过）/ 1 有用例失败 / 2 用法错 / 3 缺前置条件
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 0.26.2 是第一个「系统包与签名都齐全」的版本，也是 1.0 前最近的完整发行版。
versions="0.20.0 0.23.0 0.24.1 0.26.2"
strict=0
repo="yi-nology/shellkit"
SK="$ROOT/shellkit"

say() { printf '[matrix] %s\n' "$*" >&2; }
die() {
  printf '[matrix] FAIL: %s\n' "$1" >&2
  exit "${2:-1}"
}

while [ $# -gt 0 ]; do
  case $1 in
    --versions)
      shift
      [ $# -gt 0 ] || die "--versions needs a list" 2
      versions=$1
      ;;
    --versions=*) versions=${1#*=} ;;
    --repo)
      shift
      [ $# -gt 0 ] || die "--repo needs OWNER/NAME" 2
      repo=$1
      ;;
    --repo=*) repo=${1#*=} ;;
    # CI / 正式发布用：**全部跳过也算失败**。离网时本地跑允许 skip（那是开发体验），
    # 但「所有声明的源版本一个都没验成」不能当成通过 —— 否则这一项等于没做。
    --strict) strict=1 ;;
    -h | --help)
      printf 'usage: %s [--versions "A B C"] [--repo OWNER/NAME] [--strict]\n' "${0##*/}"
      exit 0
      ;;
    *) die "unknown option: $1" 2 ;;
  esac
  shift
done

command -v gh >/dev/null 2>&1 || die "gh is required to download the old releases" 3
[ -x "$SK" ] || die "the current CLI is missing: $SK" 3

current=$(tr -d '[:space:]' <"$ROOT/VERSION")
work=$(mktemp -d "${TMPDIR:-/tmp}/shellkit-matrix.XXXXXX") || die "cannot create a temp dir" 3
trap 'rm -rf "${work:?}"' EXIT INT TERM HUP

sum() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    openssl dgst -sha256 "$1" | awk '{print $NF}'
  fi
}

fails=0
ran=0
skipped=0

for v in $versions; do
  [ -n "$v" ] || continue
  say "== $v -> $current"
  dir="$work/$v"
  mkdir -p "$dir"

  if ! gh release download "v$v" --repo "$repo" --dir "$dir" \
    --pattern "shellkit-$v.tar.gz" --clobber >/dev/null 2>&1; then
    say "   SKIP: cannot download v$v (offline or the release has no tarball)"
    skipped=$((skipped + 1))
    printf '%s\n' "NA upgrade-matrix|$v: 取不到已发布资产（离线或该版本无 tarball）"
    continue
  fi

  tar -C "$dir" -xzf "$dir/shellkit-$v.tar.gz" || {
    say "   FAIL: cannot extract v$v"
    fails=$((fails + 1))
    continue
  }
  oldcli="$dir/shellkit-$v/shellkit"
  [ -x "$oldcli" ] || {
    say "   SKIP: v$v has no executable CLI (too old to scaffold)"
    skipped=$((skipped + 1))
    continue
  }

  proj="$dir/proj"
  if ! bash "$oldcli" new "$proj" --name tool --cmd run --yes >"$dir/new.log" 2>&1; then
    say "   SKIP: v$v CLI cannot scaffold a project (see $dir/new.log)"
    skipped=$((skipped + 1))
    continue
  fi

  printf 'MINE\n' >"$proj/user-note.txt"
  mine_before=$(sum "$proj/user-note.txt")
  ran=$((ran + 1))

  out=$(bash "$SK" upgrade "$proj" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    say "   FAIL: upgrade from $v exited $rc"
    printf '%s\n' "$out" | tail -5 >&2
    fails=$((fails + 1))
    continue
  fi

  # 工程的版本在 vendor 副本里，不在工程根（工程根没有 VERSION 文件）
  got=$(tr -d '[:space:]' <"$proj/vendor/shellkit/VERSION" 2>/dev/null)
  [ "$got" = "$current" ] || {
    say "   FAIL: VERSION is '$got', want '$current'"
    fails=$((fails + 1))
    continue
  }
  [ "$(sum "$proj/user-note.txt")" = "$mine_before" ] || {
    say "   FAIL: the user's own file changed"
    fails=$((fails + 1))
    continue
  }

  if [ -e "$proj/.shellkit-new" ] || [ -e "$proj/.shellkit-old" ]; then
    say "   FAIL: the upgrade left .shellkit-new/.shellkit-old behind"
    fails=$((fails + 1))
    continue
  fi
  leftovers=0
  for f in "$proj"/.shellkit-manifest.tmp.*; do
    [ -e "$f" ] || continue
    leftovers=$((leftovers + 1))
  done
  [ "$leftovers" -eq 0 ] || {
    say "   FAIL: the manifest left $leftovers temp file(s)"
    fails=$((fails + 1))
    continue
  }

  out2=$(bash "$SK" upgrade "$proj" 2>&1)
  rc2=$?
  if [ "$rc2" -ne 0 ]; then
    say "   FAIL: a second upgrade exited $rc2 (not idempotent)"
    printf '%s\n' "$out2" | tail -5 >&2
    fails=$((fails + 1))
    continue
  fi
  case "$out2" in
    *"already up to date"* | *"已经最新"*) ;;
    *) say "   WARN: the second upgrade did not say 'already up to date'" ;;
  esac

  # --- 7. 生命周期一圈：装 → 卸 → 重装 → 再升级 ---
  prefix="$dir/prefix"
  if ! "$SK" install-self --prefix "$prefix" >"$dir/install.log" 2>&1; then
    say "   FAIL: install-self into a temp prefix exited non-zero (see $dir/install.log)"
    fails=$((fails + 1))
    continue
  fi
  [ -x "$prefix/bin/shellkit" ] || {
    say "   FAIL: install-self did not produce $prefix/bin/shellkit"
    fails=$((fails + 1))
    continue
  }
  if ! "$SK" uninstall-self --prefix "$prefix" >"$dir/uninstall.log" 2>&1; then
    say "   FAIL: uninstall-self exited non-zero (see $dir/uninstall.log)"
    fails=$((fails + 1))
    continue
  fi
  [ ! -e "$prefix/bin/shellkit" ] || {
    say "   FAIL: uninstall-self left the CLI behind"
    fails=$((fails + 1))
    continue
  }
  [ ! -e "$prefix/share/shellkit/.shellkit-install-manifest" ] || {
    say "   FAIL: uninstall-self left its install manifest behind"
    fails=$((fails + 1))
    continue
  }
  if ! "$SK" install-self --prefix "$prefix" >"$dir/reinstall.log" 2>&1; then
    say "   FAIL: reinstall into the same prefix failed (see $dir/reinstall.log)"
    fails=$((fails + 1))
    continue
  fi
  out3=$("$prefix/bin/shellkit" upgrade "$proj" 2>&1)
  rc3=$?
  if [ "$rc3" -ne 0 ]; then
    say "   FAIL: the reinstalled CLI cannot upgrade the project (exited $rc3)"
    printf '%s\n' "$out3" | tail -5 >&2
    fails=$((fails + 1))
    continue
  fi
  got3=$(tr -d '[:space:]' <"$proj/vendor/shellkit/VERSION" 2>/dev/null)
  [ "$got3" = "$current" ] || {
    say "   FAIL: after the reinstall the project VERSION is '$got3', want '$current'"
    fails=$((fails + 1))
    continue
  }
  [ "$(sum "$proj/user-note.txt")" = "$mine_before" ] || {
    say "   FAIL: the user's own file changed during the lifecycle round"
    fails=$((fails + 1))
    continue
  }

  say "   ok: $v -> $current (install → uninstall → reinstall → upgrade)"
  printf '%s\n' "CELL upgrade-matrix|$v -> $current: passed"
  printf '%s\n' "CELL upgrade-matrix|$v lifecycle (install/uninstall/reinstall): passed"
done

say "summary: ran=$ran skipped=$skipped fails=$fails"
[ "$fails" -eq 0 ] || exit 1
if [ "$strict" = "1" ] && [ "$ran" -eq 0 ]; then
  die "strict mode: not a single upgrade source was actually tested (every version was skipped)" 1
fi
exit 0
