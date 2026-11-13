#!/usr/bin/env bash
# tools/bench.sh 的回归。
#
# 要守的是「基准本身可信」：
#   1) 四条路径都测得出数（工具跑得通，不是跑一半假装成功）
#   2) 基线文件存在、四条路径都在、每条的浮动范围是合法数字
#   3) JSON 结构稳定（CI 靠它消费）
#   4) 校验逻辑真的有判据能力：基线里塞一个离谱的数，--check 必须报错
#
# 递归保护：套件会跑本文件 ⇒ 本文件调 bench.sh ⇒ bench.sh 测套件 ⇒ 套件又跑
# 本文件 ⇒ 无限套娃。bench.sh 跑套件时带 SHELLKIT_BENCH_CHILD=1；这里再把
# 套件路径换成一条空命令（BENCH_SUITE_CMD），既不套娃，结构也能验。
#
# ⚠ 套件路径量到的数来自那条空命令 ⇒ **不是**真套件的时间，只是用来验工具
#   的结构。性能结论看 tools/bench_baseline.txt —— 那里的数是真跑出来的。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

BENCH="$TEST_ROOT/tools/bench.sh"
BASELINE="$TEST_ROOT/tools/bench_baseline.txt"
PATHS="cli_bootstrap cli_new cli_upgrade test_suite"
SUITE_STUB='printf "bench suite stub\n"'

# is_num TEXT —— 这个字符串是不是一个合法的数字
is_num() {
  case "${1:-}" in
    '' | *[!0-9.]*) return 1 ;;
  esac
  case "${1:-}" in
    .* | *. | *.*.*) return 1 ;;
  esac
  return 0
}

# baseline_row_in FILE PATH —— 从指定基线文件里取一行，输出 "<基线秒> <浮动>"
baseline_row_in() {
  local __f=$1 __p=$2 __line __f1 __f2 __f3
  while IFS= read -r __line || [ -n "$__line" ]; do
    case "$__line" in
      '' | '#'*) continue ;;
    esac
    __f1=${__line%%$'\t'*}
    __line=${__line#*$'\t'}
    __f2=${__line%%$'\t'*}
    __line=${__line#*$'\t'}
    __f3=${__line%%$'\t'*}
    if [ "$__f1" = "$__p" ]; then
      printf '%s %s' "$__f2" "$__f3"
      return 0
    fi
  done <"$__f"
  return 1
}

# baseline_row PATH —— 从仓库里的基线文件取一行
baseline_row() {
  baseline_row_in "$BASELINE" "$1"
}

# CASE: 工具列得出那四条路径
listed=$(bash "$BENCH" --list) || _fail "the benchmark must list its paths"
__n=$(printf '%s\n' "$listed" | awk 'NF { n++ } END { print n + 0 }')
assert_eq "4" "$__n" "the benchmark must cover exactly four paths"
for __p in $PATHS; do
  assert_contains "$listed" "$__p" "the path list must contain $__p"
done

# CASE: 跑得通，四条路径都出数，JSON 结构字段齐全
d=$(tmpdir) || _fail "cannot create a temp dir"
out=$(BENCH_SUITE_CMD="$SUITE_STUB" bash "$BENCH" --runs 3 --json 2>"$d/bench.err")
rc=$?
assert_eq "0" "$rc" "the benchmark must run cleanly"
printf '%s\n' "$out" >"$d/bench.json"

if command -v python3 >/dev/null 2>&1; then
  if ! python3 - "$d/bench.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as fh:
    doc = json.load(fh)

problems = []
if doc.get("schema") != "shellkit.bench.v1":
    problems.append("schema: %r" % (doc.get("schema"),))
for key in ("runs", "clock", "tolerance", "status", "results"):
    if key not in doc:
        problems.append("missing top-level key: %s" % key)

results = doc.get("results")
want = sorted(["cli_bootstrap", "cli_new", "cli_upgrade", "test_suite"])
if not isinstance(results, list) or len(results) != 4:
    problems.append("results must be a list of 4 entries: %r" % (results,))
else:
    if sorted(r.get("path") for r in results) != want:
        problems.append("paths: %r" % (sorted(r.get("path") for r in results),))
    for entry in results:
        for key in ("path", "median", "min", "max", "runs", "status"):
            if key not in entry:
                problems.append("missing result key %s in %r" % (key, entry))
        for key in ("median", "min", "max"):
            value = entry.get(key)
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                problems.append("%s must be a number: %r" % (key, value))
            elif value <= 0:
                problems.append("%s must be positive: %r" % (key, value))
        if entry.get("status") != "ok":
            problems.append("status must be ok: %r" % (entry.get("status"),))

for problem in problems:
    sys.stderr.write("json problem: %s\n" % problem)
sys.exit(1 if problems else 0)
PY
  then
    _fail "the JSON structure is not what the CI consumer expects"
  fi
else
  # 没有 python3 的机器：退到字段名的文本断言（结构松一点，但不能没有）
  for __key in '"schema"' '"runs"' '"clock"' '"tolerance"' '"status"' '"results"' '"path"' '"median"' '"min"' '"max"'; do
    assert_contains "$out" "$__key" "the JSON must carry the $__key field"
  done
fi

# CASE: 基线文件存在，四条路径都在，每条的浮动范围是合法数字
assert_true test -f "$BASELINE"
for __p in $PATHS; do
  if ! __row=$(baseline_row "$__p"); then
    _fail "the baseline file has no entry for $__p"
  fi
  __med=${__row%% *}
  __tol=${__row##* }
  assert_true is_num "$__med"
  assert_true is_num "$__tol"
  if ! awk -v t="$__tol" 'BEGIN { exit (t > 0) ? 0 : 1 }'; then
    _fail "the tolerance of $__p must be positive, got <$__tol>"
  fi
done

# CASE: 正控制 —— 用刚实测出来的值造一份基线，--check 必须放行
#
# 没有这条，--check 就算「永远报错」也能把上面几条用例糊弄过去。
# 基线口径是**最小值**（判定也比最小值）⇒ 正控制必须拿最小值当基线。
__med=$(printf '%s\n' "$out" | awk -F'"min": ' '/"path": "cli_bootstrap"/ { split($2, a, ","); print a[1]; exit }')
assert_true is_num "$__med"
# 容差给到 10.0（±1000%）是刻意的：这条用例要拿「刚测出来的数」和「马上重测的数」
# 比，而两次独立实测在有负载时能差出 2.5 倍（实测 0.038s vs 0.098s）。
# 这里要验的是「基线合理时 --check 放行」，不是「基线该有多紧」——后者由下面那条
# 离谱值的用例把关。
printf 'cli_bootstrap\t%s\t10.0\t# measured right now\n' "$__med" >"$d/baseline-ok"
rc=0
bash "$BENCH" --only cli_bootstrap --runs 3 --check --baseline "$d/baseline-ok" \
  --summary "$d/sum-ok.md" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "a baseline built from the current measurement must pass the check"

# 同一次运行顺手验报告：CI 只给 --summary、不传 --check，报告里却必须说清
# 「这算不算回归」，否则读者还得自己翻基线文件对一遍。
assert_true test -f "$d/sum-ok.md"
__sum=$(cat "$d/sum-ok.md")
assert_contains "$__sum" "| 判定 |" "the report must carry a verdict column"
assert_contains "$__sum" "in band" "a healthy measurement must be reported as in band"
assert_contains "$__sum" "cli_bootstrap" "the report must name the measured path"
assert_contains "$__sum" "口径" "the report must state how the numbers were taken"

# CASE: 基线写的是**最小值**（口径锁死）
#
# 基线若写中位数，等于把测量当时的负载固化进基线 —— 之后每次量都显得「变快了」，
# 真正的回归反而看不出来。一次运行同时产出 JSON 与基线文件 ⇒ 两个数出自同一批
# 测量，可以逐字比对。
rc=0
out=$(bash "$BENCH" --only cli_bootstrap --runs 3 --json --write-baseline --baseline "$d/base-written" 2>/dev/null) || rc=$?
assert_eq "0" "$rc" "the benchmark must write a baseline and print JSON in one run"
__jmin=$(printf '%s\n' "$out" | awk -F'"min": ' '/"path": "cli_bootstrap"/ { split($2, a, ","); print a[1]; exit }')
__jmed=$(printf '%s\n' "$out" | awk -F'"median": ' '/"path": "cli_bootstrap"/ { split($2, a, ","); print a[1]; exit }')
assert_true is_num "$__jmin"
assert_true is_num "$__jmed"
__wrow=$(baseline_row_in "$d/base-written" cli_bootstrap) || _fail "the written baseline must have an entry for cli_bootstrap"
__wmin=${__wrow%% *}
assert_eq "$__jmin" "$__wmin" "the baseline must record the fastest run, not the median"

# CASE: 判据能力自检 —— 基线里的值被改成离谱的数，--check 必须报错
#
# 校验逻辑要是只比格式不看数值，这几条用例就红不了 ⇒ 基线根本没有约束力。
printf 'cli_bootstrap\t999999.000000\t0.30\t# tampered on purpose\n' >"$d/baseline-bad"
rc=0
out=$(bash "$BENCH" --only cli_bootstrap --runs 3 --check --baseline "$d/baseline-bad" \
  --summary "$d/sum-bad.md" 2>&1) || rc=$?
assert_ne "0" "$rc" "a tampered baseline must be reported as a regression"
assert_contains "$out" "outside the baseline band" "the check must name the path that is out of band"

# 报告的判定列必须自己红 —— 只有命令行报错、报告里写「in band」就自相矛盾
assert_true test -f "$d/sum-bad.md"
assert_contains "$(cat "$d/sum-bad.md")" "out band" "the report must flag a regression as out of band"

# CASE: 基线里的值不是数字 ⇒ 必须报错（不许静默跳过）
printf 'cli_bootstrap\tnot-a-number\t0.30\t# tampered on purpose\n' >"$d/baseline-nan"
rc=0
out=$(bash "$BENCH" --only cli_bootstrap --runs 3 --check --baseline "$d/baseline-nan" 2>&1) || rc=$?
assert_ne "0" "$rc" "a non-numeric baseline must be rejected"
assert_contains "$out" "is not numeric" "the check must say the entry is not numeric"

# CASE: 基线里缺了被测的那条路径 ⇒ 必须报错（不许当成「通过」）
printf 'cli_new\t1.000000\t0.30\t# only one path\n' >"$d/baseline-partial"
rc=0
out=$(bash "$BENCH" --only cli_bootstrap --runs 3 --check --baseline "$d/baseline-partial" 2>&1) || rc=$?
assert_ne "0" "$rc" "a baseline without the measured path must be rejected"
assert_contains "$out" "has no entry" "the check must say which path is missing"

# CASE: --profile 出内部热点（不计时；结构字段齐全、计数非零）
#
# profile 是「按数据决定优化」的前提：数不出热点，批次 A2 的优化就只能拍脑袋。
# 数值用参数展开从 JSON 抠，不走 "| head" 管道 —— head 命中即退会把上游
# 打成 SIGPIPE，pipe-safety 门禁盯着这种模式。
rc=0
out=$(bash "$BENCH" --profile --only cli_bootstrap --json 2>/dev/null) || rc=$?
assert_eq "0" "$rc" "profile mode must run cleanly"
assert_contains "$out" '"schema": "shellkit.bench.profile.v1"' "the profile output must carry its schema"
assert_contains "$out" '"path": "cli_bootstrap"' "the profile output must name the path"
assert_contains "$out" '"status": "ok"' "a successful profile must say so"

__src=${out#*\"source_count\": }
__src=${__src%%,*}
[ -n "$__src" ] || _fail "profile output must carry source_count"
# source_count >= 10：modules.txt 里 23 个模块逐个 source + bootstrap 自身（实测 24）
assert_true test "$__src" -ge 10

__int=${out#*\"internal_calls\": }
__int=${__int%%,*}
[ -n "$__int" ] || _fail "profile output must separate internal calls"
# 私有函数调用（_sk_* 每模块都调）必须单列，不混进 fork 候选 —— 少了这个
# 字段，_sk_mod_index 会把 bootstrap 顶成「80 次 fork」的假热点
assert_true test "$__int" -ge 1

__tl=${out#*\"trace_lines\": }
__tl=${__tl%%,*}
[ -n "$__tl" ] || _fail "profile output must carry trace_lines"
# trace 行数非零：数不到命令说明 xtrace 没接上（__xtrace 开关掉了）
assert_true test "$__tl" -ge 100

# CASE: --profile 与 --check 语义互斥 ⇒ 用法错（profile 不产出可比的耗时值）
rc=0
out=$(bash "$BENCH" --profile --check --only cli_bootstrap 2>&1) || rc=$?
assert_eq "2" "$rc" "--profile must refuse --check"
assert_contains "$out" "--profile cannot be combined" "the usage error must say why"

# CASE: text 模式（默认）给人读
rc=0
out=$(bash "$BENCH" --profile --only cli_bootstrap 2>/dev/null) || rc=$?
assert_eq "0" "$rc" "text profile must run cleanly"
assert_contains "$out" "profile cli_bootstrap: status=ok" "the text output must name the path and status"
assert_contains "$out" "source=" "the text output must carry the source count"
assert_contains "$out" "top commands:" "the text output must list top commands"

# CASE: test_suite 不做 profile（整套 trace 几十万行，且热点要按路径拆开看），
# 跳过且不算错误
rc=0
out=$(bash "$BENCH" --profile --only test_suite --json 2>/dev/null) || rc=$?
assert_eq "0" "$rc" "skipping test_suite must not be an error"
assert_contains "$out" '"status": "skipped"' "the profile must report test_suite as skipped"

exit 0
