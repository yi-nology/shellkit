#!/usr/bin/env bash
# 所有权清单的 schema 版本（issue #78）。
#
# 四条判据：
#   1. 写出的清单首行是 manifest_version（与工程清单 .shellkit-manifest 同一种措辞）
#   2. 新清单读回：条目齐全，版本行**不**被记成「损坏」（不告警）
#   3. 老清单（没有版本行）读取行为与版本化之前一致
#   4. 未知 / 读不懂的版本：告警 + **整份拒读**（数组留空、返回 0）
#      —— 宁可让调用方走「没有清单」的退化判据，也绝不按猜出来的格式删文件。
#
# 注意：_sk_fs_own_read 把结果写进全局数组，**不能放进 $( ) 调用**（子 shell 里
# 的赋值拿不回来）—— stderr 一律重定向到文件再读。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"

work=$(tmpdir)
errf="$work/err.log"

# _read FILE —— 调用被测函数，结果在全局数组里，stderr 落到 $errf，rc 落到 $rc
rc=0
_read() {
  rc=0
  : >"$errf"
  _sk_fs_own_read "$1" 2>"$errf" || rc=$?
  return 0
}

# ---------- CASE: render 首行是版本行，其后才是条目 ----------
_SK_OWN_RELS=()
_SK_OWN_SUMS=()
_SK_OWN_RELS[${#_SK_OWN_RELS[@]}]="lib/a.sh"
_SK_OWN_SUMS[${#_SK_OWN_SUMS[@]}]="aaa111"
_SK_OWN_RELS[${#_SK_OWN_RELS[@]}]="lib/b.sh"
_SK_OWN_SUMS[${#_SK_OWN_SUMS[@]}]="bbb222"
txt=$(_sk_fs_own_render)
assert_eq "manifest_version=1" "$(printf '%s\n' "$txt" | sed -n '1p')" \
  "render must start with the schema version line"
assert_contains "$txt" "$(printf 'lib/a.sh\t%s' aaa111)" \
  "the first entry must follow the header"
assert_eq "3" "$(printf '%s\n' "$txt" | grep -c .)" \
  "one header line plus two entries"

# ---------- CASE: 新清单读回：条目齐、版本行不算损坏 ----------
newm="$work/own-new"
printf '%s\n' "$txt" >"$newm"
_read "$newm"
assert_eq "0" "$rc" "reading a new manifest must succeed"
assert_eq "" "$(cat "$errf")" "the version line must not be reported as damage"
assert_eq "2" "${#_SK_OWN_RELS[@]}" "both entries must be read back"
assert_eq "lib/a.sh" "${_SK_OWN_RELS[0]}" "the first entry survives the round trip"
assert_eq "bbb222" "${_SK_OWN_SUMS[1]}" "the fingerprints survive the round trip"

# ---------- CASE: 老清单（没有版本行）与从前逐字节一致 ----------
oldm="$work/own-old"
printf 'lib/a.sh\taaa111\n' >"$oldm"
_read "$oldm"
assert_eq "0" "$rc" "reading a legacy manifest must succeed"
assert_eq "" "$(cat "$errf")" "a legacy manifest must not warn"
assert_eq "1" "${#_SK_OWN_RELS[@]}" "the legacy entry must be read"
assert_eq "lib/a.sh" "${_SK_OWN_RELS[0]}" "the legacy entry must keep its path"

# ---------- CASE: 版本比本构建新 ⇒ 告警 + 整份拒读 ----------
futurem="$work/own-future"
printf 'manifest_version=99\nlib/a.sh\taaa111\n' >"$futurem"
_read "$futurem"
assert_eq "0" "$rc" "an unknown version must not fail the reader (callers are unguarded under set -e)"
assert_contains "$(cat "$errf")" "newer than this build understands" \
  "the refusal must name the problem"
assert_eq "0" "${#_SK_OWN_RELS[@]}" "entries must be refused, not guessed"

# ---------- CASE: 版本行读不懂 ⇒ 同样拒读 ----------
badver="$work/own-badver"
printf 'manifest_version=x\nlib/a.sh\taaa111\n' >"$badver"
_read "$badver"
assert_eq "0" "$rc" "an unreadable version must not fail the reader"
assert_contains "$(cat "$errf")" "version is unreadable" \
  "an unreadable version must be named"
assert_eq "0" "${#_SK_OWN_RELS[@]}" "an unreadable version must block interpretation"

# ---------- CASE: 集成 —— 真实代码路径写出的清单都带版本行 ----------
# skill 装下去的清单
mkdir -p "$work/skill"
rc=0
"$TEST_ROOT/shellkit" skill install --dir "$work/skill" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "skill install must succeed"
assert_eq "manifest_version=1" "$(sed -n '1p' "$work/skill/shellkit/.shellkit-skill-manifest")" \
  "the skill manifest written by the real code path carries the version line"

# vendor 清单（走 _sk_own_sync，与 install-self 同一个写入口）
rc=0
"$TEST_ROOT/shellkit" new "$work/proj" --name vercheck --yes >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "shellkit new must succeed"
rc=0
"$TEST_ROOT/shellkit" vendor "$work/proj" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "shellkit vendor must succeed"
assert_eq "manifest_version=1" \
  "$(sed -n '1p' "$work/proj/vendor/shellkit/.shellkit-vendor-manifest")" \
  "the vendor manifest written by the real code path carries the version line"

# 真装了 skill 才有清理价值：卸载仍然干净（版本行不干扰所有权判断）
rc=0
"$TEST_ROOT/shellkit" skill uninstall --dir "$work/skill" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "uninstall must work against a manifest that has a version line"
assert_false test -e "$work/skill/shellkit/SKILL.md"
