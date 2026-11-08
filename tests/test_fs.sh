#!/usr/bin/env bash
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"

d=$(tmpdir)

# 原子写 + 权限
f="$d/conf.txt"
fs_atomic_write "$f" "A=1
B=2"
assert_eq "A=1
B=2" "$(cat "$f")" "fs_atomic_write content"
assert_file_mode "$f" "600" "fs_atomic_write mode"

# 覆盖写
fs_atomic_write "$f" "A=9"
assert_eq "A=9" "$(cat "$f")" "overwrite"
assert_not_contains "$(cat "$f")" "B=2" "overwrite truncates"

# 备份与轮转
b="$d/rotate.txt"
printf 'v\n' >"$b"
fs_backup "$b" 2
sleep 1
printf 'v\n' >"$b"
fs_backup "$b" 2
sleep 1
printf 'v\n' >"$b"
fs_backup "$b" 2
count=$(ls -1 "$b".bak.* | wc -l | tr -d ' ')
assert_eq "2" "$count" "fs_backup keeps KEEP copies"

# 缺失文件不报错
assert_true fs_backup "$d/does-not-exist" 2

# 临时目录：fs_tmpdir 可在 $(...) 里安全调用，不会被立刻删掉
t=$(fs_tmpdir)
assert_true test -d "$t"
assert_eq "$t" "$(fs_tmpdir)" "fs_tmpdir is stable within a process"
fs_tmp_init
assert_eq "$t" "$SK_TMPDIR" "fs_tmp_init reuses the same directory"

# ensure_dir
fs_ensure_dir "$d/deep/nested" 700
assert_true test -d "$d/deep/nested"
assert_file_mode "$d/deep/nested" "700"

# ---------------------------------------------------------------------------
# 幂等三件
# ---------------------------------------------------------------------------

hosts="$d/hosts"
fs_ensure_line "$hosts" "1.2.3.4 a"
fs_ensure_line "$hosts" "1.2.3.4 a"
assert_eq "1" "$(grep -c '' "$hosts" | tr -d ' ')" "fs_ensure_line is idempotent"
fs_ensure_line "$hosts" "5.6.7.8 b"
assert_eq $'1.2.3.4 a\n5.6.7.8 b' "$(cat "$hosts")" "fs_ensure_line appends new lines"

# 子串不算已存在
fs_ensure_line "$hosts" "1.2.3.4"
assert_eq "3" "$(grep -c '' "$hosts" | tr -d ' ')" "fs_ensure_line matches whole lines"

# 原文件末尾没有换行时也不会把两行粘在一起
nonl="$d/nonl"
printf 'first' >"$nonl"
fs_ensure_line "$nonl" "second"
assert_eq $'first\nsecond' "$(cat "$nonl")" "fs_ensure_line fixes a missing trailing newline"

# 空行/多行参数
assert_exit_code 2 fs_ensure_line "$hosts" ""
assert_exit_code 2 fs_ensure_line "$hosts" "a
b"

# 标记块：先追加，再整体替换，重复调用不动
conf="$d/conf"
fs_ensure_block "$conf" "# BEGIN" "# END" "a=1"
assert_eq $'# BEGIN\na=1\n# END' "$(cat "$conf")" "fs_ensure_block appends a block"
fs_ensure_block "$conf" "# BEGIN" "# END" "a=2"
assert_eq $'# BEGIN\na=2\n# END' "$(cat "$conf")" "fs_ensure_block replaces the block"
fs_ensure_block "$conf" "# BEGIN" "# END" "a=2"
assert_eq $'# BEGIN\na=2\n# END' "$(cat "$conf")" "fs_ensure_block is idempotent"

# 块外内容保持不动
mixed="$d/mixed"
printf 'keep=1\n# BEGIN\nold\n# END\ntail=2\n' >"$mixed"
fs_ensure_block "$mixed" "# BEGIN" "# END" "new"
assert_eq $'keep=1\n# BEGIN\nnew\n# END\ntail=2' "$(cat "$mixed")" "fs_ensure_block touches only the block"

# 标记校验
assert_exit_code 2 fs_ensure_block "$conf" "" "# END" "x"
assert_exit_code 2 fs_ensure_block "$conf" "# A" "# A" "x"
assert_exit_code 2 fs_ensure_symlink "" "$d/l"

# 符号链接
fs_ensure_symlink /tmp "$d/link1"
assert_eq "/tmp" "$(readlink "$d/link1")" "fs_ensure_symlink creates the link"
fs_ensure_symlink /tmp "$d/link1"
assert_eq "/tmp" "$(readlink "$d/link1")" "fs_ensure_symlink is idempotent"
fs_ensure_symlink /var "$d/link1"
assert_eq "/var" "$(readlink "$d/link1")" "fs_ensure_symlink repoints the link"

# 绝不覆盖普通文件
plain="$d/plain"
printf 'data' >"$plain"
assert_exit_code 1 fs_ensure_symlink /tmp "$plain"
assert_eq "data" "$(cat "$plain")" "fs_ensure_symlink refuses to clobber a regular file"
