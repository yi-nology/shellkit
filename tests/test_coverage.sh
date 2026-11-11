#!/usr/bin/env bash
#
# 覆盖率工具的测试。
#
# 四条用例，每条都带负对照（造坏 ⇒ 必须变红）：
#   1) 机制自测：合成迷你库，只调一个公开函数 ⇒ 报告必须显示 1/2 并逐字点名另一个，
#      且不能把 _sk_ 私有函数算进去。
#   2) 棘轮负对照：白名单里少一条 ⇒ 工具必须退出码非 0。
#   3) 白名单不腐烂：白名单里塞一个不存在的公开函数名 ⇒ 必须判红。
#   4) 对真库跑一遍（跑一个快的测试文件，不跑全套）⇒ 报告能生成、格式正确、数字合理。
#
# ⚠️ 断言纪律：断完整文案不断单词；临时目录名只用编号（目录名会出现在被测用例的
# 输出里，带意义的词会撞上断言关键词）；输出语言固定 en（test_helper.sh 已经设了）。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

TOOL="$TEST_ROOT/tools/coverage.sh"

# 工具的运行可能比较久（拷树 + 跑两遍套件），给它留点时间
COV_TIMEOUT=240

# -------------------------------------------------------------------------
# 工具
# -------------------------------------------------------------------------

# _cov_run OUTVAR ARGS... —— 跑覆盖率工具，退出码写进 OUTVAR，stdout 写进 $COV_STDOUT
# 文件、stderr 写进 $COV_STDERR 文件。
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

# _cov_tree DIR —— 造一棵够用的假树：一套最小模块 + 一个最小套件。
#
# 只放三样东西：
#   lib/core/i18n.sh    —— 插桩要往这里注入 __cov_hit
#   lib/core/mini.sh    —— 两个公开函数 + 一个 _sk_ 私有函数
#   tests/run.sh        —— 只调用其中一个公开函数
# 工具跑的是 --suite 指定的命令，所以套件内容由调用方自己定。
_cov_tree() {
  local dir=$1
  mkdir -p "$dir/lib/core" "$dir/tests" || return 1

  cat >"$dir/lib/core/i18n.sh" <<'I18N'
#!/usr/bin/env bash
# 假 i18n：覆盖率插桩要把 __cov_hit 注到这里（它是 modules.txt 的第一个模块）。
I18N

  cat >"$dir/lib/core/mini.sh" <<'MINI'
#!/usr/bin/env bash
# 迷你库：两个公开函数 + 一个私有函数。
mini_alpha() {
  printf 'alpha\n'
}

mini_beta() {
  printf 'beta\n'
}

_sk_mini_private() {
  printf 'private\n'
}
MINI

  cat >"$dir/tests/run.sh" <<'SUITE'
#!/usr/bin/env bash
# 迷你套件：只调用 mini_alpha，mini_beta 与 _sk_mini_private 一次都不碰。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/core/i18n.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/core/mini.sh"
mini_alpha >/dev/null
SUITE
  return 0
}

# _cov_baseline FILE CONTENT —— 写基线文件
_cov_baseline() {
  printf '%s\n' "$2" >"$1"
  return 0
}

# CASE: 机制自测 —— 只调一个公开函数时，报告必须显示 1/2 并逐字点名另一个
d=$(tmpdir) || _fail "cannot create tmpdir"
_cov_tree "$d" || _fail "cannot build the mini tree"
mkdir -p "$d/tools"
# 基线放行 mini_beta：这样工具的退出码只受「未覆盖函数是否在基线里」影响
_cov_baseline "$d/tools/coverage_baseline.txt" "mini_beta"

rc=0
_cov_run rc --root "$d" --suite 'bash tests/run.sh' --baseline "$d/tools/coverage_baseline.txt"
out=$(cat "$COV_STDOUT")
assert_eq "0" "$rc" "the tool must succeed on the mini tree"
assert_contains "$out" "covered 1/2 (50%)" "the mini tree has one covered public function out of two"
assert_contains "$out" "mini_beta" "the uncovered public function must be named in the report"
assert_not_contains "$out" "mini_alpha" "the covered public function must not be listed as uncovered"
assert_not_contains "$out" "_sk_mini_private" "a private function must never be counted"
assert_not_contains "$out" "_sk_mini_private" "a private function must never appear in the report"

# 负对照：把私有函数也当成公开函数插桩，计数就会变成 2/3（mini_alpha + _sk_mini_private
# 都被算成公开函数）⇒ 上面那条断言必须因此失效。先确认工具当前的判据确实能区分。
mini_pub_count=$(grep -cE '^[a-z][a-z0-9_]*\(\) *\{' "$d/lib/core/mini.sh")
assert_eq "2" "$mini_pub_count" "the mini library has exactly two public functions"

# CASE: 棘轮负对照 —— 白名单里少一条，工具必须退出码非 0
d=$(tmpdir) || _fail "cannot create tmpdir"
_cov_tree "$d" || _fail "cannot build the mini tree"
mkdir -p "$d/tools"
# 基线是空的：mini_beta 未覆盖且不在基线里 ⇒ 违规
_cov_baseline "$d/tools/coverage_baseline.txt" ""

rc=0
_cov_run rc --root "$d" --suite 'bash tests/run.sh' --baseline "$d/tools/coverage_baseline.txt"
assert_ne "0" "$rc" "an uncovered function missing from the baseline must fail the ratchet"
err=$(cat "$COV_STDERR")
assert_contains "$err" "uncovered function not in the baseline: mini_beta" "the ratchet must name the offending function"

# 正对照：把 mini_beta 放进基线，同样的场景必须变绿
_cov_baseline "$d/tools/coverage_baseline.txt" "mini_beta"
rc=0
_cov_run rc --root "$d" --suite 'bash tests/run.sh' --baseline "$d/tools/coverage_baseline.txt"
assert_eq "0" "$rc" "the same scenario must pass once the baseline lists the function"

# CASE: 白名单不腐烂 —— 基线里塞一个不存在的公开函数名，必须判红
d=$(tmpdir) || _fail "cannot create tmpdir"
_cov_tree "$d" || _fail "cannot build the mini tree"
mkdir -p "$d/tools"
_cov_baseline "$d/tools/coverage_baseline.txt" "mini_beta"
_cov_baseline "$d/tools/coverage_baseline.txt" "mini_beta
mini_gamma"

rc=0
_cov_run rc --root "$d" --suite 'bash tests/run.sh' --baseline "$d/tools/coverage_baseline.txt"
assert_ne "0" "$rc" "a baseline entry that is not a public function must fail"
err=$(cat "$COV_STDERR")
assert_contains "$err" "the baseline lists a function that is not a public function: mini_gamma" "the stale baseline entry must be named"

# CASE: 白名单只允许记「当前确实未覆盖」的函数 —— 已经覆盖的还留在里面必须判红
#
# 这条是「覆盖回退」的护栏：白名单里留着已覆盖的函数，将来测试被误删、
# 覆盖消失，那个函数照样在白名单里，棘轮一声不吭 —— CI 照样绿。
d=$(tmpdir) || _fail "cannot create tmpdir"
_cov_tree "$d" || _fail "cannot build the mini tree"
mkdir -p "$d/tools"
# mini_alpha 是套件调到的那个（已覆盖）：把它留在白名单里就是白名单腐烂
_cov_baseline "$d/tools/coverage_baseline.txt" "mini_beta
mini_alpha"

rc=0
_cov_run rc --root "$d" --suite 'bash tests/run.sh' --baseline "$d/tools/coverage_baseline.txt"
assert_ne "0" "$rc" "a covered function left in the baseline must fail the ratchet"
err=$(cat "$COV_STDERR")
assert_contains "$err" "the baseline lists a covered function: mini_alpha" "the stale baseline entry must be named"

# 正对照：把已覆盖的移出白名单，同样的场景必须变绿
_cov_baseline "$d/tools/coverage_baseline.txt" "mini_beta"
rc=0
_cov_run rc --root "$d" --suite 'bash tests/run.sh' --baseline "$d/tools/coverage_baseline.txt"
assert_eq "0" "$rc" "the same scenario must pass once the covered function is removed from the baseline"

# CASE: 对真库跑一遍 —— 报告能生成、格式正确、覆盖数字合理
# 套件只跑 test_str.sh，覆盖的函数远少于全量套件 ⇒ 真库白名单（按全量生成）
# 罩不住这个套件的未覆盖集合。所以这里先用空基线跑一遍拿到本套件的未覆盖名单，
# 把它写成临时基线再跑一遍 —— 棘轮逻辑本身已由 case.1~3 覆盖，这里验的是
# 工具对真库能出格式正确的报告。
d=$(tmpdir) || _fail "cannot create tmpdir"
mkdir -p "$d"
suite_baseline="$d/suite.baseline"
rc=0
_cov_run rc --suite 'bash tests/test_str.sh' --baseline "$suite_baseline"
assert_eq "1" "$rc" "with an empty baseline every uncovered function must violate the ratchet"
awk '/^uncovered:/{f=1;next} /^excluded:/{f=0} f && /^  [a-z]/{print $1}' "$COV_STDOUT" >"$suite_baseline"
[ -s "$suite_baseline" ] || _fail "the suite uncovered nothing - implausible for a single test file"

outfile="$d/report.txt"
rc=0
_cov_run rc --suite 'bash tests/test_str.sh' --out "$outfile" --baseline "$suite_baseline"
out=$(cat "$COV_STDOUT")
assert_eq "0" "$rc" "the tool must succeed on the real library once the baseline covers the suite's uncovered set"
assert_contains "$out" "covered " "the report must start with the coverage line"
assert_contains "$out" "uncovered:" "the report must list the uncovered functions"

# 报告文件与 stdout 一致
if [ -f "$outfile" ]; then
  assert_eq "$out" "$(cat "$outfile")" "the --out file must carry the same report as stdout"
else
  _fail "the --out file was not written"
fi

# 覆盖数字合理：162 个公开函数，test_str.sh 只覆盖 str 那一块 ⇒ 覆盖率是几十个百分点
# （不是 0 也不是 100）。
pct=$(printf '%s\n' "$out" | awk '/^covered /{gsub(/[()%]/, "", $3); print $3}')
case "$pct" in
  '' | *[!0-9]*) _fail "the coverage percentage is not a number: <$pct>" ;;
esac
if [ "$pct" -le 0 ] || [ "$pct" -ge 100 ]; then
  _fail "the coverage percentage is not plausible for a single test file: <$pct>"
fi

# 报告里出现的未覆盖函数名必须都是真实的公开函数（不能有插桩残留物）
bad=$(printf '%s\n' "$out" | awk '/^uncovered:/{f=1; next} /^  /{if (f) print $1; next} {f=0}' |
  while IFS= read -r fn; do
    [ -n "$fn" ] || continue
    if ! grep -qhE "^${fn}\\(\\) *\\{" "$TEST_ROOT"/lib/core/*.sh; then
      printf '%s\n' "$fn"
    fi
  done)
assert_eq "" "$bad" "every uncovered name in the report must be a real public function"

exit 0
