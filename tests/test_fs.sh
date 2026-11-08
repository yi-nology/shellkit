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
