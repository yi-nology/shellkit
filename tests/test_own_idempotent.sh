#!/usr/bin/env bash
# 安装与同步的所有权清单（issue #69）：
#   vendor 副本与 install-self 副本里，用户改过的文件默认保留并告警，
#   不静默覆盖；--force 才覆盖；重复安装幂等（不产生无谓写入）。
#
# 判据不能只看「文件还在」—— 那样把旧实现（无条件覆盖）造回去也能过。
# 每条都断三件事：文件内容、告警文案、以及「没被重写」（inode 不变）。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

work=$(tmpdir)

# assert_exists FILE MSG —— 文件在就在，不在就带着说明失败
#
# assert_true 只能接命令、不能接说明（多一个词就多一个参数），所以自己写一个。
assert_exists() {
  local __f=${1:-} __msg=${2:-file is missing}
  if [ ! -f "$__f" ]; then
    _fail "$__msg: <$__f>"
  fi
  return 0
}

# assert_exists FILE MSG —— 文件在就在，不在就带着说明失败
#
# assert_true 只能接命令、不能接说明（多一个词就多一个参数），所以自己写一个。
assert_exists() {
  local __f=${1:-} __msg=${2:-file is missing}
  if [ ! -f "$__f" ]; then
    _fail "$__msg: <$__f>"
  fi
  return 0
}

# inode_of FILE —— 文件的 inode 号
#
# 「重复安装不产生无谓写入」这条判据只能看 inode：内容一样但文件被重写过，
# inode 就变了 —— 而这正是老实现每次都做的事（整份副本重铺一遍）。
inode_of() {
  local __f=${1:-} __i=""
  [ -f "$__f" ] || return 1
  __i=$(stat -f '%i' "$__f" 2>/dev/null) || __i=""
  if [ -z "$__i" ]; then
    __i=$(stat -c '%i' "$__f" 2>/dev/null) || __i=""
  fi
  [ -n "$__i" ] || return 1
  printf '%s' "$__i"
}

# ---------- vendor ----------

proj="$work/proj"
mkdir -p "$proj"
out=$(bash "$TEST_ROOT/shellkit" vendor "$proj" 2>&1) && rc=0 || rc=$?
assert_eq 0 "$rc" "the first vendor run succeeds"

vlog="$proj/vendor/shellkit/lib/core/log.sh"
assert_exists "$vlog" "the vendored copy has the library files"
assert_exists "$proj/vendor/shellkit/.shellkit-vendor-manifest" "the vendor copy records an ownership manifest"

# CASE: 重复同步是幂等的 —— 文件不被重写（inode 不变）
before=$(inode_of "$vlog")
out=$(bash "$TEST_ROOT/shellkit" vendor "$proj" 2>&1) && rc=0 || rc=$?
assert_eq 0 "$rc" "a repeated vendor run succeeds"
after=$(inode_of "$vlog")
assert_eq "$before" "$after" "a repeated vendor run must not rewrite files that are already correct"

# CASE: 用户改过的文件默认保留并告警，不静默覆盖
printf '# local tweak\n' >>"$vlog"
out=$(bash "$TEST_ROOT/shellkit" vendor "$proj" 2>&1) && rc=0 || rc=$?
assert_eq 0 "$rc" "a vendor run with a locally modified file still succeeds"
assert_contains "$out" "modified locally, left alone" "the modified file is reported"
assert_contains "$out" "lib/core/log.sh" "the modified file is named"
assert_contains "$(cat "$vlog")" "# local tweak" "the local modification survives the sync"

# CASE: 改过的文件再次同步仍然保留（基线没有推进）
out=$(bash "$TEST_ROOT/shellkit" vendor "$proj" 2>&1) && rc=0 || rc=$?
assert_contains "$out" "modified locally, left alone" "the modified file is still reported on the next run"
assert_contains "$(cat "$vlog")" "# local tweak" "the local modification is not overwritten later either"

# CASE: --force 显式覆盖
out=$(bash "$TEST_ROOT/shellkit" vendor "$proj" --force 2>&1) && rc=0 || rc=$?
assert_eq 0 "$rc" "vendor --force succeeds"
assert_not_contains "$out" "modified locally, left alone" "vendor --force overwrites instead of keeping"
assert_not_contains "$(cat "$vlog")" "# local tweak" "vendor --force really overwrites the local change"

# CASE: 用户自己加的文件不被删掉
printf 'mine\n' >"$proj/vendor/shellkit/my-own.sh"
bash "$TEST_ROOT/shellkit" vendor "$proj" >/dev/null 2>&1 || _fail "the vendor run failed"
assert_exists "$proj/vendor/shellkit/my-own.sh" "a file the user added is not deleted by the sync"

# CASE: 用户删掉的文件会被补回来 —— 「删掉」不等于「用户改过」
# （与 skill 安装路径同一口径：目标不在 ⇒ 写。少了这条，副本会缺文件，
#   而清单还记着它的基线，下次升级就会一直判成「用户改过」。)
rm -f "$vlog"
bash "$TEST_ROOT/shellkit" vendor "$proj" >/dev/null 2>&1 || _fail "the vendor run failed"
assert_exists "$vlog" "a file the user deleted is restored by the sync"

# CASE: 源目录里没有 NOTICE / LICENSE 也要装得上（回归）
#
# 清单函数原来以「最后一个 [ -f ... ] 的状态」收尾，而 shellkit 顶部是
# set -euo pipefail —— 发布包里没有 NOTICE 时，整条管道被判失败，
# install-self 当场退出（连着 shellkit update 一起挂）。
#
# 这里用真拷贝（不用软链）：ship-list 用 find 扫目录，find 默认不跟随软链，
# 软链出来的目录会被扫成空。
src="$work/src"
mkdir -p "$src"
cp -R "$TEST_ROOT/lib" "$TEST_ROOT/templates" "$TEST_ROOT/locale" \
  "$TEST_ROOT/skills" "$TEST_ROOT/tools" "$TEST_ROOT/docs" "$TEST_ROOT/tests" \
  "$TEST_ROOT/shellkit" "$TEST_ROOT/AGENTS.md" "$src/" || _fail "cannot stage the source tree"
printf '9.9.9\n' >"$src/VERSION"
pfx_nolice="$work/pfx-nolice"
out=$(bash "$src/shellkit" install-self --prefix "$pfx_nolice" 2>&1) && rc=0 || rc=$?
assert_eq 0 "$rc" "install-self must work from a source tree without NOTICE"
assert_exists "$pfx_nolice/share/shellkit/lib/bootstrap.sh" "the copy is installed anyway"

# ---------- install-self ----------

pfx="$work/pfx"
out=$(bash "$TEST_ROOT/shellkit" install-self --prefix "$pfx" 2>&1) && rc=0 || rc=$?
assert_eq 0 "$rc" "the first install-self run succeeds"

ilog="$pfx/share/shellkit/lib/core/log.sh"
assert_exists "$ilog" "the installed copy has the library files"
assert_exists "$pfx/share/shellkit/.shellkit-install-manifest" "the installed copy records an ownership manifest"

# CASE: 重复安装幂等 —— 文件不被重写
before=$(inode_of "$ilog")
out=$(bash "$TEST_ROOT/shellkit" install-self --prefix "$pfx" 2>&1) && rc=0 || rc=$?
assert_eq 0 "$rc" "a repeated install-self run succeeds"
after=$(inode_of "$ilog")
assert_eq "$before" "$after" "a repeated install-self run must not rewrite files that are already correct"

# CASE: 用户改过的文件默认保留并告警
printf '# local tweak\n' >>"$ilog"
out=$(bash "$TEST_ROOT/shellkit" install-self --prefix "$pfx" 2>&1) && rc=0 || rc=$?
assert_eq 0 "$rc" "an install-self run with a locally modified file still succeeds"
assert_contains "$out" "modified locally, left alone" "the modified file is reported"
assert_contains "$out" "lib/core/log.sh" "the modified file is named"
assert_contains "$(cat "$ilog")" "# local tweak" "the local modification survives the reinstall"

# CASE: --force 显式覆盖
out=$(bash "$TEST_ROOT/shellkit" install-self --prefix "$pfx" --force 2>&1) && rc=0 || rc=$?
assert_eq 0 "$rc" "install-self --force succeeds"
assert_not_contains "$out" "modified locally, left alone" "install-self --force overwrites instead of keeping"
assert_not_contains "$(cat "$ilog")" "# local tweak" "install-self --force really overwrites the local change"

# CASE: 用户自己加的文件不被删掉
printf 'mine\n' >"$pfx/share/shellkit/my-own.sh"
bash "$TEST_ROOT/shellkit" install-self --prefix "$pfx" >/dev/null 2>&1 || _fail "the install-self run failed"
assert_exists "$pfx/share/shellkit/my-own.sh" "a file the user added is not deleted by the reinstall"
