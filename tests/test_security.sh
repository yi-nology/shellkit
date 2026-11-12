#!/usr/bin/env bash
#
# 安全边界门禁自测 + 规范文档自测。
#
# 两件事：
#
#   1. 门禁必须绿（当前 HEAD），而且每条判据都能被「注入违规」打出红灯 ——
#      门禁自己崩了、或者规则写空了，输出就会是「一切正常」，
#      而那恰恰是最需要它响的时候。
#   2. 规范文档（docs/SECURITY.md）必须有四类边界各成一节、代码块能过 bash -n、
#      并且与 AGENTS.md 的坑清单互相引用。
#
# 改坏文件一律用 awk 改写，不用 sed -i：BSD 的 sed -i '' 与 GNU 的 sed -i 参数不同，
# 本机（macOS）过了、CI（Ubuntu）会炸 —— 这条测试本身就在这个坑上栽过一次。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

GATE="$TEST_ROOT/tools/check_security.sh"
DOC="$TEST_ROOT/docs/SECURITY.md"
FAKE="$TEST_TMP_ROOT/fake-root"

# ---------------------------------------------------------------- 工具
# build_fake —— 造一棵假的树：门禁只看 lib/core、shellkit 与 VERSION，够用了。
# 每次注入前重建，不留上一次的状态。
build_fake() {
  # 用 find -delete 而不是 rm -rf：有些机器上的 rm 是回收站包装器，一次要 1–9 秒
  [ -d "$FAKE" ] && find "$FAKE" -depth -delete
  mkdir -p "$FAKE/lib/core"
  cp "$TEST_ROOT"/lib/core/*.sh "$FAKE/lib/core/"
  cp "$TEST_ROOT/lib/bootstrap.sh" "$TEST_ROOT/lib/modules.txt" "$FAKE/lib/"
  cp "$TEST_ROOT/VERSION" "$FAKE/"
  cp "$TEST_ROOT/shellkit" "$FAKE/"
  return 0
}

# run_gate CHECK_ID —— 只跑一条判据，把输出收进来
run_gate() {
  bash "$GATE" --root "$FAKE" --only "$1" 2>&1
}

# _rewrite FILE AWK_PROG —— 用 awk 改写文件（保留原权限）
_rewrite() {
  local __f=$1 __prog=$2 __tmp
  __tmp="$__f.tmp.$$"
  awk "$__prog" "$__f" >"$__tmp" || return 1
  cat "$__tmp" >"$__f"
  rm -f "$__tmp"
  return 0
}

# _expect_red ID —— 门禁必须因为这条判据而红
_expect_red() {
  local __id=$1 __out
  __out=$(run_gate "$__id")
  if [ $? -eq 0 ]; then
    _fail "$__id: 注入了违规之后门禁必须红，实际输出：$__out"
  fi
  case "$__out" in
    *"$__id"*) ;;
    *) _fail "$__id: 门禁红了但没指出是哪条判据：$__out" ;;
  esac
}

# ---------------------------------------------------------------- CASE: 当前 HEAD 是绿的
out=$(bash "$GATE" 2>&1) || _fail "当前 HEAD 应该通过安全门禁，实际输出：$out"
case "$out" in
  *"check_security: ok"*) ;;
  *) _fail "门禁没有输出通过标记：$out" ;;
esac

# 用法错必须返回 2（不是 1，也不是 0）
bash "$GATE" --only no_such_check >/dev/null 2>&1
if [ $? -ne 2 ]; then
  _fail "用法错时门禁必须返回 2"
fi

# 假树与 HEAD 一样，必须绿
build_fake
out=$(run_gate path.write) || _fail "完好的树应该通过门禁，实际输出：$out"

# ---------------------------------------------------------------- CASE: path.write
# 注入：加一个写文件却没有边界守卫的函数
build_fake
printf '\n_bad_writer() {\n  fs_atomic_write "$1" "$2" || return 1\n}\n' >>"$FAKE/lib/core/fs.sh"
_expect_red path.write

# ---------------------------------------------------------------- CASE: path.symlink
# 注入：让 _sk_fs_no_symlink_below 放过软链目录
build_fake
_rewrite "$FAKE/lib/core/fs.sh" '
  /if \[ -L "\$__dir" \]; then/ { flag = 1; print; next }
  flag && /return 1/ { print "      return 0"; flag = 0; next }
  { print }
' || _fail "改写 fs.sh 失败"
_expect_red path.symlink

# ---------------------------------------------------------------- CASE: path.name
# 注入：让 _sk_valid_name 什么都放行
build_fake
_rewrite "$FAKE/shellkit" '
  /^_sk_valid_name\(\)/ { inf = 1 }
  inf && /return 1 ;;/ { print "    *) return 0 ;;"; inf = 0; next }
  { print }
' || _fail "改写 shellkit 失败"
_expect_red path.name

# ---------------------------------------------------------------- CASE: perm.mode
# 注入：新建文件默认权限从 600 改成 644
build_fake
_rewrite "$FAKE/lib/core/fs.sh" '{ gsub(/:-600\}/, ":-644}"); print }' || _fail "改写 fs.sh 失败"
_expect_red perm.mode

# ---------------------------------------------------------------- CASE: secret.redact
# 注入：把敏感变量直接递给 run，没有声明脱敏
build_fake
printf 'run mysql -u root "$DB_PASSWORD"\n' >>"$FAKE/lib/core/fs.sh"
_expect_red secret.redact

# ---------------------------------------------------------------- CASE: secret.tracked
# 注入：把凭据文件塞进版本库
build_fake
(
  cd "$FAKE" || exit 1
  git init -q . || exit 1
  printf 'SECRET=1\n' >.env
  git add .env
) || _fail "造凭据文件失败"
_expect_red secret.tracked

# ---------------------------------------------------------------- CASE: exec.lock
# 注入：去掉锁的宽限逻辑（pid 文件缺失就永久不可用）
build_fake
_rewrite "$FAKE/lib/core/lock.sh" '{ gsub(/SHELLKIT_LOCK_STALE/, "SHELLKIT_LOCK_GRACE"); print }' ||
  _fail "改写 lock.sh 失败"
_expect_red exec.lock

# ---------------------------------------------------------------- CASE: exec.trap
# 注入：注册了清理动作却不装 trap
build_fake
_rewrite "$FAKE/lib/core/fs.sh" '{ if ($0 ~ /^  trap_install$/) { print "  :" } else { print } }' ||
  _fail "改写 fs.sh 失败"
_expect_red exec.trap

# ---------------------------------------------------------------- CASE: exec.atomic
# 注入：把 rename 换成 cp -f —— 会写穿软链，也会留下半截文件
build_fake
_rewrite "$FAKE/lib/core/fs.sh" '{ gsub(/mv -f "\$__tmp" "\$__dst"/, "cp -f \"\$__tmp\" \"\$__dst\""); print }' ||
  _fail "改写 fs.sh 失败"
_expect_red exec.atomic

# ---------------------------------------------------------------- CASE: exec.concurrent
# 注入：并发实例不再各写各的文件
build_fake
_rewrite "$FAKE/lib/core/run.sh" '{ if (index($0, "__i}.out") > 0) gsub(/>"[^"]*" 2>"[^"]*"/, ">/dev/null"); print }' ||
  _fail "改写 run.sh 失败"
_expect_red exec.concurrent

# ---------------------------------------------------------------- CASE: 规范文档结构
[ -f "$DOC" ] || _fail "docs/SECURITY.md 不存在"

sections=$(grep '^## ' "$DOC" || true)
[ -n "$sections" ] || _fail "docs/SECURITY.md 里一个二级标题都没有"

# 四类边界各成一节：按标题判定，不做脆弱的全文匹配
for __h in 路径边界 权限边界 敏感参数 执行隔离; do
  printf '%s\n' "$sections" | grep -qE "^## .*$__h" ||
    _fail "docs/SECURITY.md 里没有「${__h}」这一节"
done

# 与 AGENTS.md 坑清单的互相引用段必须存在
printf '%s\n' "$sections" | grep -q 'AGENTS.md' ||
  _fail "docs/SECURITY.md 没有与 AGENTS.md「十六个坑」的互相引用段"
grep -q 'AGENTS.md' "$DOC" || _fail "docs/SECURITY.md 没有提到 AGENTS.md"
grep -q '坑' "$DOC" || _fail "docs/SECURITY.md 没有提到坑清单"

# ---------------------------------------------------------------- CASE: 规范文档里的代码块
BLKS="$TEST_TMP_ROOT/sec-blocks"
[ -d "$BLKS" ] && find "$BLKS" -depth -delete
mkdir -p "$BLKS"
awk -v dir="$BLKS" '
  /^```bash[ \t]*$/ { inb = 1; n++; f = dir "/blk." n ".sh"; next }
  /^```[ \t]*$/ { inb = 0; next }
  inb { print > f }
' "$DOC"
nblk=$(ls "$BLKS" | wc -l | tr -d ' ')
[ "$nblk" -ge 8 ] || _fail "docs/SECURITY.md 的 bash 代码块只有 $nblk 个，提取可能失效"
for __b in "$BLKS"/*.sh; do
  bash -n "$__b" || _fail "docs/SECURITY.md 里的 bash 代码块语法不合法：$__b"
done

# ---------------------------------------------------------------- CASE: 文档与门禁对得上
ids=$(bash "$GATE" --list | awk '$1 ~ /^[a-z][a-z0-9]*\.[a-z][a-z0-9]*$/ { print $1 }')
nids=$(printf '%s\n' "$ids" | wc -l | tr -d ' ')
[ "$nids" -ge 6 ] || _fail "门禁只列出了 $nids 条判据，少于应有的下限"
for __id in $ids; do
  grep -q "$__id" "$DOC" || _fail "docs/SECURITY.md 里没有提到判据 $__id"
done

# 每类边界至少要有一条机器判据
for __sec in 路径边界 权限边界 敏感参数 执行隔离; do
  __body=$(awk -v h="$__sec" '
    /^## / { inh = (index($0, h) > 0); next }
    inh { print }
  ' "$DOC")
  printf '%s\n' "$__body" | grep -qE '`(path|perm|secret|exec)\.[a-z]+`' ||
    _fail "docs/SECURITY.md 的「${__sec}」这一节没有列出任何机器判据"
done
