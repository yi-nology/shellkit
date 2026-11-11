#!/usr/bin/env bash
# 升级日志可靠性的回归（issue #44）。
#
# 三个要守的点：
#   1) 日志损坏（截断 / 垃圾行）必须告警，不能静默当成「用户改过」
#   2) 上一轮的旧记录只留「指纹还与磁盘对得上」的 —— 记录不无限累积
#   3) 日志落盘后有持久化边界上的努力（sync），且 sync 失败不致命
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"

work=$(tmpdir)
tpl="$work/tpl"
cp -R "$TEST_ROOT/templates" "$tpl"

# TAB：日志一行是「相对路径 TAB 旧基线 TAB 目标指纹」，断言模式里也要拼 TAB
TAB=$(printf '\t')

# 日志函数在 CLI 脚本里、不在库里：按函数边界抽出来，配真库跑。
# 抽取锚点是函数注释行 —— 误锚漏行 bash -n 会立刻红。
sed -n '/^# _sk_upgrade_journal_file/,/^cmd_upgrade()/p' "$TEST_ROOT/shellkit" | sed '$d' >"$work/journal.sh"
bash -n "$work/journal.sh" || _fail "extracted journal functions must be valid bash"
# shellcheck disable=SC1090
. "$work/journal.sh"

# mk_project DIR NAME —— 造一个只有清单的工程（够升级用，不必跑 new）
mk_project() {
  local d=$1 name=$2
  mkdir -p "$d" || _fail "mkdir failed: $d"
  cat >"$d/.shellkit-manifest" <<EOF
# shellkit manifest v1
manifest_version=2
version=0.11.0
template_version=0.11.0
name=$name
commands=run
EOF
}

# ---------- 日志损坏必须告警（e2e：真 CLI） ----------
p1="$work/damaged"
mk_project "$p1" "damaged"
printf 'garbage line without tabs\n' >"$p1/.shellkit-upgrade-journal"
printf 'a\tb\n' >>"$p1/.shellkit-upgrade-journal"
out=$("$TEST_ROOT/shellkit" upgrade "$p1" --template "$tpl" 2>&1)
rc=0
"$TEST_ROOT/shellkit" upgrade "$p1" --template "$tpl" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "a damaged journal must not break the upgrade"
assert_contains "$out" "the upgrade journal is damaged" "a damaged journal must be reported"
# 垃圾日志不能把文件误判成用户改动 —— 该补的文件照常补上
assert_contains "$out" "added" "the upgrade must still apply template updates"

# ---------- 旧记录的去重与有界累积（单元：直接驱动 _sk_upgrade_journal_write） ----------
p2="$work/prune"
mkdir -p "$p2" || _fail "mkdir failed"
printf 'content-A\n' >"$p2/a.txt"
printf 'content-B\n' >"$p2/b.txt"
shaA=$(os_sha256 "$p2/a.txt")
shaB=$(os_sha256 "$p2/b.txt")
# 这一轮 a.txt 要更新：模板文件就放在 $work/a.txt（__tpl=$work、__rel=a.txt）
printf 'tpl-A\n' >"$work/a.txt"
shaTplA=$(os_sha256 "$work/a.txt")

# 上一轮留下的三条记录：a.txt 的死记录（指纹在磁盘上不存在）、
# a.txt 的活记录（指纹 == 磁盘当前内容）、b.txt 的活记录。
_SK_UPGRADE_JRELS=(a.txt a.txt b.txt)
_SK_UPGRADE_JOLDS=(oldbase oldbase base-b)
_SK_UPGRADE_JNEWS=(deadbeef0000 "$shaA" "$shaB")
# 这一轮的动作表：a.txt 更新（模板指纹 tplA），b.txt 不动。
_SK_UPGRADE_RELS=(a.txt b.txt)
_SK_UPGRADE_ACTS=(U S)
_SK_UPGRADE_BASES=("$shaA" "$shaB")

_sk_upgrade_journal_write "$p2" "$work" || _fail "journal write must succeed"
jf="$p2/.shellkit-upgrade-journal"
if [ ! -f "$jf" ]; then
  _fail "the journal must exist while the round is in flight"
fi
jtxt=$(cat "$jf")
case "$jtxt" in
  *deadbeef*) _fail "a stale record whose fingerprint is not on disk must be dropped" ;;
esac
want="a.txt${TAB}${shaA}${TAB}${shaTplA}"
case "$jtxt" in
  *"$want"*) ;;
  *) _fail "the new record for a.txt must point at the template fingerprint" ;;
esac
want="a.txt${TAB}oldbase${TAB}${shaA}"
case "$jtxt" in
  *"$want"*) ;;
  *) _fail "the live old record for a.txt must be kept (disk still holds that content)" ;;
esac
want="b.txt${TAB}base-b${TAB}${shaB}"
case "$jtxt" in
  *"$want"*) ;;
  *) _fail "the live old record for b.txt must be kept" ;;
esac
n_lines=$(printf '%s\n' "$jtxt" | wc -l | tr -d ' ')
assert_eq "3" "$n_lines" "the journal must not accumulate dead records"

# ---------- sync 失败不致命（sync 被桩成必败，日志照样写成功） ----------
p3="$work/syncfail"
mkdir -p "$p3"
printf 'content-C\n' >"$p3/c.txt"
# act=U 的目标指纹取自 $__tpl/$__rel（= $work/c.txt），模板文件必须在
printf 'tpl-C\n' >"$work/c.txt"
_SK_UPGRADE_JRELS=()
_SK_UPGRADE_JOLDS=()
_SK_UPGRADE_JNEWS=()
_SK_UPGRADE_RELS=(c.txt)
_SK_UPGRADE_ACTS=(U)
_SK_UPGRADE_BASES=("-")
# 覆盖 sync：恒败，模拟「sync 在这台机器上不认操作数」的最坏情况
sync() { return 127; }
_sk_upgrade_journal_write "$p3" "$work" || _fail "journal write must succeed even when sync fails"
jf="$p3/.shellkit-upgrade-journal"
if [ ! -f "$jf" ]; then
  _fail "the journal must exist even when sync fails"
fi
assert_contains "$(cat "$jf")" "c.txt" "the record must be intact"

# ---------- 清单提交成功后日志清掉（既有语义不被去重改动破坏） ----------
_sk_upgrade_journal_clear "$p3" || _fail "journal clear must succeed"
if [ -e "$p3/.shellkit-upgrade-journal" ]; then
  _fail "the journal must be gone after a successful commit"
fi

exit 0
