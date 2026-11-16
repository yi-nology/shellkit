#!/usr/bin/env bash
# 安装生命周期的端到端用例（issue #128）：install → modify → uninstall →
# reinstall → update，每一步都断言用户内容与所有权状态。
#
# 现有所有权用例的链路是 install → modify → reinstall → uninstall ——
# 唯一没覆盖的就是「卸载之后」。三条已确认缺口（#123 基线随卸载被删、
# #124 旧清单全删、#125 二次 purge / 失败保留清单）都长在这段盲区里。
#
# 判据形态：把 _sk_own_sync 的「有删除风险」分支改回无条件覆盖，这份用例
# 必须在 reinstall 一步变红。
#
# TEST_TIMEOUT: 900 —— 真实安装/重装/更新各跑一遍（与 test_install.sh 同量级）。
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

work=$(tmpdir)

# mk_release VERSION OUT —— 造一个能装的最小发布包（内容与当前树一致）
mk_release() {
  local __ver=$1 __out=$2 __stage
  __stage=$work/stage-$__ver
  mkdir -p "$__stage/shellkit-$__ver"
  cp -R "$TEST_ROOT/lib" "$TEST_ROOT/templates" "$TEST_ROOT/locale" \
    "$TEST_ROOT/skills" "$TEST_ROOT/tools" "$TEST_ROOT/docs" "$TEST_ROOT/tests" \
    "$TEST_ROOT/shellkit" "$TEST_ROOT/AGENTS.md" "$TEST_ROOT/LICENSE" "$TEST_ROOT/NOTICE" \
    "$__stage/shellkit-$__ver/" ||
    _fail "cannot stage the release tree"
  # 与 release.yml 一致：设计文档不随发布包走
  rm -rf "$__stage/shellkit-$__ver/docs/superpowers"
  printf '%s\n' "$__ver" >"$__stage/shellkit-$__ver/VERSION"
  tar -C "$__stage" -czf "$__out" "shellkit-$__ver" || _fail "cannot build the tarball"
}

fake=$work/fake-9.9.9.tar.gz
mk_release 9.9.9 "$fake"

prefix=$work/prefix
dest=$prefix/share/shellkit

# ---------- CASE: install → modify ----------
assert_exit_code 0 "$SK" install-self --prefix "$prefix"
upstream_sum=$(sum "$dest/lib/core/log.sh") # 我们装的原文
license_sum=$(sum "$dest/LICENSE")
printf '\n# user edit across uninstall\n' >>"$dest/lib/core/log.sh"
edit_sum=$(sum "$dest/lib/core/log.sh")
printf 'MINE\n' >"$dest/my-own.sh"
mine_sum=$(sum "$dest/my-own.sh")
assert_ne "$upstream_sum" "$edit_sum" "the fixture edit must change the hash"

# ---------- CASE: uninstall ----------
unlog="$work/uninstall.log"
rc=0
"$SK" uninstall-self --prefix "$prefix" >"$unlog" 2>&1 || rc=$?
assert_eq "0" "$rc" "uninstall must succeed while keeping the user's file"
assert_eq "$edit_sum" "$(sum "$dest/lib/core/log.sh")" \
  "the user edit must survive the uninstall"
assert_eq "$mine_sum" "$(sum "$dest/my-own.sh")" \
  "the user-added file must survive the uninstall"
assert_false test -f "$dest/LICENSE"
assert_contains "$(cat "$unlog")" "kept files that are not ours" \
  "the uninstall must report what it kept"
# #123 的根因：基线随卸载一起消失 ⇒ 重装分不清原文与用户修改
if [ ! -f "$dest/.shellkit-install-manifest" ]; then
  _fail "the ownership baseline must survive the uninstall"
fi

# ---------- CASE: reinstall（卸载之后重装，不许静默覆盖） ----------
relog="$work/reinstall.log"
rc=0
"$SK" install-self --prefix "$prefix" >"$relog" 2>&1 || rc=$?
assert_eq "0" "$rc" "the reinstall after uninstall must succeed"
assert_eq "$edit_sum" "$(sum "$dest/lib/core/log.sh")" \
  "the reinstall must keep the user edit instead of silently overwriting it"
assert_eq "$mine_sum" "$(sum "$dest/my-own.sh")" \
  "the reinstall must keep the user-added file"
assert_eq "$license_sum" "$(sum "$dest/LICENSE")" \
  "an untouched upstream file must be restored to the upstream content"
assert_contains "$(cat "$relog")" "modified locally, left alone" \
  "the reinstall must classify the kept file as locally modified"
assert_not_contains "$(cat "$dest/.shellkit-install-manifest")" "my-own.sh" \
  "user-added files must not enter the ownership baseline"
assert_contains "$(cat "$dest/.shellkit-install-manifest")" "lib/core/log.sh" \
  "the kept file must keep an ownership baseline"

# ---------- CASE: update（真实升级路径） ----------
updlog="$work/update.log"
rc=0
"$SK" update --from "$fake" --prefix "$prefix" >"$updlog" 2>&1 || rc=$?
assert_eq "0" "$rc" "update must succeed"
assert_eq "9.9.9" "$(cat "$dest/VERSION")" "update must install the new version"
assert_eq "$edit_sum" "$(sum "$dest/lib/core/log.sh")" \
  "update must keep the user edit — the baseline must not have been lost on uninstall"
assert_eq "$mine_sum" "$(sum "$dest/my-own.sh")" \
  "update must keep the user-added file"
assert_eq "$license_sum" "$(sum "$dest/LICENSE")" \
  "update must keep untouched upstream files at the upstream content"
assert_contains "$(cat "$updlog")" "modified locally, left alone" \
  "update must classify the kept file as locally modified"

# ---------- CASE: 反例 —— 同链路带 --force 必须覆盖 ----------
flog="$work/update-force.log"
rc=0
"$SK" update --force --from "$fake" --prefix "$prefix" >"$flog" 2>&1 || rc=$?
assert_eq "0" "$rc" "forced update must succeed"
assert_eq "$(sum "$TEST_ROOT/lib/core/log.sh")" "$(sum "$dest/lib/core/log.sh")" \
  "an explicit --force must overwrite the user edit kept through the lifecycle"
assert_eq "$mine_sum" "$(sum "$dest/my-own.sh")" \
  "--force must not delete the user's own file"
assert_not_contains "$(cat "$dest/lib/core/log.sh")" "user edit across uninstall" \
  "the forced update must replace the edited content"

exit 0
