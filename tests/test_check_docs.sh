#!/usr/bin/env bash
#
# 门禁自测：check_docs.sh 必须在「文档里的示例坏了」时变红。
#
# 为什么需要自测：这道门守的是「文档里的示例代码还能不能跑、函数名还在不在」。
# 门禁自己要是静默失效（规则写空了、解析写错了），文档就会悄悄烂掉 ——
# 而文档烂掉是**没有人会报告**的那种坏：示例照抄，跑不通。
#
# 树是假的：只放门禁真正要看的东西（REFERENCE.md、allow 名单、POSIX 子集、
# 一份 markdown）。真仓库的判定由 check-docs 自己跑。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

GATE="$TEST_ROOT/tools/check_docs.sh"
FAKE="$TEST_TMP_ROOT/fake-docs-root"
DOC="$FAKE/docs/a.md"

mkdir -p "$FAKE/docs" "$FAKE/tools" "$FAKE/lib/posix"
cp "$GATE" "$FAKE/tools/check_docs.sh"

cat >"$FAKE/docs/REFERENCE.md" <<'EOF'
# reference

### `known_fn`

### `other_fn`
EOF

cat >"$FAKE/lib/posix/shellkit-posix.sh" <<'EOF'
posix_fn() { :; }
EOF

printf 'allowed_fn\n' >"$FAKE/tools/check_docs.allow"

run_gate() {
  (cd "$FAKE" && bash "$FAKE/tools/check_docs.sh" 2>&1)
}

write_doc() {
  printf '%s\n' "$1" >"$DOC"
}

# 好树：必须绿
write_doc '说明文字

```bash
known_fn
```
'
out=$(run_gate) || _fail "完好的文档应该通过门禁，实际输出：$out"

# 坏树 1：文档里用了不存在的函数名
write_doc '```bash
known_fn
mystery_fn
```
'
out=$(run_gate) && _fail "出现不存在的函数名时门禁必须红"
case "$out" in
  *mystery_fn*) ;;
  *) _fail "门禁没有指出是哪个名字坏了：$out" ;;
esac
case "$out" in
  *"not in docs/REFERENCE.md"*) ;;
  *) _fail "门禁没有说明这个名字从哪来：$out" ;;
esac

# 坏树 2：代码块语法自相矛盾
write_doc '```bash
if then fi
```
'
out=$(run_gate) && _fail "代码块语法错误时门禁必须红"
case "$out" in
  *"bash syntax error"*) ;;
  *) _fail "门禁没有说明是语法错误：$out" ;;
esac

# 好树：块里自己定义过的函数也算已知
write_doc '```bash
cmd_deploy() {
  known_fn
}
cmd_deploy
```
'
out=$(run_gate) || _fail "块内自定义的函数应该算已知，实际输出：$out"

# 好树：赋值、字符串、注释里的名字都不算调用
write_doc '```bash
mystery_fn=1
export mystery_fn
known_fn "mystery_fn"
# mystery_fn
```
'
out=$(run_gate) || _fail "赋值/字符串/注释里的名字不该算调用，实际输出：$out"

# 好树：白名单与 POSIX 子集里的函数也算已知
write_doc '```bash
allowed_fn
posix_fn
```
'
out=$(run_gate) || _fail "白名单与 POSIX 子集里的函数应该算已知，实际输出：$out"

# 好树：管道与 && 里的函数名也要查（这是最容易漏的一条）
write_doc '```bash
known_fn | mystery_fn
```
'
out=$(run_gate) && _fail "管道下游的未知函数名也必须被查出来"

# 修好之后必须重新变绿
write_doc '```bash
known_fn
```
'
out=$(run_gate) || _fail "修好之后应该重新通过门禁，实际输出：$out"
