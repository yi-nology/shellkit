#!/usr/bin/env bash
#
# RC 验证（v1.0.0 门槛，issue #129）：对**给定项目**跑生命周期一圈。
#
#   bash tools/rc_check.sh [--keep] [--test-cmd CMD] PROJECT_DIR [PROJECT_DIR...]
#
# 自动识别两种工程形态：
#   脚手架工程（有 .shellkit-manifest）：升级 → 幂等 → 安装/卸载/重装 → 再升级；
#   vendor 工程（只有 vendor/shellkit、没有清单）：vendor 同步 → 幂等 → 安装/卸载/重装。
#
# 给了 --test-cmd 时，还会在同步/升级前后各跑一次工程自己的测试，判据是
# 「不许新增失败」—— 同步前就红的工程只记 WARN，不冤枉它。
#
# 两种形态都断言：
#   - vendor/shellkit/VERSION 跟上当前 VERSION；
#   - 用户自己的文件（vendor 之外的、清单里没记的）字节不变；
#   - 没有 .shellkit-new / .shellkit-old / 清单 .tmp 残骸；
#   - install-self → uninstall-self 后 bin 与安装清单消失，重装后仍能用。
#
# 安全：**绝不改传入的工程** —— 每个项目先整目录复制，所有写操作都在副本上。
#
# 退出码：0 全过 / 1 有失败 / 2 用法错 / 3 前置条件不满足
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SK="$ROOT/shellkit"
CURRENT=$(tr -d "[:space:]" <"$ROOT/VERSION")
KEEP=0
TEST_CMD=""

say() { printf "[rc] %s\n" "$*" >&2; }
die() {
  printf "[rc] FAIL: %s\n" "$1" >&2
  exit "${2:-1}"
}

projects=""
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1 ;;
    --test-cmd)
      [ $# -ge 2 ] || die "--test-cmd needs a command" 2
      TEST_CMD=$2
      shift
      ;;
    --test-cmd=*) TEST_CMD=${1#*=} ;;
    -h | --help)
      printf "usage: %s [--keep] [--test-cmd CMD] PROJECT_DIR [PROJECT_DIR...]\n" "${0##*/}"
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

# _user_files_hashes DIR OUT TAG —— 用户文件的「路径 + 摘要」
_user_files_hashes() {
  local __dir=$1 __out=$2 __tag=$3 __rel
  : >"$__out"
  (
    cd "$__dir" || exit 1
    find . -type f \
      -not -path "./.git/*" \
      -not -path "./vendor/*" \
      -not -name ".shellkit-manifest" | sed 's|^\./||' | LC_ALL=C sort
  ) >"$work/all-$__tag.txt" || return 1
  while IFS= read -r __rel; do
    [ -n "$__rel" ] || continue
    if [ -f "$__dir/.shellkit-manifest" ] &&
      awk -v rel="$__rel" '$1 == "@file" && $2 == rel { found = 1 } END { exit !found }' \
        "$__dir/.shellkit-manifest"; then
      continue
    fi
    printf "%s\t%s\n" "$__rel" "$(sum "$__dir/$__rel")" >>"$__out"
  done <"$work/all-$__tag.txt"
  return 0
}

# _run_tests DIR LOG OUTFILE —— 在副本里跑工程自己的测试；返回其退出码
_run_tests() {
  local __dir=$1 __log=$2 __rc=0
  (cd "$__dir" && sh -c "$TEST_CMD") >"$__log" 2>&1 || __rc=$?
  return "$__rc"
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

  mode=""
  if [ -f "$proj/.shellkit-manifest" ]; then
    mode=scaffold
  elif [ -f "$proj/vendor/shellkit/VERSION" ]; then
    mode=vendor
  else
    say "   FAIL: neither a scaffolded project (no .shellkit-manifest) nor a vendor consumer (no vendor/shellkit)"
    fails=$((fails + 1))
    continue
  fi

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
  say "   mode: $mode"

  baseline_rc=0
  if [ -n "$TEST_CMD" ]; then
    _run_tests "$copy" "$work/test.$ran.before.log" || baseline_rc=$?
  fi

  _user_files_hashes "$copy" "$work/user.$ran.before" "$ran.before" || {
    say "   FAIL: cannot hash the user files"
    fails=$((fails + 1))
    continue
  }

  if [ "$mode" = "scaffold" ]; then
    out=$("$SK" upgrade "$copy" 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ]; then
      say "   FAIL: upgrade exited $rc"
      printf "%s\n" "$out" | tail -5 >&2
      fails=$((fails + 1))
      continue
    fi
  else
    if [ -f "$copy/vendor/shellkit/.shellkit-vendor-manifest" ]; then
      out=$("$SK" vendor "$copy" 2>&1)
      rc=$?
    else
      # 没有所有权基线的旧副本：vendor 会保留每个文件并 fail-closed（issue #137）。
      # 副本里没有用户改动可保护，用 --force 走「明确选择覆盖」这条合法路径。
      say "   note: legacy vendor copy (no ownership baseline) — using vendor --force"
      out=$("$SK" vendor --force "$copy" 2>&1)
      rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
      say "   FAIL: vendor sync exited $rc"
      printf "%s\n" "$out" | tail -5 >&2
      fails=$((fails + 1))
      continue
    fi
  fi

  got=$(tr -d "[:space:]" <"$copy/vendor/shellkit/VERSION" 2>/dev/null)
  [ "$got" = "$CURRENT" ] || {
    say "   FAIL: vendor VERSION is '$got', want '$CURRENT'"
    fails=$((fails + 1))
    continue
  }

  _user_files_hashes "$copy" "$work/user.$ran.after" "$ran.after" || {
    say "   FAIL: cannot hash the user files after the sync"
    fails=$((fails + 1))
    continue
  }
  if ! cmp -s "$work/user.$ran.before" "$work/user.$ran.after"; then
    say "   FAIL: a user-owned file changed during the sync"
    diff "$work/user.$ran.before" "$work/user.$ran.after" | sed -n "1,10p" >&2
    fails=$((fails + 1))
    continue
  fi

  if [ -e "$copy/.shellkit-new" ] || [ -e "$copy/.shellkit-old" ]; then
    say "   FAIL: the sync left .shellkit-new/.shellkit-old behind"
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

  # 幂等：脚手架再升级一次；vendor 工程要求 vendor --check 已是最新
  if [ "$mode" = "scaffold" ]; then
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
  else
    if ! "$SK" vendor --check "$copy" >"$work/vendorcheck.$ran.log" 2>&1; then
      say "   FAIL: vendor --check still reports an out-of-date copy after sync"
      fails=$((fails + 1))
      continue
    fi
  fi

  if [ -n "$TEST_CMD" ]; then
    after_rc=0
    _run_tests "$copy" "$work/test.$ran.after.log" || after_rc=$?
    if [ "$after_rc" -ne 0 ] && [ "$baseline_rc" -eq 0 ]; then
      say "   FAIL: the project's own tests turned red after the sync (rc=$after_rc, was green)"
      tail -5 "$work/test.$ran.after.log" >&2
      fails=$((fails + 1))
      continue
    fi
    if [ "$after_rc" -ne 0 ]; then
      say "   WARN: the project's own tests were already red before the sync (rc=$baseline_rc) and stayed red (rc=$after_rc)"
    fi
  fi

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
  if [ "$mode" = "scaffold" ]; then
    out3=$("$prefix/bin/shellkit" upgrade "$copy" 2>&1)
    rc3=$?
    if [ "$rc3" -ne 0 ]; then
      say "   FAIL: the reinstalled CLI cannot upgrade (exited $rc3)"
      printf "%s\n" "$out3" | tail -5 >&2
      fails=$((fails + 1))
      continue
    fi
  else
    if ! "$prefix/bin/shellkit" vendor --check "$copy" >"$work/reinstallcheck.$ran.log" 2>&1; then
      say "   FAIL: the reinstalled CLI reports the vendored copy as out of date"
      fails=$((fails + 1))
      continue
    fi
  fi
  got3=$(tr -d "[:space:]" <"$copy/vendor/shellkit/VERSION" 2>/dev/null)
  [ "$got3" = "$CURRENT" ] || {
    say "   FAIL: after reinstall the vendor VERSION is '$got3'"
    fails=$((fails + 1))
    continue
  }

  say "   ok: $mode — sync → idempotent → install/uninstall/reinstall ($(basename "$proj"))"
  printf "%s\n" "CELL rc-check|$proj ($mode): passed"
done

say "summary: ran=$ran fails=$fails"
[ "$fails" -eq 0 ] || exit 1
exit 0
