#!/usr/bin/env bash
# 安装 / 卸载的所有权语义（评估 2026-11-16 的 P0）：
#   安装时保护用户文件，不等于卸载时也保护。
#
# 以前 MANIFEST 由 find . -type f 生成（目录里有什么就记什么），于是：
#   装 -> 用户放一个 my-own.sh -> 重装（文件被保留、同时被记进 MANIFEST）-> 卸载把它删掉。
# 现在：MANIFEST 只登记「我们装的」，卸载按带指纹的所有权清单逐条比对，
# 用户新增/改过的一律保留；--purge 才全清。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

SK="$TEST_ROOT/shellkit"

sum() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

d=$(tmpdir)
prefix="$d/prefix"
"$SK" install-self --prefix "$prefix" >/dev/null 2>&1 || _fail "install-self must succeed"
dest="$prefix/share/shellkit"
assert_true test -f "$dest/MANIFEST"

printf 'MINE\n' >"$dest/my-own.sh"
printf '\n# user edit\n' >>"$dest/lib/core/log.sh"
mine_sum=$(sum "$dest/my-own.sh")

rc=0
"$SK" install-self --prefix "$prefix" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "the reinstall must succeed"
assert_eq "$mine_sum" "$(sum "$dest/my-own.sh")" "the reinstall must keep the user's own file"
assert_contains "$(cat "$dest/lib/core/log.sh")" "user edit" "the reinstall must keep the user's edit"

# 关键判据：用户文件不许被记进 MANIFEST —— 记进去就等于卸载时会删
if grep -q 'my-own.sh' "$dest/MANIFEST"; then
  _fail "the manifest must not record user-added files (it did: my-own.sh)"
fi

rc=0
"$SK" uninstall-self --prefix "$prefix" >"$d/uninstall.log" 2>&1 || rc=$?
assert_eq "0" "$rc" "the uninstall must succeed even when it keeps user files"
assert_true test -f "$dest/my-own.sh"
assert_eq "$mine_sum" "$(sum "$dest/my-own.sh")" "the user's own file must survive the uninstall"
assert_contains "$(cat "$dest/lib/core/log.sh")" "user edit" "the user's edit must survive the uninstall"
assert_false test -f "$dest/LICENSE"
assert_not_contains "$(cat "$d/uninstall.log")" "leftover files were kept" \
  "keeping user files is not a failure and must not be reported as leftovers"
assert_contains "$(cat "$d/uninstall.log")" "kept files that are not ours" \
  "the uninstall must say what it kept and how to remove it"

# --purge：用户明确要求全清时才回到「全删」语义
prefix2="$d/prefix2"
"$SK" install-self --prefix "$prefix2" >/dev/null 2>&1 || _fail "the second install must succeed"
dest2="$prefix2/share/shellkit"
printf 'MINE\n' >"$dest2/my-own.sh"
rc=0
"$SK" uninstall-self --prefix "$prefix2" --purge >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "the purge must succeed"
assert_false test -d "$dest2"
assert_false test -e "$prefix2/bin/shellkit"

# ---------- #123：卸载保留用户修改后，重装不许静默覆盖 ----------
#
# 卸载（不带 --purge）保留用户改过的文件时，所有权基线不能随卸载消失：
# 重装/更新要能认出「这份不是我们装的原文」而继续保留；只有 --force 才覆盖。
p3="$d/prefix3"
"$SK" install-self --prefix "$p3" >/dev/null 2>&1 || _fail "the third install must succeed"
d3="$p3/share/shellkit"
orig_log_sum=$(sum "$d3/lib/core/log.sh")
printf '\n# user edit survived uninstall\n' >>"$d3/lib/core/log.sh"
edit_log_sum=$(sum "$d3/lib/core/log.sh")
printf 'MINE\n' >"$d3/my-own-3.sh"
mine3_sum=$(sum "$d3/my-own-3.sh")

unlog="$d/uninstall3.log"
rc=0
"$SK" uninstall-self --prefix "$p3" >"$unlog" 2>&1 || rc=$?
assert_eq "0" "$rc" "the uninstall keeping user edits must succeed"
assert_eq "$edit_log_sum" "$(sum "$d3/lib/core/log.sh")" "the user edit must survive uninstall"
assert_contains "$(cat "$unlog")" "kept files that are not ours" \
  "the uninstall must report the kept files"
# 卸载后基线必须留下：没有它，重装就分不清「上游原文」与「用户改过」
assert_true test -f "$d3/.shellkit-install-manifest"

relog="$d/reinstall3.log"
rc=0
"$SK" install-self --prefix "$p3" >"$relog" 2>&1 || rc=$?
assert_eq "0" "$rc" "the reinstall after uninstall must succeed"
assert_eq "$edit_log_sum" "$(sum "$d3/lib/core/log.sh")" \
  "the reinstall must not silently overwrite the user edit kept by uninstall"
assert_eq "$mine3_sum" "$(sum "$d3/my-own-3.sh")" \
  "the reinstall must keep the user-added file"
assert_contains "$(cat "$relog")" "modified locally, left alone" \
  "the reinstall must report the kept user edit"
# 基线仍是上游原文的指纹 —— 推进成用户内容就等于把编辑记成「我们装的原文」
if grep -q "$(printf '%s\t%s' 'lib/core/log.sh' "$edit_log_sum")" "$d3/.shellkit-install-manifest"; then
  _fail "the ownership baseline must not advance to the user's edited content"
fi
assert_contains "$(cat "$d3/.shellkit-install-manifest")" "lib/core/log.sh" \
  "the kept file must stay in the ownership baseline"
assert_not_contains "$(cat "$d3/.shellkit-install-manifest")" "my-own-3.sh" \
  "user-added files must not enter the ownership baseline"

# 反例：同一条链路带上 --force，用户修改必须被显式覆盖（逃逸口只对开关开）
frc=0
"$SK" install-self --prefix "$p3" --force >/dev/null 2>&1 || frc=$?
assert_eq "0" "$frc" "the forced reinstall must succeed"
assert_eq "$(sum "$TEST_ROOT/lib/core/log.sh")" "$(sum "$d3/lib/core/log.sh")" \
  "an explicit --force must overwrite the user edit"
assert_ne "$orig_log_sum" "$edit_log_sum" "the fixture edit must change the hash"
assert_eq "$mine3_sum" "$(sum "$d3/my-own-3.sh")" \
  "--force must not delete the user's own files"

# 没有基线的既有同名文件（旧安装 / 资产目录里的同名文件）：默认保留并告警，
# 只有 --force 才允许覆盖。这是 #123 的另一半：不能靠「没基线」就落进 W。
p4="$d/prefix4"
d4="$p4/share/shellkit"
mkdir -p "$d4/lib/core"
printf '# pre-existing local file\n' >"$d4/lib/core/log.sh"
pre_sum=$(sum "$d4/lib/core/log.sh")
inc="$d/install4.log"
rc=0
"$SK" install-self --prefix "$p4" >"$inc" 2>&1 || rc=$?
assert_eq "0" "$rc" "installing over a pre-existing same-name file must succeed"
assert_eq "$pre_sum" "$(sum "$d4/lib/core/log.sh")" \
  "a same-name file without an ownership baseline must not be overwritten by default"
assert_contains "$(cat "$inc")" "no ownership baseline" \
  "the install must explain that the file was kept for lack of a baseline"
rc=0
"$SK" install-self --prefix "$p4" --force >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "the forced install must succeed"
assert_eq "$(sum "$TEST_ROOT/lib/core/log.sh")" "$(sum "$d4/lib/core/log.sh")" \
  "an explicit --force must overwrite a same-name file without a baseline"

# ---------- #124：没有指纹清单的旧安装，普通卸载默认 fail-closed ----------
#
# 旧 MANIFEST 由 find 生成，里面的用户文件/用户修改无法与新装的文件区分。
# 只告警就按 MANIFEST 全删，与「默认保护用户文件」契约冲突；默认必须拒绝，
# 把旧语义留给显式 --legacy。
p5="$d/prefix5"
"$SK" install-self --prefix "$p5" >/dev/null 2>&1 || _fail "the fifth install must succeed"
d5="$p5/share/shellkit"
rm -f "$d5/.shellkit-install-manifest"
printf '\n# legacy user edit\n' >>"$d5/lib/core/log.sh"
legacy_sum=$(sum "$d5/lib/core/log.sh")
untouched_sum=$(sum "$d5/LICENSE")

lout="$d/legacy-default.log"
rc=0
"$SK" uninstall-self --prefix "$p5" >"$lout" 2>&1 || rc=$?
assert_eq "3" "$rc" "a legacy install without fingerprints must be refused by default"
assert_contains "$(cat "$lout")" "refusing to remove a legacy install without ownership fingerprints" \
  "the refusal must explain why nothing was removed"
assert_contains "$(cat "$lout")" "--legacy" "the refusal must point at the explicit escape hatch"
assert_eq "$legacy_sum" "$(sum "$d5/lib/core/log.sh")" \
  "the default legacy uninstall must not delete the user's edited file"
assert_eq "$untouched_sum" "$(sum "$d5/LICENSE")" \
  "the default legacy uninstall must not delete even untouched files"
assert_true test -f "$d5/MANIFEST"

# 显式 --legacy：旧语义（按 MANIFEST 全删）必须是可用的逃逸口
rc=0
"$SK" uninstall-self --prefix "$p5" --legacy >"$d/legacy-explicit.log" 2>&1 || rc=$?
assert_eq "0" "$rc" "an explicit --legacy uninstall must succeed"
assert_false test -e "$d5/lib/core/log.sh"
assert_false test -e "$d5/LICENSE"
assert_contains "$(cat "$d/legacy-explicit.log")" "MANIFEST will be removed (--legacy)" \
  "the explicit legacy mode must say what it deletes"

# 有指纹清单时 --legacy 不许绕过所有权保护（全清请用 --purge）
p6="$d/prefix6"
"$SK" install-self --prefix "$p6" >/dev/null 2>&1 || _fail "the sixth install must succeed"
d6="$p6/share/shellkit"
printf '\n# own edit\n' >>"$d6/lib/core/log.sh"
own_sum=$(sum "$d6/lib/core/log.sh")
rc=0
"$SK" uninstall-self --prefix "$p6" --legacy >"$d/legacy-ignored.log" 2>&1 || rc=$?
assert_eq "0" "$rc" "uninstall with fingerprints and --legacy must still succeed"
assert_eq "$own_sum" "$(sum "$d6/lib/core/log.sh")" \
  "--legacy must not delete user edits when ownership fingerprints exist"
assert_contains "$(cat "$d/legacy-ignored.log")" "using the default ownership checks" \
  "--legacy must say it is ignored for fingerprinted installs"


exit 0
