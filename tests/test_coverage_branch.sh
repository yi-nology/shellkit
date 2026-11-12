#!/usr/bin/env bash
# 分支覆盖工具（tools/coverage.sh --branch）的自证测试。
#
# 每条判据都带负对照（造坏 ⇒ 必须变红；不变红 ⇒ 这条用例没有判据能力）：
#   1) 机制与四层口径：迷你树跑 --branch，报告必须有 enumerated / hit /
#      skipped / whitelist 四个数、paths 四行路径数字、skipped 与 whitelist
#      明细；已覆盖的臂绝不进白名单。
#   2) 棘轮规则一：未覆盖臂不在基线 ⇒ 红并点名。
#   3) 棘轮规则二：已覆盖臂留在基线 ⇒ 红并点名（覆盖回退不许被白名单掩盖）。
#   4) 棘轮规则三：基线里是已不存在的臂 ⇒ 红并点名（名单腐烂）。
#   5) 正对照：基线 = 当前未覆盖集合 ⇒ 绿。
#   6) 守卫机制：命中臂守卫绿；未覆盖臂的守卫即使基线齐全也红；子串匹配不上也红。
#   7) 真库快跑（test_str 套件）：报告格式、四条路径数字、--out 与 stdout
#      一致；第二遍用 /bin/bash 起工具（macOS 上即 3.2 解析执行）+ 正对照基线。
#
# 断言纪律：断完整文案不断单词；临时目录名只用编号；SHELLKIT_LANG=en 由
# test_helper.sh 统一设置。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

TOOL="$TEST_ROOT/tools/coverage.sh"
COV_TIMEOUT=240

# _cov_run OUTVAR ARGS... —— 跑覆盖率工具，退出码写进 OUTVAR，
# stdout 进 $COV_STDOUT、stderr 进 $COV_STDERR。
_cov_run() {
  local __outvar=$1
  shift
  local __rc=0
  _cov_out="$TEST_TMP_ROOT/cov.stdout"
  _cov_err="$TEST_TMP_ROOT/cov.stderr"
  if command -v timeout >/dev/null 2>&1; then
    timeout "$COV_TIMEOUT" bash "$TOOL" "$@" >"$_cov_out" 2>"$_cov_err" </dev/null || __rc=$?
  else
    bash "$TOOL" "$@" >"$_cov_out" 2>"$_cov_err" </dev/null || __rc=$?
  fi
  printf -v "$__outvar" '%s' "$__rc"
  COV_STDOUT="$_cov_out"
  COV_STDERR="$_cov_err"
  return 0
}

# _cov_run_bash OUTVAR INTERP ARGS... —— 指定解释器跑工具（/bin/bash = 3.2 基线）
_cov_run_bash() {
  local __outvar=$1 __interp=$2
  shift 2
  local __rc=0
  _cov_out="$TEST_TMP_ROOT/cov.stdout"
  _cov_err="$TEST_TMP_ROOT/cov.stderr"
  if command -v timeout >/dev/null 2>&1; then
    timeout "$COV_TIMEOUT" "$__interp" "$TOOL" "$@" >"$_cov_out" 2>"$_cov_err" </dev/null || __rc=$?
  else
    "$__interp" "$TOOL" "$@" >"$_cov_out" 2>"$_cov_err" </dev/null || __rc=$?
  fi
  printf -v "$__outvar" '%s' "$__rc"
  COV_STDOUT="$_cov_out"
  COV_STDERR="$_cov_err"
  return 0
}

# _cov_tree DIR —— 造迷你树：if 双臂、case 双臂、|| 守卫臂各一类。
_cov_tree() {
  local dir=$1
  mkdir -p "$dir/lib/core" "$dir/tests" || return 1

  cat >"$dir/lib/core/i18n.sh" <<'I18N'
#!/usr/bin/env bash
# 假 i18n：__cov_hit 的注入落点（modules.txt 的第一个模块）。
I18N

  cat >"$dir/lib/core/mini.sh" <<'MINI'
#!/usr/bin/env bash
# 迷你库：if 双臂、case 双臂、|| 守卫臂各一。
mini_alpha() {
  if [ -n "${1:-}" ]; then
    printf 'a\n'
  else
    printf 'b\n'
  fi
}

mini_beta() {
  case "${1:-}" in
    ok) printf 'ok\n' ;;
    *) printf 'no\n' ;;
  esac
}

mini_guard() {
  [ -n "${1:-}" ] || return 1
  return 0
}
MINI

  cat >"$dir/tests/run.sh" <<'SUITE'
#!/usr/bin/env bash
# 迷你套件：只走 mini_alpha 的 then 臂与 mini_guard 的守卫臂。
# mini_beta 两条 case 臂、mini_alpha 的 else 臂一次都碰不到。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/core/i18n.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/core/mini.sh"
mini_alpha x >/dev/null
if mini_guard ok; then :; fi
if ! mini_guard ""; then :; fi
SUITE
  return 0
}

# _cov_whitelist OUT FILE —— 从报告里抽 whitelist 段（跳过段头，逐条写 FILE）
_cov_whitelist() {
  awk '/^whitelist /{f=1; next} /^excluded:/{f=0} f && /^  /{sub(/^  /,""); print}' "$1" >"$2"
  return 0
}

# -------------------------------------------------------------------------
# CASE 1：机制 + 四层口径（空基线 ⇒ 规则一红，报告必须四层齐全）
# -------------------------------------------------------------------------
d=$(tmpdir) || _fail "cannot create tmpdir"
_cov_tree "$d" || _fail "cannot build the mini tree"
base="$d/base"

rc=0
_cov_run rc --branch --root "$d" --suite 'bash tests/run.sh' --guards '' --baseline "$base"
assert_ne "0" "$rc" "an empty baseline must violate the ratchet (rule 1)"
err=$(cat "$COV_STDERR")
assert_contains "$err" "branch not in the baseline: lib/core/mini.sh:mini_alpha:2" \
  "the ratchet must name the uncovered else arm"

out=$(cat "$COV_STDOUT")
hl=$(printf '%s\n' "$out" | awk '/^branch coverage:/{print; exit}')
assert_contains "$hl" "enumerated " "the headline must state the enumerated count"
assert_contains "$hl" "hit " "the headline must state the hit count"
assert_contains "$hl" "skipped " "the headline must state the skipped count"
assert_contains "$hl" "whitelist " "the headline must state the whitelist count"

n=$(printf '%s\n' "$hl" | sed -n 's/.*enumerated \([0-9][0-9]*\).*/\1/p')
w=$(printf '%s\n' "$hl" | sed -n 's/.*whitelist \([0-9][0-9]*\).*/\1/p')
case "$n" in '' | *[!0-9]*) _fail "enumerated is not a number: <$n>" ;; esac
case "$w" in '' | *[!0-9]*) _fail "whitelist is not a number: <$w>" ;; esac
if [ "$n" -lt 4 ]; then
  _fail "the mini tree must enumerate at least 4 arms, got $n"
fi
assert_eq "3" "$w" "exactly the three unhit mini arms belong to the whitelist"

assert_contains "$out" "paths:" "the report must carry the path section"
for __p in Upgrade Install Skill Repair; do
  assert_contains "$out" "  $__p: " "the path section must list $__p"
done
assert_contains "$out" "whitelist 3:" "the whitelist section must be listed"
assert_contains "$out" "lib/core/mini.sh:mini_beta:1" "the uncovered case arm must be named"
assert_not_contains "$out" "lib/core/mini.sh:mini_alpha:1" \
  "the covered then arm must never be listed as uncovered"

# -------------------------------------------------------------------------
# CASE 2：正对照 —— 基线 = 当前未覆盖集合 ⇒ 绿
# -------------------------------------------------------------------------
_cov_whitelist "$COV_STDOUT" "$base"
[ -s "$base" ] || _fail "the parsed whitelist must not be empty"

rc=0
_cov_run rc --branch --root "$d" --suite 'bash tests/run.sh' --guards '' --baseline "$base"
assert_eq "0" "$rc" "the ratchet must pass once the baseline lists exactly the uncovered arms"

# -------------------------------------------------------------------------
# CASE 3：规则二 —— 已覆盖臂留在基线 ⇒ 红（防覆盖回退被掩盖）
# -------------------------------------------------------------------------
printf '%s\n' "lib/core/mini.sh:mini_alpha:1" >>"$base"
rc=0
_cov_run rc --branch --root "$d" --suite 'bash tests/run.sh' --guards '' --baseline "$base"
assert_ne "0" "$rc" "a covered arm left in the baseline must fail the ratchet (rule 2)"
err=$(cat "$COV_STDERR")
assert_contains "$err" "the baseline lists a covered branch: lib/core/mini.sh:mini_alpha:1" \
  "rule 2 must name the stale entry"

# 还原
grep -vx 'lib/core/mini.sh:mini_alpha:1' "$base" >"$base.clean" || true
mv "$base.clean" "$base"

# -------------------------------------------------------------------------
# CASE 4：规则三 —— 基线里是已不存在的臂 ⇒ 红（名单腐烂）
# -------------------------------------------------------------------------
printf '%s\n' "lib/core/mini.sh:mini_ghost:1" >>"$base"
rc=0
_cov_run rc --branch --root "$d" --suite 'bash tests/run.sh' --guards '' --baseline "$base"
assert_ne "0" "$rc" "a baseline entry that no longer exists must fail the ratchet (rule 3)"
err=$(cat "$COV_STDERR")
assert_contains "$err" "the baseline lists a branch that no longer exists: lib/core/mini.sh:mini_ghost:1" \
  "rule 3 must name the dead entry"
grep -vx 'lib/core/mini.sh:mini_ghost:1' "$base" >"$base.clean" || true
mv "$base.clean" "$base"

# -------------------------------------------------------------------------
# CASE 5：守卫 —— 未覆盖臂的守卫即使基线齐全也红（白名单救不了）
# -------------------------------------------------------------------------
guards="$d/guards"
# 子串同时匹配 then 臂（已覆盖）与 else 臂（未覆盖）⇒ else 未命中必须红
printf '%s\n' 'G1|lib/core/mini.sh|mini_alpha|[ -n "${1:-}" ]' >"$guards"
rc=0
_cov_run rc --branch --root "$d" --suite 'bash tests/run.sh' --guards "$guards" --baseline "$base"
assert_ne "0" "$rc" "a guard arm that is not hit must fail even with a complete baseline"
err=$(cat "$COV_STDERR")
assert_contains "$err" "guard branch not hit: [G1] lib/core/mini.sh:mini_alpha:2" \
  "the guard violation must name the missed arm"

# -------------------------------------------------------------------------
# CASE 6：守卫 —— 只指向命中臂 ⇒ 绿
# -------------------------------------------------------------------------
printf '%s\n' 'G2|lib/core/mini.sh|mini_guard|return 1' >"$guards"
rc=0
_cov_run rc --branch --root "$d" --suite 'bash tests/run.sh' --guards "$guards" --baseline "$base"
assert_eq "0" "$rc" "a guard over a hit arm must pass"

# -------------------------------------------------------------------------
# CASE 7：守卫 —— 子串在全宇宙里匹配不上 ⇒ 红并点名
# -------------------------------------------------------------------------
printf '%s\n' 'G3|lib/core/mini.sh|mini_alpha|no-such-substring' >"$guards"
rc=0
_cov_run rc --branch --root "$d" --suite 'bash tests/run.sh' --guards "$guards" --baseline "$base"
assert_ne "0" "$rc" "a guard that matches no branch must fail"
err=$(cat "$COV_STDERR")
assert_contains "$err" "guard has no matching branch: [G3] lib/core/mini.sh:mini_alpha" \
  "the unmatched guard must be named"

# -------------------------------------------------------------------------
# CASE 8：真库快跑 —— 报告格式 + 四条路径数字 + --out 一致；
# 第二遍用 /bin/bash 起工具（macOS 上就是 3.2 在解析执行），基线齐全 ⇒ 绿
# -------------------------------------------------------------------------
rb="$TEST_TMP_ROOT/rb.base"
rout="$TEST_TMP_ROOT/rb.report"

rc=0
_cov_run rc --branch --suite 'bash tests/test_str.sh' --guards '' --baseline "$rb" --out "$rout"
assert_eq "1" "$rc" "on the real tree an empty baseline must violate the ratchet"
out=$(cat "$COV_STDOUT")
assert_contains "$out" "branch coverage: enumerated " "the real report must carry the headline"
for __p in Upgrade Install Skill Repair; do
  assert_contains "$out" "  $__p: " "the real report must list the $__p path"
done
assert_contains "$out" "guards:" "the real report must carry the guards section"
assert_contains "$out" "(disabled)" "guards must be reported as disabled when --guards is empty"
assert_contains "$out" "skipped " "the real report must list skipped sites"
[ -f "$rout" ] || _fail "--out was not written"
assert_eq "$out" "$(cat "$rout")" "the --out file must carry the same report as stdout"

_cov_whitelist "$COV_STDOUT" "$rb"
[ -s "$rb" ] || _fail "the real-tree whitelist must not be empty"

rc=0
_cov_run_bash rc /bin/bash --branch --suite 'bash tests/test_str.sh' --guards '' --baseline "$rb"
assert_eq "0" "$rc" "the tool must pass under /bin/bash with a complete baseline"

exit 0
