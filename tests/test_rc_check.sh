#!/usr/bin/env bash
# RC 验证脚本（tools/rc_check.sh）的回归。
#
# 要守的四件事：
#   1. 两个形状不同的工程都能跑完「升级 → 幂等 → 安装/卸载/重装 → 再升级」；
#   2. 传入的工程**一个字节都不许改**（脚本必须先复制再动手）；
#   3. 不是 shellkit 工程的目录 ⇒ 判失败并点名原因；
#   4. --help 可用。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

SK="$TEST_ROOT/shellkit"
RC="$TEST_ROOT/tools/rc_check.sh"

sum() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

d=$(tmpdir)
p1="$d/p1"
p2="$d/p2"
"$SK" new "$p1" --name p1 --cmd run --cmd status --yes >/dev/null 2>&1 || _fail "cannot create p1"
"$SK" new "$p2" --name p2 --cmd run --set GREETING=hello --yes >/dev/null 2>&1 || _fail "cannot create p2"

# 用户自己的文件：顶层 + 子目录（清单里没有，升级必须原样保留）
printf 'my notes\n' >"$p1/notes.txt"
mkdir -p "$p1/docs"
printf '# design\n' >"$p1/docs/design.md"
mkdir -p "$p2/local"
printf 'k=v\n' >"$p2/local/extra.conf"

before1=$(sum "$p1/notes.txt")
before2=$(sum "$p1/docs/design.md")
before3=$(sum "$p2/local/extra.conf")
manifest1=$(sum "$p1/.shellkit-manifest")

rc=0
out=$(bash "$RC" "$p1" "$p2" 2>&1) || rc=$?
assert_eq "0" "$rc" "rc_check must pass on two freshly generated projects"
assert_contains "$out" "ok: upgrade" "the run must report success per project"
assert_contains "$out" "ran=2 fails=0" "the summary must count both projects"

# 2) 传入的工程必须一个字节都没变（脚本只改副本）
assert_eq "$before1" "$(sum "$p1/notes.txt")" "a user file in the input project must not change"
assert_eq "$before2" "$(sum "$p1/docs/design.md")" "a nested user file must not change"
assert_eq "$before3" "$(sum "$p2/local/extra.conf")" "p2 user file must not change"
assert_eq "$manifest1" "$(sum "$p1/.shellkit-manifest")" "the input manifest must not change"

# 3) 不是 shellkit 工程的目录 ⇒ 失败并点名
empty="$d/not-a-project"
mkdir -p "$empty"
rc=0
out=$(bash "$RC" "$empty" 2>&1) || rc=$?
assert_eq "1" "$rc" "a directory without a manifest must fail"
assert_contains "$out" "no .shellkit-manifest" "the failure must say why"

# 4) 参数缺失与 --help
rc=0
bash "$RC" --help >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "--help must exit 0"
rc=0
bash "$RC" >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "no arguments must be a usage error"

exit 0
