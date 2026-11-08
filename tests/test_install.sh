#!/usr/bin/env bash
# 安装 / 卸载 / 更新：全部走真实二进制，不用替身。
# 网络一律不碰 —— 远端路径用 file:// 假 release 喂给 curl，跑的是同一条代码路径。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

work=$(tmpdir)
sk=$TEST_ROOT/shellkit
prefix=$work/prefix
dest=$prefix/share/shellkit

_sha() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# mk_release VERSION OUT —— 造一个能装的最小发布包
mk_release() {
  local __ver=$1 __out=$2 __stage
  __stage=$work/stage-$__ver
  mkdir -p "$__stage/shellkit-$__ver"
  cp -R "$TEST_ROOT/lib" "$TEST_ROOT/templates" "$TEST_ROOT/locale" \
    "$TEST_ROOT/skills" "$TEST_ROOT/shellkit" "$__stage/shellkit-$__ver/" ||
    _fail "cannot stage the release tree"
  printf '%s\n' "$__ver" >"$__stage/shellkit-$__ver/VERSION"
  tar -C "$__stage" -czf "$__out" "shellkit-$__ver" || _fail "cannot build the tarball"
}

fake=$work/fake-9.9.9.tar.gz
mk_release 9.9.9 "$fake"

# ---------- install-self ----------

assert_exit_code 0 "$sk" install-self --prefix "$prefix"
assert_true test -f "$dest/MANIFEST"
assert_true test ! -e "$dest/lib/lib"
assert_eq "$(cat "$TEST_ROOT/VERSION")" "$("$dest/shellkit" --version)" "installed copy runs"
assert_eq "$(cat "$TEST_ROOT/VERSION")" "$("$prefix/bin/shellkit" --version)" "symlink resolves its own root"

# 二次安装必须幂等：cp -R 到已存在的目录会嵌套成 lib/lib
lines=$(grep -vc '^#' "$dest/MANIFEST")
assert_exit_code 0 "$sk" install-self --prefix "$prefix"
assert_true test ! -e "$dest/lib/lib"
assert_eq "$lines" "$(grep -vc '^#' "$dest/MANIFEST")" "manifest is stable across reinstalls"

# ---------- update ----------

assert_exit_code 0 "$sk" update --check --from "$fake" --prefix "$prefix"
assert_eq "9.9.9" "$("$sk" update --check --from "$fake" --prefix "$prefix" 2>/dev/null)" \
  "--check prints the target version on stdout"

assert_exit_code 0 "$sk" update --from "$fake" --prefix "$prefix"
assert_eq "9.9.9" "$(cat "$dest/VERSION")" "VERSION is bumped"
assert_eq "9.9.9" "$("$prefix/bin/shellkit" --version)" "updated binary runs"

assert_contains "$("$sk" update --from "$fake" --prefix "$prefix" 2>&1)" "up to date" \
  "same version is a no-op"
assert_exit_code 0 "$sk" update --force --from "$fake" --prefix "$prefix"
assert_exit_code 5 "$sk" update --from "$fake" --sha256 00 --prefix "$prefix"
assert_exit_code 3 "$sk" update --from "$work/absent.tar.gz" --prefix "$prefix"
assert_exit_code 3 "$sk" update --from "$fake" --prefix "$work/empty"
assert_exit_code 2 "$sk" update --bogus
# ---------- uninstall-self ----------

# 没有清单的目录不许动：宁可报错，也不猜着删
mkdir -p "$work/nomani/share/shellkit"
printf 'keep\n' >"$work/nomani/share/shellkit/keep.txt"
assert_exit_code 3 "$sk" uninstall-self --prefix "$work/nomani"
assert_true test -f "$work/nomani/share/shellkit/keep.txt"

assert_exit_code 0 "$sk" uninstall-self --prefix "$prefix"
assert_false test -e "$dest"
assert_false test -e "$prefix/bin/shellkit"
assert_exit_code 3 "$sk" uninstall-self --prefix "$prefix"

# 清单是文件，不是可信输入：../ 不许把删除动作带出安装目录
esc=$work/esc
mkdir -p "$esc/share/shellkit" "$esc/outside"
printf 'victim\n' >"$esc/outside/victim"
printf '# shellkit test\n../outside/victim\n' >"$esc/share/shellkit/MANIFEST"
err=$("$sk" uninstall-self --prefix "$esc" 2>&1)
rc=$?
assert_eq "0" "$rc" "a skipped path is not a failure"
assert_contains "$err" "skipped a path"
assert_true test -f "$esc/outside/victim"

# 软链指向别处时不许删：那不是我们装的
mkdir -p "$work/other/share/shellkit" "$work/other/bin"
printf '# shellkit test\n' >"$work/other/share/shellkit/MANIFEST"
printf '#!/bin/sh\n' >"$work/other/target"
ln -s "$work/other/target" "$work/other/bin/shellkit"
err=$("$sk" uninstall-self --prefix "$work/other" 2>&1)
rc=$?
assert_eq "0" "$rc"
assert_contains "$err" "points elsewhere"
assert_true test -e "$work/other/bin/shellkit"

# ---------- install.sh ----------

installer=$TEST_ROOT/install.sh

assert_exit_code 0 "$installer" --prefix "$work/fromtree"
assert_eq "$(cat "$TEST_ROOT/VERSION")" "$("$work/fromtree/bin/shellkit" --version)" \
  "install.sh installs the working tree when run from a checkout"

# 远端路径：file:// 假 release，跑的是真实的 下载 → 校验 → 解包 → install-self
rel=$work/rel
mkdir -p "$rel/v9.9.9"
cp "$fake" "$rel/v9.9.9/shellkit-9.9.9.tar.gz"
printf '%s  %s\n' "$(_sha "$rel/v9.9.9/shellkit-9.9.9.tar.gz")" "shellkit-9.9.9.tar.gz" \
  >"$rel/v9.9.9/SHA256SUMS"
printf '{"tag_name":"v9.9.9"}\n' >"$rel/release.json"

assert_exit_code 0 env \
  SHELLKIT_RELEASE_API="file://$rel/release.json" \
  SHELLKIT_RELEASE_BASE="file://$rel" \
  "$installer" --remote --prefix "$work/remote"
assert_eq "9.9.9" "$("$work/remote/bin/shellkit" --version)" "remote install lands on the release version"

assert_eq "9.9.9" \
  "$(SHELLKIT_RELEASE_API="file://$rel/release.json" "$installer" --check --prefix "$work/remote" 2>/dev/null)" \
  "--check prints the latest version on stdout"

# 校验不过的包一个字节都不许落地
bad=$work/bad
mkdir -p "$bad/v9.9.9"
cp "$fake" "$bad/v9.9.9/shellkit-9.9.9.tar.gz"
printf '0000  %s\n' "shellkit-9.9.9.tar.gz" >"$bad/v9.9.9/SHA256SUMS"
assert_exit_code 5 env SHELLKIT_RELEASE_BASE="file://$bad" \
  "$installer" --version 9.9.9 --prefix "$work/badprefix"
assert_false test -e "$work/badprefix/share/shellkit/shellkit"

assert_exit_code 0 "$installer" --uninstall --prefix "$work/remote"
assert_false test -e "$work/remote/share/shellkit"
assert_exit_code 3 "$installer" --uninstall --prefix "$work/absent"
assert_exit_code 2 "$installer" --bogus

printf 'install tests passed\n'
