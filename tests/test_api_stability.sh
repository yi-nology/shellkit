#!/usr/bin/env bash
# 公开 API 分级的判据（issue #79）。
#
# 四条：
#   1. 当前树上门禁是绿的（注解 / 基线分级列 / 豁免名单三者一致）
#   2. 新公开函数既没写 @stability、又不在豁免名单 ⇒ 红（棘轮：新函数第一天就要声明）
#   3. 豁免名单里的函数已经写了 @stability ⇒ 红（必须移出名单，双向棘轮，坑 15）
#   4. 基线里的分级与源码注解对不上 ⇒ 红（重生成基线）
# 外加：shdoc 把 @stability 渲染成「稳定性」小节。
#
# 副本是「门禁需要的最小树」（lib/ + MIGRATING + VERSION，门禁文件从工作树拷），
# **不依赖 git** —— compat 容器里没有 git、或 git 不认这个 checkout 的属主，
# 依赖它就会红在「建不出副本」上（CI run 43374301252 的教训）；
# 门禁文件从工作树拷，本用例在未提交的改动上也能自证。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

REPO="$TEST_ROOT"

# _copy_repo DST —— 门禁需要的最小副本（**不依赖 git**）
#
# 为什么不用 git archive：compat 容器里要么没有 git，要么 git 不认这个 checkout
# 的属主（dubious ownership）—— 两种都会让 archive 走空，用例就红在「建不出
# 副本」上（CI run 43374301252 就是这么红的）。门禁实际只读这几处：
# lib/（扫描 + 探针加载）、docs/MIGRATING.md、VERSION，加上 tools/ 下的门禁文件
# （从工作树拷，让用例在未提交的改动上也能自证）。
_copy_repo() {
  local dst=$1
  mkdir -p "$dst" || return 1
  cp -R "$REPO/lib" "$dst/" || return 1
  mkdir -p "$dst/docs" || return 1
  cp "$REPO/docs/MIGRATING.md" "$dst/docs/" || return 1
  cp "$REPO/VERSION" "$dst/" || return 1
  mkdir -p "$dst/tools" || return 1
  cp "$REPO/tools/api_baseline.sh" "$REPO/tools/api_baseline.txt" \
    "$REPO/tools/stability_exempt.txt" "$dst/tools/" || return 1
  return 0
}

GATE_OUT=""
GATE_RC=0
_gate() {
  local dir=$1
  GATE_RC=0
  GATE_OUT=$(bash "$dir/tools/api_baseline.sh" --root "$dir" 2>&1) || GATE_RC=$?
  return 0
}

# CASE 1: 当前树上门禁是绿的 —— 正控制，后面几条才作数
d=$(tmpdir)
_copy_repo "$d" || _fail "cannot create the repo copy"
_gate "$d"
if [ "$GATE_RC" -ne 0 ]; then
  printf '%s\n' "$GATE_OUT" >&2
  _fail "the gate must be green on the current tree"
fi

# CASE 2: 新函数没声明 @stability，也不在豁免名单 ⇒ 红
d=$(tmpdir)
_copy_repo "$d" || _fail "cannot create the repo copy"
printf '# 临时探针函数\nzz_probe_fn() {\n  return 0\n}\n' >"$d/lib/core/zzprobe.sh"
# 同时把它塞进基线，避免被判据里的「新函数没进基线」抢先报错 —— 我们要看的是分级这条
printf 'zz_probe_fn\t0\tactive\t-\tskip\t-\t-\texperimental\n' >>"$d/tools/api_baseline.txt"
_gate "$d"
assert_ne "0" "$GATE_RC" "an unannotated new function must fail the gate"
assert_contains "$GATE_OUT" "没有声明 @stability" "the gate must name the missing annotation"
assert_contains "$GATE_OUT" "zz_probe_fn" "the gate must name the function"

# CASE 3: 豁免名单里的函数已经写了 @stability ⇒ 红（必须移出名单）
d=$(tmpdir)
_copy_repo "$d" || _fail "cannot create the repo copy"
# 挑一个在豁免名单里的函数，给它加上注解（插在定义行之前）
__fn=$(grep -v '^#' "$d/tools/stability_exempt.txt" | sed -n '1p')
[ -n "$__fn" ] || _fail "the exempt list must not be empty"
# 逐文件处理：把注解插到该函数定义行之前（扫描器只认紧邻的注释块）
for __f in "$d/lib/core/"*.sh; do
  awk -v fn="$__fn" '
    $0 ~ "^" fn "\\(\\)" && !done { print "# @stability stable"; done = 1 }
    { print }
  ' "$__f" >"$__f.tmp" && mv "$__f.tmp" "$__f"
done
_gate "$d"
assert_ne "0" "$GATE_RC" "an annotated function still listed as exempt must fail the gate"
assert_contains "$GATE_OUT" "必须移出名单" "the gate must demand removing it from the exempt list"
assert_contains "$GATE_OUT" "$__fn" "the gate must name the function"

# CASE 4: 基线里的分级被改 ⇒ 红
d=$(tmpdir)
_copy_repo "$d" || _fail "cannot create the repo copy"
__fn=$(grep -v '^#' "$d/tools/api_baseline.txt" | grep -v '^baseline-version:' | sed -n '1p' | cut -f1)
[ -n "$__fn" ] || _fail "the baseline must contain at least one entry"
awk -F'\t' -v OFS='\t' -v fn="$__fn" '
  $1 == fn && $8 == "experimental" { $8 = "stable" }
  { print }
' "$d/tools/api_baseline.txt" >"$d/tools/api_baseline.tmp" && mv "$d/tools/api_baseline.tmp" "$d/tools/api_baseline.txt"
_gate "$d"
assert_ne "0" "$GATE_RC" "a tampered stability column must fail the gate"
assert_contains "$GATE_OUT" "分级与源码注解对不上" "the gate must say the column disagrees"

# CASE 5: shdoc 把 @stability 渲染成「稳定性」小节
demo="$d/demo.sh"
cat >"$demo" <<'EOF'
# 演示函数
# @stability stable
# @exitcode 0 永远成功
demo_fn() {
  return 0
}
EOF
assert_contains "$(awk -f "$REPO/tools/shdoc.awk" "$demo" 2>/dev/null)" "**稳定性**：stable" \
  "shdoc must render the stability tag"
