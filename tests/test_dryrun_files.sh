#!/usr/bin/env bash
#
# 「只演练不落盘」模式（SHELLKIT_DRY_RUN_FILES=1）的用例。
#
# 覆盖：
#   1) 开关关着时，一切照常（默认行为一个字节都不变 —— 兼容承诺）
#   2) 开关打开时，fs / conf 的写原语只打印计划、不落盘、返回 0
#      （write / copy / backup / ensure_line / ensure_block / ensure_symlink /
#        mkdir / conf_set / conf_unset / conf_disable 一个都不许落盘）
#   2b) 干跑不吞「用法错」：参数非法仍然返回 2
#   3) 干跑打印走 stderr（stdout 只给数据）
#   4) 既有 SHELLKIT_DRY_RUN 的语义不变（它只管 run / svc）
#
# 断言纪律：断完整文案不断单词；临时目录名只用编号；SHELLKIT_LANG=en 由
# test_helper.sh 统一设置。

set -u

TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"
# shellcheck source=tests/test_helper.sh
. "$TEST_ROOT/tests/test_helper.sh"

. "$TEST_ROOT/lib/bootstrap.sh"

WORK=""
_cleanup() {
  [ -n "$WORK" ] && rm -rf "$WORK"
}
trap '_cleanup' EXIT

WORK=$(mktemp -d "${TMPDIR:-/tmp}/shellkit-dryrun-test.XXXXXX") || exit 1
cd "$WORK" || exit 1

# -------------------------------------------------------------------------
# CASE 1：开关关着 ⇒ 照常写（这是兼容承诺，不能被这次改动破坏）
# -------------------------------------------------------------------------
fs_atomic_write plain.txt "hello" 644 || _fail "fs_atomic_write must succeed when the dry-run switch is off"
assert_eq "hello" "$(cat plain.txt 2>/dev/null)" "fs_atomic_write must write the file when the switch is off"

conf_init plain-cfg >/dev/null || _fail "conf_init must succeed"
conf_set K V >/dev/null || _fail "conf_set must succeed when the dry-run switch is off"
assert_eq "V" "$(conf_get K 2>/dev/null)" "conf_set must write the config when the switch is off"

# -------------------------------------------------------------------------
# CASE 2：开关打开 ⇒ 只打印计划，不落盘，返回 0
# -------------------------------------------------------------------------
export SHELLKIT_DRY_RUN_FILES=1

out=$(fs_atomic_write dry.txt "hello" 644 2>&1)
assert_contains "$out" "[dry-run] write dry.txt" "the dry-run plan must name the write and the target"
assert_eq "" "$(cat dry.txt 2>/dev/null)" "the dry-run write must not create the file"

rc=0
fs_atomic_write dry.txt "hello" 644 >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "a dry-run write must not fail: skipping is not an error"
if [ -e dry.txt ]; then
  _fail "the dry-run write must not create the file"
fi

out=$(conf_set DRYKEY DRYVAL 2>&1)
assert_contains "$out" "[dry-run] conf-set DRYKEY" "the dry-run plan must name the config key"
rc=0
conf_set DRYKEY DRYVAL >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "a dry-run conf_set must not fail"

# 目录也不许建
out=$(fs_ensure_dir dry-dir 2>&1)
assert_contains "$out" "[dry-run] mkdir dry-dir" "the dry-run plan must name the directory"
if [ -d dry-dir ]; then
  _fail "the dry-run mkdir must not create the directory"
fi

# 备份 / 拷贝 / 软链 / 追加行：同样不许落盘
printf 'x
' >src.txt
rc=0
fs_atomic_copy src.txt dst.txt >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "a dry-run copy must not fail"
if [ -e dst.txt ]; then
  _fail "the dry-run copy must not create the destination"
fi

rc=0
fs_backup src.txt >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "a dry-run backup must not fail"
if ls src.txt.bak.* >/dev/null 2>&1; then
  _fail "the dry-run backup must not create a backup file"
fi

rc=0
fs_ensure_line line.txt "abc" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "a dry-run ensure_line must not fail"
if [ -e line.txt ]; then
  _fail "the dry-run ensure_line must not create the file"
fi

rc=0
fs_ensure_symlink src.txt link.txt >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "a dry-run symlink must not fail"
if [ -e link.txt ] || [ -L link.txt ]; then
  _fail "the dry-run symlink must not create the link"
fi

# 块标记：同样不许落盘
out=$(fs_ensure_block block.txt "BEGIN" "END" "body" 2>&1)
assert_contains "$out" "[dry-run] ensure-block block.txt" "the dry-run plan must name the block"
rc=0
fs_ensure_block block.txt "BEGIN" "END" "body" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "a dry-run ensure_block must not fail"
if [ -e block.txt ]; then
  _fail "the dry-run ensure_block must not create the file"
fi

# 取消键 / 禁用键：同样不许落盘
out=$(conf_unset DRYKEY 2>&1)
assert_contains "$out" "[dry-run] conf-unset DRYKEY" "the dry-run plan must name the unset key"
rc=0
conf_unset DRYKEY >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "a dry-run conf_unset must not fail"

out=$(conf_disable DRYKEY 2>&1)
assert_contains "$out" "[dry-run] conf-disable DRYKEY" "the dry-run plan must name the disabled key"
rc=0
conf_disable DRYKEY >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "a dry-run conf_disable must not fail"

# -------------------------------------------------------------------------
# CASE 2b：干跑不吞「用法错」
#
# 守卫放在参数校验之前 ⇒ 干跑时把「参数错」也变成成功（rc=0）。
# 那会让调用方以为「演练通过」，实际上一条命令都没跑对。
# 干跑只该短路「写盘」，不该短路「判对错」。
# -------------------------------------------------------------------------
rc=0
conf_set 'bad key!' v >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "a dry-run conf_set must still reject an invalid key"

rc=0
fs_ensure_symlink >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "a dry-run fs_ensure_symlink must still report a usage error"

# -------------------------------------------------------------------------
# CASE 3：干跑信息走 stderr，stdout 仍然只给数据
# -------------------------------------------------------------------------
stdout_only=$(fs_atomic_write quiet.txt "hello" 644 2>/dev/null)
assert_eq "" "$stdout_only" "the dry-run plan must not pollute stdout"

# -------------------------------------------------------------------------
# CASE 4：既有 SHELLKIT_DRY_RUN 的语义不变
#
# 它只管 run（跑命令）与 svc（服务写类动作）。开着它时 fs 仍然照写 ——
# 这是 1.0 之前的兼容承诺面，不能因为新开关而变。
# -------------------------------------------------------------------------
unset SHELLKIT_DRY_RUN_FILES
export SHELLKIT_DRY_RUN=1

fs_atomic_write legacy.txt "hello" 644 >/dev/null 2>&1 || true
if [ ! -e legacy.txt ]; then
  _fail "SHELLKIT_DRY_RUN must not change the file write behaviour: it only covers run and svc"
fi

# 两个开关叠加时，文件开关优先（更具体的那个说了算）
export SHELLKIT_DRY_RUN=1
export SHELLKIT_DRY_RUN_FILES=1
rc=0
fs_atomic_write both.txt "hello" 644 >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "the combined switches must not fail"
if [ -e both.txt ]; then
  _fail "the file dry-run switch must win over the command one"
fi

exit 0
