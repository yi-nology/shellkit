#!/usr/bin/env bash
# 上游删除 + 用户改过 ⇒ 保留且**基线冻结**；上游加回同路径 ⇒ 用户编辑仍活着
# （issue #91，用例规格取自 PR #90 原 17 例里的 B1/B5）。
#
# 三步链：上游删 X → 用户改 X（保留）→ 上游重新加回 X。
# 旧实现的断点：删除循环 rc=1（拒绝删除=保留）不登记 _SK_OWN_NEW_*，
# 基线随旧清单作废 ⇒ 加回那轮决策循环 __base 为空、__act 停在 W ⇒
# 用户编辑被上游内容静默覆盖、新清单记上游指纹。
#
# 每步断三件事：文件内容（用户编辑存活）、告警（modified locally）、
# 清单基线（冻结在安装时的旧指纹——既不推进成用户内容，也不推进成上游新指纹）。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"

work=$(tmpdir)

# assert_exists FILE MSG —— 文件在就在，不在就带着说明失败
assert_exists() {
  local __f=${1:-} __msg=${2:-file is missing}
  if [ ! -f "$__f" ]; then
    _fail "$__msg: <$__f>"
  fi
  return 0
}

# mkminisrc DIR —— 最小源码树：真实 shellkit + lib + VERSION，
# 外加一个能自由增删的「上游文件」（lib/core/legacy_extra.sh）。
mkminisrc() {
  mkdir -p "$1"
  cp -f "$TEST_ROOT/shellkit" "$1/shellkit"
  cp -f "$TEST_ROOT/VERSION" "$1/VERSION"
  cp -R "$TEST_ROOT/lib" "$1/lib"
  printf '# legacy module (test fixture)\n' >"$1/lib/core/legacy_extra.sh"
}

src="$work/b1src"
mkminisrc "$src"
pfx="$work/b1pfx"
dest="$pfx/share/shellkit"
rel="lib/core/legacy_extra.sh"

# ---------- 第一步：首装 ----------
out=$(bash "$src/shellkit" install-self --prefix "$pfx" 2>&1) && rc=0 || rc=$?
assert_eq 0 "$rc" "B1: the first install must succeed"
assert_exists "$dest/$rel" "B1: the fixture file must be installed"
orig_sum=$(os_sha256 "$src/$rel")

# ---------- 第二步：用户改过 + 上游删除 ⇒ 保留、告警、基线不推进 ----------
printf '# user edit\n' >>"$dest/$rel"
user_sum=$(os_sha256 "$dest/$rel")
rm -f "$src/$rel" # 上游删除了这个文件
out=$(bash "$src/shellkit" install-self --prefix "$pfx" 2>&1) && rc=0 || rc=$?
assert_eq 0 "$rc" "B1: the second install must succeed"
assert_contains "$out" "modified locally" \
  "B1: the preserved file must be announced"
assert_exists "$dest/$rel" \
  "B1: a locally modified file must survive an upstream deletion"
assert_contains "$(cat "$dest/$rel")" "user edit" \
  "B1: the user's edit must be the content that survives"
man=$(cat "$dest/.shellkit-install-manifest")
assert_contains "$man" "$(printf '%s\t%s' "$rel" "$orig_sum")" \
  "B1: the manifest must keep the original baseline (frozen, not dropped)"
assert_not_contains "$man" "$user_sum" \
  "B1: the user's content must never be recorded as our baseline"

# ---------- 第三步：上游加回同路径 ⇒ 用户编辑活着、基线仍冻结 ----------
printf '# legacy module v2\n' >"$src/$rel"
out=$(bash "$src/shellkit" install-self --prefix "$pfx" 2>&1) && rc=0 || rc=$?
assert_eq 0 "$rc" "B5: re-adding the file must not fail the install"
assert_contains "$out" "modified locally" \
  "B5: the collision must be announced"
assert_contains "$(cat "$dest/$rel")" "user edit" \
  "B5: a re-added upstream file must not overwrite the user's edit"
assert_contains "$(cat "$dest/.shellkit-install-manifest")" \
  "$(printf '%s\t%s' "$rel" "$orig_sum")" \
  "B5: the baseline must stay frozen at the original install-time value"

printf 'test_own_sync_frozen: all cases passed\n'
