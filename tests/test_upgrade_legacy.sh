#!/usr/bin/env bash
# 旧清单（v0.10 时代，manifest_version<2）的升级迁移。
# 历史缺陷：旧模板校验**通过**的文件没有被标成「更新」—— 第一次升级不更新文件、
# 却把清单升成新版格式，第二次升级才真正更新（评审 P1）。
# 三态：文件未修改（必须一次升级到位）/ 已修改（永远不动）/ 基线损坏（当用户改过）。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"

work=$(tmpdir)
cur=$(cat "$TEST_ROOT/VERSION")

# mk_legacy DIR —— 造一个「v0.10 时代的工程」：
# 文件 = 当前模板 + 版本号 0.10.0 渲染（README 是唯一嵌 {{SHELLKIT_VERSION}} 的），
# 清单 = 旧格式（没有 manifest_version 行、template_version=0.10.0、
#        指纹记的是「当时的文件内容」—— v0.10 的语义）。
mk_legacy() {
  local d=$1 sum
  "$TEST_ROOT/shellkit" new "$d" --cmd run --yes >/dev/null 2>&1
  os_sed_i "s/版本 $cur/版本 0.10.0/" "$d/README.md"
  sum=$(os_sha256 "$d/README.md")
  cp "$d/.shellkit-manifest" "$d/m.new"
  os_sed_i '/^manifest_version=/d' "$d/m.new"
  os_sed_i 's/^template_version=.*/template_version=0.10.0/' "$d/m.new"
  os_sed_i "s|^@file README.md .*|@file README.md $sum|" "$d/m.new"
  mv "$d/m.new" "$d/.shellkit-manifest"
}

# CASE: 未修改的文件 —— 旧模板校验通过，第一次升级就要更新到位
p1="$work/legacy-clean"
mk_legacy "$p1"
rc=0
out=$("$TEST_ROOT/shellkit" upgrade "$p1" 2>&1) || rc=$?
assert_eq "0" "$rc" "migrating a verified-pristine project must succeed"
assert_contains "$out" "updated: README.md" "a verified-pristine file must update on the FIRST upgrade"
assert_contains "$(cat "$p1/README.md")" "版本 $cur" "the file must land on the new render in one shot"
assert_contains "$(cat "$p1/.shellkit-manifest")" "manifest_version=2" "the manifest must migrate to the new format"
# 第二次升级必须空转 —— 不能出现「修好又坏」的来回
out=$("$TEST_ROOT/shellkit" upgrade "$p1" 2>&1)
assert_contains "$out" "0 updated" "the second upgrade must be a no-op"

# CASE: 已修改的文件 —— v0.10 把「用户改过的内容」记成了指纹，
# 旧模板对照不上 ⇒ 一律不动，而且基线清空，下一次升级也不会当成「没动过」
p2="$work/legacy-modified"
mk_legacy "$p2"
printf 'LOCAL EDIT\n' >>"$p2/README.md"
sum=$(os_sha256 "$p2/README.md")
cp "$p2/.shellkit-manifest" "$p2/m.new"
os_sed_i "s|^@file README.md .*|@file README.md $sum|" "$p2/m.new"
mv "$p2/m.new" "$p2/.shellkit-manifest"
out=$("$TEST_ROOT/shellkit" upgrade "$p2" 2>&1)
assert_contains "$out" "left alone" "an unverifiable file must be left alone"
assert_contains "$(cat "$p2/README.md")" "LOCAL EDIT" "the user's edit must survive the first upgrade"
out=$("$TEST_ROOT/shellkit" upgrade "$p2" 2>&1)
assert_contains "$out" "left alone" "the second upgrade must not treat it as unmodified either"
assert_contains "$(cat "$p2/README.md")" "LOCAL EDIT" "the user's edit must survive every upgrade"

# CASE: 基线损坏 —— 指纹对不上任何东西，当「用户改过」处理，不动
p3="$work/legacy-broken"
mk_legacy "$p3"
cp "$p3/.shellkit-manifest" "$p3/m.new"
os_sed_i 's|^@file README.md .*|@file README.md 0000000000000000000000000000000000000000000000000000000000000000|' "$p3/m.new"
mv "$p3/m.new" "$p3/.shellkit-manifest"
out=$("$TEST_ROOT/shellkit" upgrade "$p3" 2>&1)
assert_contains "$out" "modified locally, left alone" "a broken baseline must be treated as user-modified"
assert_contains "$(cat "$p3/README.md")" "版本 0.10.0" "a broken baseline must not cause an overwrite"

exit 0
