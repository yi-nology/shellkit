#!/usr/bin/env bash
#
# RC 验证（v1.0.0 门槛，issue #129）：对**给定项目**跑生命周期一圈。
#
#   bash tools/rc_check.sh PROJECT_DIR [PROJECT_DIR...]
#   bash tools/rc_check.sh --keep PROJECT_DIR        # 保留临时目录便于排查
#
# 每个项目都要证明：
#   1. 用当前 CLI 升级成功，vendor 里的 VERSION 跟上；
#   2. 用户自己的文件（清单里没记的、vendor 之外的）字节不变；
#   3. 没有 .shellkit-new / .shellkit-old / 清单 .tmp 残骸；
#   4. 再升一次是幂等（already up to date）；
#   5. install-self → uninstall-self 之后 bin 与安装清单消失；
#   6. 重装出来的 CLI 还能再升级同一个项目，且版本仍正确。
#
# 安全：**绝不改传入的工程** —— 每个项目先整目录复制到临时目录，所有写操作都在副本上。
#
# 退出码：0 全过 / 1 有失败 / 2 用法错 / 3 前置条件不满足
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SK="$ROOT/shellkit"
CURRENT=$(tr -d "[:space:]" <"$ROOT/VERSION")
KEEP=0

say() { printf "[rc] %s\n" "$*" >&2; }
die() {
  printf "[rc] FAIL: %s\n" "$1" >&2
  exit "${2:-1}"
}

projects=""
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1 ;;
    -h | --help)
      printf "usage: %s [--keep] PROJECT_DIR [PROJECT_DIR...]\n" "${0##*/}"
      exit 0
      ;;
    -*) die "unknown option: $1" 2 ;;
    *) projects="$projects $1" ;;
  esac
  shift
done

[ -n "$projects" ] || die "give at least one project directory" 2
[ -x "$SK" ] || die "the current CLI is missing: $SK" 3
command -v tar >/dev/null 2>&1 || die "tar is required" 3

work=$(mktemp -d "${TMPDIR:-/tmp}/shellkit-rc.XXXXXX") || die "cannot create a temp dir" 3
cleanup() {
  if [ "$KEEP" = "1" ]; then
    say "keeping $work"
    return 0
  fi
  rm -rf "${work:?}"
}
trap cleanup EXIT INT TERM HUP

sum() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# _user_files_hashes DIR OUT —— 用户文件的路径+摘要（清单里没记的、vendor 之外的）
_user_files_hashes() {
  local __dir=$1 __out=$2 __rel
  : >"$__out"
  (
    cd "$__dir" || exit 1
    find . -type f \
      -not -path "./.git/*" \
      -not -path "./vendor/*" \
      -not -name ".shellkit-manifest" | sed 's|^\./||' | LC_ALL=C sort
  ) >"$work/all-$3.txt" || return 1
  while IFS= read -r __rel; do
    [ -n "$__rel" ] || continue
    awk -v rel="$__rel" '$1 == "@file" && $2 == rel { found = 1 } END { exit !found }' \
      "$__dir/.shellkit-manifest" && continue
    printf "%s\t%s\n" "$__rel" "$(sum "$__dir/$__rel")" >>"$__out"
  done <"$work/all-$3.txt"
  return 0
}

fails=0
ran=0

for proj in $projects; do
  say "== $proj"
  [ -d "$proj" ] || {
    say "   FAIL: not a directory: $proj"
    fails=$((fails + 1))
    continue
  }
  [ -f "$proj/.shellkit-manifest" ] || {
    say "   FAIL: no .shellkit-manifest (not a shellkit project?)"
    fails=$((fails + 1))
    continue
  }

  ran=$((ran + 1))
  copy="$work/p$ran"
  prefix="$work/prefix$ran"
  mkdir -p "$copy" || {
    say "   FAIL: cannot create $copy"
    fails=$((fails + 1))
    continue
  }
  tar -C "$proj" -cf - --exclude=./.git . 2>/dev/null | tar -C "$copy" -xf - || {
    say "   FAIL: cannot copy the project"
    fails=$((fails + 1))
    continue
  }

  _user_files_hashes "$copy" "$work/user.$ran.before" "$ran.before" || {
    say "   FAIL: cannot hash the user files"
    fails=$((fails + 1))
    continue
  }

  out=$("$SK" upgrade "$copy" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    say "   FAIL: upgrade exited $rc"
    printf "%s\n" "$out" | tail -5 >&2
    fails=$((fails + 1))
    continue
  fi

  got=$(tr -d "[:space:]" <"$copy/vendor/shellkit/VERSION" 2>/dev/null)
  [ "$got" = "$CURRENT" ] || {
    say "   FAIL: vendor VERSION is '$got', want '$CURRENT'"
    fails=$((fails + 1))
    continue
  }

  _user_files_hashes "$copy" "$work/user.$ran.after" "$ran.after" || {
    say "   FAIL: cannot hash the user files after the upgrade"
    fails=$((fails + 1))
    continue
  }
  if ! cmp -s "$work/user.$ran.before" "$work/user.$ran.after"; then
    say "   FAIL: a user-owned file changed during the upgrade"
    diff "$work/user.$ran.before" "$work/user.$ran.after" | sed -n "1,10p" >&2
    fails=$((fails + 1))
    continue
  fi

  if [ -e "$copy/.shellkit-new" ] || [ -e "$copy/.shellkit-old" ]; then
    say "   FAIL: the upgrade left .shellkit-new/.shellkit-old behind"
    fails=$((fails + 1))
    continue
  fi
  leftovers=0
  for f in "$copy"/.shellkit-manifest.tmp.*; do
    [ -e "$f" ] || continue
    leftovers=$((leftovers + 1))
  done
  [ "$leftovers" -eq 0 ] || {
    say "   FAIL: the manifest left $leftovers temp file(s)"
    fails=$((fails + 1))
    continue
  }

  out2=$("$SK" upgrade "$copy" 2>&1)
  rc2=$?
  [ "$rc2" -eq 0 ] || {
    say "   FAIL: a second upgrade exited $rc2"
    fails=$((fails + 1))
    continue
  }
  case "$out2" in
    *"already up to date"* | *"已经最新"*) ;;
    *) say "   WARN: the second upgrade did not say 'already up to date'" ;;
  esac

  if ! "$SK" install-self --prefix "$prefix" >"$work/install.$ran.log" 2>&1; then
    say "   FAIL: install-self failed (see $work/install.$ran.log)"
    fails=$((fails + 1))
    continue
  fi
  [ -x "$prefix/bin/shellkit" ] || {
    say "   FAIL: install-self produced no bin/shellkit"
    fails=$((fails + 1))
    continue
  }

  if ! "$SK" uninstall-self --prefix "$prefix" >"$work/uninstall.$ran.log" 2>&1; then
    say "   FAIL: uninstall-self failed (see $work/uninstall.$ran.log)"
    fails=$((fails + 1))
    continue
  fi
  [ ! -e "$prefix/bin/shellkit" ] || {
    say "   FAIL: uninstall left the CLI behind"
    fails=$((fails + 1))
    continue
  }
  [ ! -e "$prefix/share/shellkit/.shellkit-install-manifest" ] || {
    say "   FAIL: uninstall left its manifest"
    fails=$((fails + 1))
    continue
  }

  if ! "$SK" install-self --prefix "$prefix" >"$work/reinstall.$ran.log" 2>&1; then
    say "   FAIL: reinstall failed (see $work/reinstall.$ran.log)"
    fails=$((fails + 1))
    continue
  fi
  out3=$("$prefix/bin/shellkit" upgrade "$copy" 2>&1)
  rc3=$?
  if [ "$rc3" -ne 0 ]; then
    say "   FAIL: the reinstalled CLI cannot upgrade (exited $rc3)"
    printf '%s\n' "$out3" | tail -5 >&2
    fails=$((fails + 1))
    continue
  fi
  got3=$(tr -d "[:space:]" <"$copy/vendor/shellkit/VERSION" 2>/dev/null)
  [ "$got3" = "$CURRENT" ] || {
    say "   FAIL: after reinstall the vendor VERSION is '$got3'"
    fails=$((fails + 1))
    continue
  }

  say "   ok: upgrade → idempotent → install/uninstall/reinstall → upgrade ($(basename "$proj"))"
  printf "%s\n" "CELL rc-check|$proj: passed"
done

say "summary: ran=$ran fails=$fails"
[ "$fails" -eq 0 ] || exit 1
exit 0
