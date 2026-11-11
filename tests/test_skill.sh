#!/usr/bin/env bash
# shellkit skill 子命令与 skill 包的测试。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

SK="$TEST_ROOT/shellkit"
PACK="$TEST_ROOT/skills/shellkit"

# CASE: skill 包的结构
# 入口 + references/（渐进披露的细节）。少一个文件，AI 就会照着残缺的内容写代码。
assert_true test -f "$PACK/SKILL.md"
assert_true test -d "$PACK/references"
for f in reference.md cookbook.md bash32.md cli.md; do
  assert_true test -s "$PACK/references/$f"
done

# SKILL.md 里提到的 references 必须真的存在 —— 提到一个不存在的文件，
# AI 会去读、读不到、然后自己编一个出来。
missing=""
while IFS= read -r ref || [ -n "$ref" ]; do
  [ -n "$ref" ] || continue
  if [ ! -f "$PACK/$ref" ]; then
    missing="$missing $ref"
  fi
done <<EOF
$(grep -o 'references/[a-z0-9-]*\.md' "$PACK/SKILL.md" | sort -u)
EOF
assert_eq "" "$missing" "SKILL.md points at reference files that do not exist"

# CASE: 包与源码同源
# 包的每份文件都必须跟生成源一致：docs/ 的投影不能手改。
assert_exit_code 0 diff -r "$TEST_ROOT/docs/REFERENCE.md" "$PACK/references/reference.md"
assert_exit_code 0 diff -r "$TEST_ROOT/docs/COOKBOOK.md" "$PACK/references/cookbook.md"
assert_exit_code 0 diff -r "$TEST_ROOT/docs/BASH32.md" "$PACK/references/bash32.md"

# CASE: skill list
out=$("$SK" skill list 2>/dev/null)
rc=0
"$SK" skill list >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "skill list must succeed"
assert_contains "$out" "claude" "skill list should name the known clients"

# CASE: skill install --dir
d=$(mktemp -d "$TEST_TMP_ROOT/skill.XXXXXX") || _fail "mktemp failed"
rc=0
"$SK" skill install --dir "$d/1" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "skill install must succeed"
assert_true test -f "$d/1/shellkit/SKILL.md"
assert_true test -f "$d/1/shellkit/references/reference.md"
# 装进去的必须与源逐字节一致（fs_atomic_copy 是逐字节搬的）
for f in SKILL.md references/reference.md references/cookbook.md references/bash32.md references/cli.md; do
  assert_exit_code 0 diff "$PACK/$f" "$d/1/shellkit/$f"
done
# 版本号跟着装进去：list 才知道装的是哪一版
assert_true test -f "$d/1/shellkit/VERSION"
assert_eq "$(tr -d '[:space:]' <"$TEST_ROOT/VERSION")" "$(tr -d '[:space:]' <"$d/1/shellkit/VERSION")" "the installed skill must carry the current version"

# CASE: skill uninstall
rc=0
"$SK" skill uninstall --dir "$d/1" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "skill uninstall must succeed"
assert_false test -e "$d/1/shellkit/SKILL.md"
assert_false test -d "$d/1/shellkit"

# CASE: 目标已经是软链就放过它
# 跟着软链写会写到别处去（坑 8），而且退出码还是 0 —— 装的人根本不知道。
mkdir -p "$d/2" "$d/3" || _fail "mkdir failed"
ln -s "$d/3" "$d/2/shellkit" || _fail "ln failed"
rc=0
"$SK" skill install --dir "$d/2" >/dev/null 2>&1 || rc=$?
assert_eq "3" "$rc" "installing onto a symlink must fail with the precondition code"
assert_true test -L "$d/2/shellkit"
assert_false test -e "$d/3/SKILL.md"

# CASE: 未知客户端
rc=0
"$SK" skill install --client nosuchclient >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "an unknown client must be a usage error"

# CASE: 没有可用的客户端目录
rc=0
HOME="$d/nohome" "$SK" skill install >/dev/null 2>&1 || rc=$?
assert_eq "3" "$rc" "no client directory must be a precondition error"

# CASE: skill print 把入口打到 stdout
out=$("$SK" skill print 2>/dev/null)
assert_contains "$out" "name: shellkit" "skill print should print the entry file"

# ---------- 所有权清单（issue #39）与幂等安装（issue #45） ----------

# CASE: 安装后清单在，记录的就是装下去的那几个文件
d=$(mktemp -d "$TEST_TMP_ROOT/skill.XXXXXX") || _fail "mktemp failed"
rc=0
"$SK" skill install --dir "$d/10" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "install must succeed"
m="$d/10/shellkit/.shellkit-skill-manifest"
assert_true test -f "$m"
for f in SKILL.md VERSION references/reference.md references/cookbook.md references/bash32.md references/cli.md; do
  assert_contains "$(cat "$m")" "$f" "the manifest should record $f"
done

# CASE: 幂等 —— 同一版重装不动任何文件，输出说「已是最新的」
out=$("$SK" skill install --dir "$d/10" 2>&1)
rc=0
"$SK" skill install --dir "$d/10" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "a second install must succeed"
assert_contains "$out" "up to date" "a repeated install should report up to date"

# CASE: 用户改过的已安装文件，重装默认跳过并告警（不静默覆盖）
printf 'EDITED BY USER - MUST SURVIVE\n' >"$d/10/shellkit/SKILL.md"
out=$("$SK" skill install --dir "$d/10" 2>&1)
rc=0
"$SK" skill install --dir "$d/10" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "an install over a modified file must still succeed"
assert_contains "$out" "modified locally, left alone" "the install must warn about the modified file"
assert_eq "EDITED BY USER - MUST SURVIVE" "$(cat "$d/10/shellkit/SKILL.md")" "the user's edit must survive a reinstall"

# CASE: 显式 --force 才覆盖用户改动
"$SK" skill install --dir "$d/10" --force >/dev/null 2>&1
assert_true test -f "$d/10/shellkit/SKILL.md"
assert_not_contains "$(cat "$d/10/shellkit/SKILL.md")" "EDITED BY USER" "--force must overwrite the user's edit"

# CASE: 卸载不删用户自己加的文件（issue #39 的主场景）
d=$(mktemp -d "$TEST_TMP_ROOT/skill.XXXXXX") || _fail "mktemp failed"
"$SK" skill install --dir "$d/11" >/dev/null 2>&1
printf 'MY OWN NOTES\n' >"$d/11/shellkit/references/custom.md"
printf 'EDITED BY USER\n' >"$d/11/shellkit/SKILL.md"
out=$("$SK" skill uninstall --dir "$d/11" 2>&1)
rc=0
"$SK" skill uninstall --dir "$d/11" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "an uninstall with kept files must still exit 0"
assert_contains "$out" "modified locally, left alone" "the uninstall must say what it kept"
assert_eq "MY OWN NOTES" "$(cat "$d/11/shellkit/references/custom.md")" "a user-added file must survive the uninstall"
assert_eq "EDITED BY USER" "$(head -n 1 "$d/11/shellkit/SKILL.md")" "a user-modified file must survive the uninstall"
assert_false test -e "$d/11/shellkit/references/reference.md"

# ---------- 安装路径的软链边界（issue #40） ----------

# CASE: references 预置指向根之外的软链 —— 拒绝安装，一个字节都不落到外面
d=$(mktemp -d "$TEST_TMP_ROOT/skill.XXXXXX") || _fail "mktemp failed"
mkdir -p "$d/20/shellkit" "$d/outside" || _fail "mkdir failed"
ln -s "$d/outside" "$d/20/shellkit/references" || _fail "ln failed"
out=$("$SK" skill install --dir "$d/20" 2>&1)
rc=0
"$SK" skill install --dir "$d/20" >/dev/null 2>&1 || rc=$?
assert_eq "3" "$rc" "installing through a symlinked references must fail with the precondition code"
assert_contains "$out" "refusing to write through a symlink" "the refusal must say why"
assert_true test -L "$d/20/shellkit/references"
n_out=$(find "$d/outside" -type f | wc -l | tr -d ' ')
assert_eq "0" "$n_out" "nothing may be written outside the target root"

# CASE: references 预置指向根之内的软链 —— 同样拒绝（不可信一律拒绝）
mkdir -p "$d/21/shellkit" "$d/21/inner" || _fail "mkdir failed"
ln -s ../inner "$d/21/shellkit/references" || _fail "ln failed"
out=$("$SK" skill install --dir "$d/21" 2>&1)
rc=0
"$SK" skill install --dir "$d/21" >/dev/null 2>&1 || rc=$?
assert_eq "3" "$rc" "a symlink pointing inside the root must be refused too"
assert_contains "$out" "refusing to write through a symlink" "the refusal must say why"
n_in=$(find "$d/21/inner" -type f | wc -l | tr -d ' ')
assert_eq "0" "$n_in" "nothing may be written through the symlink"

# ---------- skill list 的状态判别（issue #52 的第一块） ----------

# CASE: list 能报「被改过」—— 清单指纹对不上就是 modified
d=$(mktemp -d "$TEST_TMP_ROOT/skill.XXXXXX") || _fail "mktemp failed"
mkdir -p "$d/home30/.claude/skills" || _fail "mkdir failed"
HOME="$d/home30" "$SK" skill install --client claude >/dev/null 2>&1
out=$(HOME="$d/home30" "$SK" skill list 2>/dev/null)
assert_contains "$out" "installed" "a fresh install must be reported as installed"
printf 'tampered\n' >>"$d/home30/.claude/skills/shellkit/SKILL.md"
out=$(HOME="$d/home30" "$SK" skill list 2>/dev/null)
assert_contains "$out" "modified" "a tampered install must be reported as modified"
