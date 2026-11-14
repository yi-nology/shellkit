#!/usr/bin/env bash
# 统一安全删除接口 _sk_fs_safe_remove_owned（issue #81）的回归。
#
# 要守的是两条删除底线：
#   1. 用户改过的文件绝不能被静默删掉 —— 上游删除也要先对内容基线，
#      对不上就保留并告警（与写入路径同一契约）；只有 --force / 卸载的
#      清理语义才跳过比对；
#   2. 父目录里有一级是符号链接就绝不动手 —— rm 会顺着链接删到安装目录
#      之外（评审轮独立实验里这条丢过数据）。
# 三个删除入口都要过这两关：vendor 同步的上游删除循环、uninstall-self、
# skill uninstall。全部走真实 CLI 端到端验证。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

SK="$TEST_ROOT/shellkit"

sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# manifest_add FILE REL SHA —— 往所有权清单里追加一条「我们装过」的条目。
# 这是在模拟「上游发过、后来又删掉的文件」：清单里点名，而当前 ship list
# 里没有 —— 同步路径的删除循环正是靠这个差异识别「上游删除」的。
# 清单是命令替换落盘的（fs_atomic_write 原样写入），末尾没有换行 ——
# 追加前先补一条，别把两行粘成一行。
manifest_add() {
  if [ -n "$(tail -c 1 "$1" 2>/dev/null)" ]; then
    printf '\n' >>"$1"
  fi
  printf '%s\t%s\n' "$2" "$3" >>"$1"
}

work=$(tmpdir)

# ---------- CASE: vendor 同步 —— 上游删除 + 用户改过 ⇒ 保留并告警 ----------
#
# 旧实现无条件 rm -f：用户的修改静默丢失（无告警、退出码 0）。
proj="$work/app"
"$SK" new "$proj" >/dev/null 2>&1 || _fail "shellkit new failed"
ownf="$proj/vendor/shellkit/.shellkit-vendor-manifest"
[ -f "$ownf" ] || _fail "the vendor copy has no ownership manifest"

# docs/ 不在 vendor 的 ship list 里 —— 写进清单就是「上游曾经发过它」
mkdir -p "$proj/vendor/shellkit/docs"
printf 'original\n' >"$proj/vendor/shellkit/docs/notes.md"
manifest_add "$ownf" "docs/notes.md" "$(sha_of "$proj/vendor/shellkit/docs/notes.md")"
printf 'user edit\n' >>"$proj/vendor/shellkit/docs/notes.md"

out=$("$SK" vendor "$proj" 2>&1) && rc=0 || rc=$?
assert_eq "0" "$rc" "the sync must succeed while keeping a user-modified upstream-deleted file"
assert_contains "$out" "modified locally, left alone" "the kept file must be reported"
assert_contains "$out" "docs/notes.md" "the verdict must name the kept file"
assert_contains "$(cat "$proj/vendor/shellkit/docs/notes.md")" "user edit" \
  "the user modification must survive the sync"

# ---------- CASE: vendor 同步 —— 上游删除 + 内容还是原文 ⇒ 删掉 ----------
# 同一条判据的正面：内容对得上基线才动手 —— 该删的照删，同步仍是幂等的。
mkdir -p "$proj/vendor/shellkit/docs"
printf 'release notes\n' >"$proj/vendor/shellkit/docs/gone.md"
manifest_add "$ownf" "docs/gone.md" "$(sha_of "$proj/vendor/shellkit/docs/gone.md")"
out=$("$SK" vendor "$proj" 2>&1) && rc=0 || rc=$?
assert_eq "0" "$rc" "an untouched upstream-deleted file must be removable"
assert_not_contains "$out" "docs/gone.md" "the removal must stay silent for unmodified files"
if [ -e "$proj/vendor/shellkit/docs/gone.md" ]; then
  _fail "an upstream-deleted file whose content still matches the baseline must be removed"
fi

# ---------- CASE: vendor 同步 —— 父目录是符号链接 ⇒ 拒绝，根外文件活着 ----------
#
# lib/link 指向安装目录之外：rm -f lib/link/xx.md 会顺着链接把外面的文件删掉。
# 基线对得上（唯一可疑点就是父目录边界）—— 旧实现在这个场景直接删穿。
outside="$work/outside"
mkdir -p "$outside"
printf 'outside content\n' >"$outside/xx.md"
ln -s "$outside" "$proj/vendor/shellkit/lib/link"
manifest_add "$ownf" "lib/link/xx.md" "$(sha_of "$outside/xx.md")"

out=$("$SK" vendor "$proj" 2>&1) && rc=0 || rc=$?
assert_eq "0" "$rc" "refusing an unsafe removal must not fail the sync"
assert_contains "$out" "refusing to remove through a symlink" "the boundary refusal must be reported"
assert_eq "outside content" "$(cat "$outside/xx.md")" \
  "the file outside the install root must survive the sync"

# ---------- CASE: vendor 同步 --force —— 清理语义才允许跳过内容比对 ----------
# --force 的上游删除仍要过父目录边界（安全阀不随 force 放开），
# 但内容比对放开：用户改过也删 —— 用户明确说了要覆盖。
out=$("$SK" vendor "$proj" --force 2>&1) && rc=0 || rc=$?
assert_eq "0" "$rc" "--force must succeed"
assert_eq "outside content" "$(cat "$outside/xx.md")" \
  "the parent-directory boundary must hold even under --force"

# ---------- CASE: uninstall-self —— 父目录是符号链接 ⇒ 根外文件活着 ----------
#
# 装好之后把 lib/core 换成指向外部的软链：MANIFEST 里列着的 lib/core/*.sh
# 一律不许顺着软链删出去。
pfx="$work/pfx"
"$SK" install-self --prefix "$pfx" >/dev/null 2>&1 || _fail "install-self failed"
dest="$pfx/share/shellkit"
outside2="$work/outside-core"
mkdir -p "$outside2"
cp "$dest/lib/core/fs.sh" "$outside2/fs.sh"
rm -rf "$dest/lib/core"
ln -s "$outside2" "$dest/lib/core"

out=$("$SK" uninstall-self --prefix "$pfx" 2>&1) && rc=0 || rc=$?
assert_ne "0" "$rc" "a blocked removal must be reported as leftover (non-zero exit)"
assert_contains "$(cat "$outside2/fs.sh")" "$(head -c 20 "$TEST_ROOT/lib/core/fs.sh" | head -1)" \
  "the file outside the install prefix must survive uninstall-self"
if [ ! -e "$outside2/fs.sh" ]; then
  _fail "uninstall-self deleted through a symlinked parent directory"
fi

# ---------- CASE: skill uninstall —— 父目录是符号链接 ⇒ 根外文件活着 ----------
clidir="$work/client"
"$SK" skill install --dir "$clidir" >/dev/null 2>&1 || _fail "skill install failed"
skdst="$clidir/shellkit"
outside3="$work/outside-refs"
mkdir -p "$outside3"
cp "$skdst/references/reference.md" "$outside3/reference.md"
rm -rf "$skdst/references"
ln -s "$outside3" "$skdst/references"

out=$("$SK" skill uninstall --dir "$clidir" 2>&1) && rc=0 || rc=$?
assert_eq "0" "$rc" "skill uninstall must finish even when a file is kept"
assert_contains "$out" "refusing to remove through a symlink" "the boundary refusal must be reported"
assert_eq "$(sha_of "$TEST_ROOT/skills/shellkit/references/reference.md")" "$(sha_of "$outside3/reference.md")" \
  "the file outside the skill directory must survive skill uninstall"

exit 0
