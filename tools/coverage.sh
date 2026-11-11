#!/usr/bin/env bash
#
# 覆盖率工具 —— 把「哪块没被测到」变成可测量的东西。
#
# 用法：
#   bash tools/coverage.sh [--out FILE] [--suite CMD] [--min PCT]
#
# 做法：
#   1) 把仓库复制到临时目录（不拷 site/ 与 .git）
#   2) 给 lib/core 的公开函数插桩：函数体第一句调一次 __cov_hit
#   3) 在副本里跑测试套件，统计哪些公开函数一次都没被调到
#   4) 与 tools/coverage_baseline.txt 比对：白名单外的未覆盖函数 ⇒ 违规
#      白名单只允许记「当前确实未覆盖」的函数：已经覆盖的还留在里面，
#      棘轮就看不见覆盖回退 —— 将来测试被误删，它照样在白名单里，CI 照样绿。
#
# 三条纪律：
#   1) **绝不在红的套件上算覆盖率**：跑套件前先在未插桩的副本上跑一遍确认是绿的，
#      插桩后再跑一遍，这一步也必须是绿的。任何一步不绿 ⇒ 中止。
#      （红着的套件会让每个函数都算「被覆盖」，是彻底的假绿。）
#   2) 插桩只碰 lib/core/*.sh 里行首 name() { 的**公开**函数（下划线开头的私有函数不插）。
#   3) stdout 只给数据，日志一律 stderr。
#
# 退出码：
#   0  通过
#   1  棘轮违规（白名单外有未覆盖函数 / 白名单里有不存在的函数 / 覆盖率低于阈值）
#   2  用法错
#   3  前置条件不满足（套件不是绿的，覆盖率算不出来）
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

OUT_FILE=""
SUITE_CMD="bash tests/run.sh"
MIN_PCT=""
TREE_ROOT=""
BASELINE_FILE=""
WRITE_BASELINE=0

usage() {
  cat <<'EOF'
usage: bash tools/coverage.sh [--out FILE] [--suite CMD] [--min PCT]

  --out FILE     把报告写进 FILE（内容与 stdout 相同）
  --suite CMD    在副本树里执行的命令（默认：bash tests/run.sh）
  --min PCT      覆盖率低于 PCT 就判失败
  --root DIR     被测的仓库根目录（默认：脚本所在目录的上一级）
  --baseline FILE  基线白名单文件（默认：<root>/tools/coverage_baseline.txt）
  --write-baseline  按本次结果重写基线白名单（只记当前确实未覆盖的函数）
EOF
}

die_usage() {
  printf 'coverage: %s\n' "$*" >&2
  usage >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --out)
      [ $# -ge 2 ] || die_usage "--out 需要一个参数"
      OUT_FILE=$2
      shift 2
      ;;
    --out=*)
      OUT_FILE=${1#*=}
      shift
      ;;
    --suite)
      [ $# -ge 2 ] || die_usage "--suite 需要一个参数"
      SUITE_CMD=$2
      shift 2
      ;;
    --suite=*)
      SUITE_CMD=${1#*=}
      shift
      ;;
    --min)
      [ $# -ge 2 ] || die_usage "--min 需要一个参数"
      MIN_PCT=$2
      shift 2
      ;;
    --min=*)
      MIN_PCT=${1#*=}
      shift
      ;;
    --root)
      [ $# -ge 2 ] || die_usage "--root 需要一个参数"
      TREE_ROOT=$2
      shift 2
      ;;
    --root=*)
      TREE_ROOT=${1#*=}
      shift
      ;;
    --baseline)
      [ $# -ge 2 ] || die_usage "--baseline 需要一个参数"
      BASELINE_FILE=$2
      shift 2
      ;;
    --baseline=*)
      BASELINE_FILE=${1#*=}
      shift
      ;;
    --write-baseline)
      WRITE_BASELINE=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die_usage "未知选项：$1"
      ;;
  esac
done

if [ -n "$MIN_PCT" ]; then
  case "$MIN_PCT" in
    '' | *[!0-9]*) die_usage "--min 只接受 0-100 的整数" ;;
  esac
  if [ "$MIN_PCT" -gt 100 ]; then
    die_usage "--min 只接受 0-100 的整数"
  fi
fi

case "$OUT_FILE" in
  '') ;;
  /*) ;;
  *) OUT_FILE="$PWD/$OUT_FILE" ;;
esac

# 被测的仓库根：--root 优先，否则是脚本所在目录的上一级
if [ -n "$TREE_ROOT" ]; then
  ROOT="$(cd "$TREE_ROOT" && pwd -P)" || {
    printf 'coverage: cannot enter the root directory: %s\n' "$TREE_ROOT" >&2
    exit 2
  }
fi

# ---------------------------------------------------------------------------
# 临时工作区
# ---------------------------------------------------------------------------

WORK="$(mktemp -d "${TMPDIR:-/tmp}/shellkit-cov.XXXXXX")" || {
  printf 'coverage: cannot create a work directory\n' >&2
  exit 3
}
WORK="$(cd "$WORK" && pwd -P)"

_cleanup() {
  rm -rf "$WORK"
}
trap _cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

TREE="$WORK/tree"
COV_LOG="$WORK/cov.log"
UNIVERSE="$WORK/universe.txt"
if [ -n "$BASELINE_FILE" ]; then
  BASELINE="$BASELINE_FILE"
else
  BASELINE="$ROOT/tools/coverage_baseline.txt"
fi

log() {
  printf 'coverage: %s\n' "$*" >&2
}

# ---------------------------------------------------------------------------
# 1) 复制仓库到副本
#
# 不拷 site/（有 node_modules，太大）与 .git（历史与覆盖率无关）。
# ---------------------------------------------------------------------------

mkdir -p "$TREE" || {
  log "cannot create the copy directory"
  exit 3
}

for __d in lib tests tools templates locale po docs examples skills; do
  if [ -e "$ROOT/$__d" ]; then
    cp -Rp "$ROOT/$__d" "$TREE/" || {
      log "cannot copy $__d"
      exit 3
    }
  fi
done

for __f in shellkit install.sh repair.sh Makefile VERSION README.md AGENTS.md LICENSE NOTICE; do
  if [ -f "$ROOT/$__f" ]; then
    cp -p "$ROOT/$__f" "$TREE/" || {
      log "cannot copy $__f"
      exit 3
    }
  fi
done

# ---------------------------------------------------------------------------
# 2) 排除「检查源码树」的用例
#
# 插桩会改源码 ⇒ 那些拿源码跟生成物比对的门禁用例必然对不上。
# 让它们红着比把它们排除掉更糟：红着的套件会让所有覆盖率结论失效。
# 这里把它们从副本里挪走（tests/run.sh 的通配是 tests/test_*.sh），
# 并在报告里写明排除了哪些、为什么。
# ---------------------------------------------------------------------------

EXCLUDED_DIR="$TREE/tests/.coverage-excluded"
EXCLUDED_LIST="$WORK/excluded.list"
mkdir -p "$EXCLUDED_DIR"
: >"$EXCLUDED_LIST"

_exclude_reason() {
  case "$1" in
    test_coverage.sh)
      printf '%s' "runs the coverage tool itself; running it inside the coverage run would recurse"
      ;;
    test_ai_docs.sh)
      printf '%s' "compares the generated docs with the source tree; instrumentation changes the source"
      ;;
    test_local_names.sh)
      printf '%s' "lints the library sources; instrumentation adds lines the linter does not expect"
      ;;
    test_module_count.sh)
      printf '%s' "compares the module count in the docs with lib/modules.txt; the docs are generated from the instrumented sources"
      ;;
    test_pipe_safety.sh)
      printf '%s' "lints the pipelines in the library sources; instrumentation changes the sources it reads"
      ;;
    *)
      printf '%s' "inspects the source tree"
      ;;
  esac
}

for __f in test_coverage.sh test_ai_docs.sh test_local_names.sh test_module_count.sh test_pipe_safety.sh; do
  if [ -f "$TREE/tests/$__f" ]; then
    mv "$TREE/tests/$__f" "$EXCLUDED_DIR/$__f" || {
      log "cannot exclude $__f"
      exit 3
    }
    printf '%s\t%s\n' "$__f" "$(_exclude_reason "$__f")" >>"$EXCLUDED_LIST"
  fi
done

# ---------------------------------------------------------------------------
# 3) 跑套件（未插桩）—— 必须先绿
# ---------------------------------------------------------------------------

_run_suite() {
  local logfile=$1
  local rc=0
  (
    cd "$TREE" || exit 3
    unset SHELLKIT_COVERAGE_LOG
    bash -c "$SUITE_CMD"
  ) >"$logfile" 2>&1 || rc=$?
  return $rc
}

_report_red() {
  local logfile=$1
  local phase=$2
  local names
  names="$(grep '^FAILED: ' "$logfile" 2>/dev/null | sed 's/^FAILED: //' | tr '\n' ' ')"
  log "the suite is RED ($phase) - coverage would be a false green, aborting"
  if [ -n "$names" ]; then
    log "red test files: $names"
  else
    log "red test files: (the suite printed no FAILED: line; see the log below)"
  fi
  log "----- suite log (tail) -----"
  tail -n 40 "$logfile" >&2
  log "----- end of suite log -----"
}

log "running the suite on the untouched copy (this must be green)..."
if ! _run_suite "$WORK/suite-plain.log"; then
  _report_red "$WORK/suite-plain.log" "before instrumentation"
  exit 3
fi
log "the untouched copy is green"

# ---------------------------------------------------------------------------
# 4) 插桩
#
# 只碰 lib/core/*.sh 里行首 name() { 的公开函数：
#   name() {            ->  name() { __cov_hit name;
#   name() { body; }    ->  name() { __cov_hit name; body; }
# 一行体函数自然变成一行，函数体一行都不动。
# ---------------------------------------------------------------------------

if [ ! -d "$TREE/lib/core" ]; then
  log "the copy has no lib/core directory - nothing to instrument"
  exit 3
fi

: >"$UNIVERSE"

for __f in "$TREE"/lib/core/*.sh; do
  [ -f "$__f" ] || continue
  __tmp="$__f.covtmp"
  awk -v allfile="$UNIVERSE" '
    match($0, /^[a-z][a-z0-9_]*\(\) *\{/) {
      fn = substr($0, 1, index($0, "(") - 1)
      print fn "() { __cov_hit " fn ";" substr($0, RLENGTH + 1)
      print fn >> allfile
      next
    }
    { print }
  ' "$__f" >"$__tmp" || {
    log "cannot instrument $__f"
    exit 3
  }
  mv "$__tmp" "$__f" || {
    log "cannot replace $__f"
    exit 3
  }
done

# __cov_hit 的定义注入到 i18n.sh 的最顶部：
# i18n 是 lib/modules.txt 的第一个模块，一定先于任何插桩函数被加载。
# 不用命令替换（不 fork），只用纯重定向追加；环境变量没设就静默返回。
COV_DEF="$WORK/cov_hit.def"
cat >"$COV_DEF" <<'COVDEF'
# 覆盖率插桩（由 tools/coverage.sh 自动注入，勿手改）
__cov_hit() {
  [ -n "${SHELLKIT_COVERAGE_LOG:-}" ] || return 0
  printf '%s\n' "$1" >> "$SHELLKIT_COVERAGE_LOG"
}
COVDEF

I18N="$TREE/lib/core/i18n.sh"
if [ ! -f "$I18N" ]; then
  log "the copy has no lib/core/i18n.sh - cannot inject __cov_hit"
  exit 3
fi

__first=""
IFS= read -r __first <"$I18N" || true

__tmp="$I18N.covtmp"
{
  case "$__first" in
    '#!'*)
      printf '%s\n' "$__first"
      printf '\n'
      cat "$COV_DEF"
      awk 'NR > 1' "$I18N"
      ;;
    *)
      cat "$COV_DEF"
      cat "$I18N"
      ;;
  esac
} >"$__tmp" || {
  log "cannot inject __cov_hit"
  exit 3
}
mv "$__tmp" "$I18N" || {
  log "cannot replace $I18N"
  exit 3
}

TOTAL="$(LC_ALL=C sort -u "$UNIVERSE" | wc -l | tr -d ' ')"
log "instrumented $TOTAL public functions"

# ---------------------------------------------------------------------------
# 5) 跑套件（已插桩）—— 也必须绿
# ---------------------------------------------------------------------------

: >"$COV_LOG"

log "running the suite on the instrumented copy (this must be green too)..."
if ! (
  cd "$TREE" || exit 3
  export SHELLKIT_COVERAGE_LOG="$COV_LOG"
  bash -c "$SUITE_CMD"
) >"$WORK/suite-cov.log" 2>&1; then
  _report_red "$WORK/suite-cov.log" "after instrumentation"
  exit 3
fi
log "the instrumented copy is green"

# ---------------------------------------------------------------------------
# 6) 收数据
# ---------------------------------------------------------------------------

LC_ALL=C sort -u "$UNIVERSE" >"$WORK/universe.sorted"
if [ -s "$COV_LOG" ]; then
  LC_ALL=C sort -u "$COV_LOG" >"$WORK/hits.sorted"
else
  : >"$WORK/hits.sorted"
fi
LC_ALL=C comm -12 "$WORK/universe.sorted" "$WORK/hits.sorted" >"$WORK/covered.txt"
LC_ALL=C comm -23 "$WORK/universe.sorted" "$WORK/hits.sorted" >"$WORK/uncovered.txt"

COVERED="$(wc -l <"$WORK/covered.txt" | tr -d ' ')"
UNCOVERED="$(wc -l <"$WORK/uncovered.txt" | tr -d ' ')"
PCT=0
if [ "$TOTAL" -gt 0 ]; then
  PCT=$((COVERED * 100 / TOTAL))
fi

# ---------------------------------------------------------------------------
# 6.5) 「重写基线」模式
#
# 白名单的正确定义是「当前确实未覆盖的公开函数」。手改容易漏、也容易留，
# 所以给它一条命令：跑完把未覆盖集合写进去。
# 这一趟是「修基线」，不是「查基线」：棘轮判定跳过（它正是要修的东西），
# 报告照常出，基线在报告之后写。
# ---------------------------------------------------------------------------
if [ "$WRITE_BASELINE" = "1" ]; then
  log "rewriting the baseline: $BASELINE"
fi

# ---------------------------------------------------------------------------
# 7) 白名单（棘轮）
#
# 基线是「当前确实没被覆盖的公开函数」名单。规则（三条都要成立）：
#   - 实际未覆盖、且不在基线里 => 违规（新加了一个谁都没测的公开函数）
#   - 基线里有、但已经不是公开函数了 => 违规（白名单腐烂）
#   - 基线里有、而且已经被覆盖了 => 违规（白名单该瘦身：留着就看不见覆盖回退）
# ---------------------------------------------------------------------------

BASELINE_NAMES=""
if [ -f "$BASELINE" ]; then
  while IFS= read -r __line || [ -n "$__line" ]; do
    __line="${__line%%#*}"
    __line="${__line#"${__line%%[![:space:]]*}"}"
    __line="${__line%"${__line##*[![:space:]]}"}"
    [ -n "$__line" ] || continue
    BASELINE_NAMES="$BASELINE_NAMES $__line"
  done <"$BASELINE"
else
  log "no baseline file at $BASELINE - every uncovered function counts as a violation"
fi

VIOLATIONS=0

if [ "$WRITE_BASELINE" != "1" ]; then
  # 重写模式：基线本身就是这一趟要修的东西，不拿它判自己

  while IFS= read -r __fn || [ -n "$__fn" ]; do
    [ -n "$__fn" ] || continue
    case " $BASELINE_NAMES " in
      *" $__fn "*) ;;
      *)
        printf 'coverage: uncovered function not in the baseline: %s\n' "$__fn" >&2
        VIOLATIONS=1
        ;;
    esac
  done <"$WORK/uncovered.txt"

  for __fn in $BASELINE_NAMES; do
    if ! grep -qxF -- "$__fn" "$WORK/universe.sorted"; then
      printf 'coverage: the baseline lists a function that is not a public function: %s\n' "$__fn" >&2
      VIOLATIONS=1
      continue
    fi
    # 白名单只允许记「当前确实未覆盖」的函数。已经覆盖的还留在里面，
    # 棘轮就看不见覆盖回退：将来测试被误删，那个函数照样在白名单里，永远绿。
    if grep -qxF -- "$__fn" "$WORK/covered.txt"; then
      printf 'coverage: the baseline lists a covered function: %s (remove it: bash tools/coverage.sh --write-baseline)\n' "$__fn" >&2
      VIOLATIONS=1
    fi
  done

fi

if [ -n "$MIN_PCT" ] && [ "$PCT" -lt "$MIN_PCT" ]; then
  printf 'coverage: coverage %s%% is below the required %s%%\n' "$PCT" "$MIN_PCT" >&2
  VIOLATIONS=1
fi

# ---------------------------------------------------------------------------
# 8) 报告
#
# stdout 只给数据；--out 写同样内容。
# ---------------------------------------------------------------------------

REPORT="$WORK/report.txt"
{
  printf 'covered %s/%s (%s%%)\n' "$COVERED" "$TOTAL" "$PCT"
  printf 'uncovered:\n'
  if [ "$UNCOVERED" -eq 0 ]; then
    printf '  (none)\n'
  else
    while IFS= read -r __fn || [ -n "$__fn" ]; do
      [ -n "$__fn" ] || continue
      printf '  %s\n' "$__fn"
    done <"$WORK/uncovered.txt"
  fi
  if [ -s "$EXCLUDED_LIST" ]; then
    printf 'excluded:\n'
    while IFS= read -r __line || [ -n "$__line" ]; do
      [ -n "$__line" ] || continue
      __fn="${__line%%$'\t'*}"
      __reason="${__line#*$'\t'}"
      printf '  %s - %s\n' "$__fn" "$__reason"
    done <"$EXCLUDED_LIST"
  fi
} >"$REPORT"

cat "$REPORT"

if [ -n "$OUT_FILE" ]; then
  cat "$REPORT" >"$OUT_FILE" || {
    log "cannot write the report to $OUT_FILE"
    exit 3
  }
  log "report written to $OUT_FILE"
fi

# ---------------------------------------------------------------------------
# 9) 重写基线（--write-baseline）
#
# 报告出完之后再写：这一趟既给出「哪块没测到」，又给出「白名单该长什么样」。
# ---------------------------------------------------------------------------
if [ "$WRITE_BASELINE" = "1" ]; then
  {
    printf '# 覆盖率白名单：当前确实没被测试覆盖的公开函数。\n'
    printf '# 由 bash tools/coverage.sh --write-baseline 生成，不要手工维护。\n'
    printf '# 棘轮规则：这里面的函数一旦被覆盖，CI 就要求把它移出（防覆盖回退）。\n'
    cat "$WORK/uncovered.txt"
  } >"$BASELINE.tmp" || {
    log "cannot write the baseline"
    exit 3
  }
  mv -f "$BASELINE.tmp" "$BASELINE" || {
    log "cannot replace the baseline: $BASELINE"
    exit 3
  }
  log "wrote $BASELINE ($UNCOVERED uncovered function(s))"
  exit 0
fi

if [ "$VIOLATIONS" -ne 0 ]; then
  log "ratchet violated (see the messages above)"
  exit 1
fi

log "coverage $PCT% - ratchet OK"
exit 0
