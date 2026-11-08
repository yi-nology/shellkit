#!/usr/bin/env bash
# 参数太少必须是用法错误（2），不能有两种劣化：
#   1. 被 set -u 打死成 1 —— 调用方用 `case "$rc" in 2) 骂用户 ;; *) 重试 ;; esac` 分流时，
#      1 与 2 的差别决定「是用户写错了」还是「环境暂时不行」（issue #25）。
#   2. 静默返回 0 —— `require_cmd "$EMPTY"` 于是变成空真，前置检查整段失效（issue #26）。
# 所以这里逐个公开函数按「零参数」打一遍。参数个数是接口的一部分。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"

d=$(tmpdir)

# ---- 前置检查：零参数不许是空真 ----
assert_exit_code 2 require_cmd
assert_exit_code 2 require_file
assert_exit_code 2 os_has_cmd

# ---- 字符串 ----
assert_exit_code 2 str_trim
assert_exit_code 2 str_lower
assert_exit_code 2 str_upper
assert_exit_code 2 str_repeat

# ---- 文件 ----
assert_exit_code 2 fs_ensure_dir
assert_exit_code 2 fs_atomic_write
assert_exit_code 2 fs_backup
assert_exit_code 2 fs_ensure_line
assert_exit_code 2 fs_ensure_block
assert_exit_code 2 fs_ensure_symlink

# ---- 网络：守卫必须在碰网络之前 ----
assert_exit_code 2 net_sha256
assert_exit_code 2 net_verify
assert_exit_code 2 net_download
assert_exit_code 2 net_wait_port
assert_exit_code 2 net_wait_http

# ---- 系统 ----
assert_exit_code 2 os_md5
assert_exit_code 2 os_sha256

# ---- 交互：守卫在 read 之前，否则零参数会卡在 stdin 上 ----
assert_exit_code 2 ask
assert_exit_code 2 ask_yn
assert_exit_code 2 ask_choice

# ---- CLI ----
assert_exit_code 2 cli_opt

# 少一个必需参数同样是 2，而不是「用空值也能跑完」
assert_exit_code 2 fs_ensure_block "$d/x"
assert_exit_code 2 fs_ensure_line
assert_exit_code 2 net_download http://example.invalid/x
assert_exit_code 2 ask_choice V

# set -u 下也必须是 2：这一条曾经是 1，因为 `local __x=$1` 先炸了
rc=0
bash -c 'set -u; . "$1/lib/bootstrap.sh"; fs_ensure_dir' _ "$TEST_ROOT" 2>/dev/null || rc=$?
assert_eq "2" "$rc" "a missing argument is a usage error even under set -u"

rc=0
bash -c 'set -u; . "$1/lib/bootstrap.sh"; require_cmd' _ "$TEST_ROOT" 2>/dev/null || rc=$?
assert_eq "2" "$rc" "require_cmd reports usage, not unbound variable"

# 错误信息必须说清怎么用，否则用户只知道「缺参数」
err=$(require_cmd 2>&1 >/dev/null)
assert_contains "$err" "require_cmd CMD" "the usage line names the signature"

printf 'argument tests passed\n'
