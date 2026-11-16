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

exit 0
