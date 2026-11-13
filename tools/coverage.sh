#!/usr/bin/env bash
#
# 覆盖率工具 —— 把「哪块没被测到」变成可测量的东西。
#
# 用法：
#   bash tools/coverage.sh [--out FILE] [--suite CMD] [--min PCT]
#   bash tools/coverage.sh --branch [--guards FILE] [--write-baseline] ...
#
# 两种模式：
#   函数级（默认）—— 给 lib/core 的公开函数体第一句插 __cov_hit，
#     与 tools/coverage_baseline.txt 比对（原有行为，一字未动）。
#   分支级（--branch）—— 在 if/elif 的 then 臂、else 臂、case 各臂、
#     以及单行 `||` 短路守卫的右臂上插 __cov_hit，统计每个分支臂的命中数，
#     与 tools/coverage_branch_baseline.txt 比对（棘轮与函数级同构）。
#     插桩范围：lib/core/*.sh、lib/bootstrap.sh、shellkit、install.sh、
#     repair.sh、tools/release_gate.sh —— 四条关键路径（Upgrade / Install /
#     Skill / Repair）与 release gate 的分支都在考核范围内。
#     分支 ID 形如 <file>:<fn>:<n>（函数内序号；不用行号 —— 行号会被
#     无关改动挤跑）。报告附带 guards 段：#39/#40/#41/#42 的 P0 守卫分支
#     必须命中，白名单救不了（见 --guards；默认清单内嵌在本脚本里）。
#
# 做法：
#   1) 把仓库复制到临时目录（不拷 site/ 与 .git）
#   2) 给 lib/core 的公开函数插桩：函数体第一句调一次 __cov_hit
#      （--branch 模式：按上面说的分支臂插桩，并逐文件 bash -n 验语法）
#   3) 在副本里跑测试套件，统计哪些公开函数 / 分支臂一次都没被调到
#   4) 与基线白名单比对：白名单外的未覆盖 ⇒ 违规
#      白名单只允许记「当前确实未覆盖」的：已经覆盖的还留在里面，
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
MODE="function"
# GUARDS_MODE: default = 内嵌 #39-#42 守卫清单；none = 不强制；file = 用户清单
GUARDS_MODE="default"
GUARDS_FILE=""

usage() {
  cat <<'EOF'
usage: bash tools/coverage.sh [--branch] [--out FILE] [--suite CMD] [--min PCT]

  --branch       分支级覆盖：插桩 if/elif/case/|| 各分支臂，棘轮同函数级
  --guards FILE  分支守卫清单（仅 --branch；默认内嵌 #39-#42 守卫清单；
                 传空串 "" 表示只报告不强制）
  --out FILE     把报告写进 FILE（内容与 stdout 相同）
  --suite CMD    在副本树里执行的命令（默认：bash tests/run.sh）
  --min PCT      覆盖率低于 PCT 就判失败
  --root DIR     被测的仓库根目录（默认：脚本所在目录的上一级）
  --baseline FILE  基线白名单文件（默认：<root>/tools/coverage_baseline.txt；
                 --branch 时是 coverage_branch_baseline.txt）
  --write-baseline  按本次结果重写基线白名单（只记当前确实未覆盖的）
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
    --branch)
      MODE="branch"
      shift
      ;;
    --guards)
      [ $# -ge 2 ] || die_usage "--guards 需要一个参数"
      GUARDS_FILE=$2
      if [ -z "$GUARDS_FILE" ]; then GUARDS_MODE="none"; else GUARDS_MODE="file"; fi
      shift 2
      ;;
    --guards=*)
      GUARDS_FILE=${1#*=}
      if [ -z "$GUARDS_FILE" ]; then GUARDS_MODE="none"; else GUARDS_MODE="file"; fi
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
  if [ "${KEEP_WORK:-0}" = "1" ]; then
    log "KEEP_WORK=1 - keeping $WORK"
    return 0
  fi
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
elif [ "$MODE" = "branch" ]; then
  BASELINE="$ROOT/tools/coverage_branch_baseline.txt"
else
  BASELINE="$ROOT/tools/coverage_baseline.txt"
fi

# guards 清单模式：default（内嵌清单）/ none（--guards ""）/ file（--guards FILE）
# 在上面的参数解析里判定，这里只做一致性收口。

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
    test_coverage_branch.sh)
      printf '%s' "runs the branch coverage tool itself; running it inside the coverage run would recurse"
      ;;
    test_api_baseline.sh)
      printf '%s' "rebuilds a repo copy with git archive HEAD; the coverage copy has no .git so the archive silently yields an empty tree"
      ;;
    test_api_stability.sh)
      printf '%s' "runs the api gate itself; its probes would cover functions the product suite never touches (same reason as test_api_baseline.sh)"
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
    test_meta_gates.sh)
      printf '%s' "mutates literal source text; branch instrumentation rewrites the lines its mutators match"
      ;;
    *)
      printf '%s' "inspects the source tree"
      ;;
  esac
}

# 排除清单按模式选：test_coverage_branch 两种模式都递归（它自己会调本工具）；
# test_meta_gates 只在分支模式排除（它的变异器按字面量匹配源码行，分支插桩会改写那些行）。
COV_EXCLUDES="test_coverage.sh test_coverage_branch.sh test_api_baseline.sh test_api_stability.sh test_ai_docs.sh test_local_names.sh test_module_count.sh test_pipe_safety.sh"
if [ "$MODE" = "branch" ]; then
  COV_EXCLUDES="$COV_EXCLUDES test_meta_gates.sh"
fi

for __f in $COV_EXCLUDES; do
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

# __cov_hit 的定义：函数级注入到 i18n.sh（modules.txt 的第一个模块，先于
# 任何插桩函数被加载）；分支级注入到每个被插桩文件的最顶部（shellkit /
# install.sh / repair.sh / release_gate.sh 是独立入口，不一定先加载 i18n）。
# 不用命令替换（不 fork），只用纯重定向追加；环境变量没设就静默返回。
COV_DEF="$WORK/cov_hit.def"
cat >"$COV_DEF" <<'COVDEF'
# 覆盖率插桩（由 tools/coverage.sh 自动注入，勿手改）
# 注意：名字与 () 之间留一个空格 —— tests/test_bootstrap.sh 靠「文件里第一个
# name() 定义」判断模块是否加载，紧凑写法会被它当成每个模块的首函数。
__cov_hit () {
  [ -n "${SHELLKIT_COVERAGE_LOG:-}" ] || return 0
  printf '%s\n' "$1" >> "$SHELLKIT_COVERAGE_LOG"
}
COVDEF

if [ "$MODE" = "function" ]; then

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

else

  # ---------------------------------------------------------------------------
  # 分支级插桩：if/elif 的 then 臂、else 臂、case 各臂、单行 || 守卫的右臂
  # ---------------------------------------------------------------------------

  : >"$WORK/skipped.list"

  BRANCH_LIST="$WORK/branch_files.list"
  : >"$BRANCH_LIST"
  for __f in "$TREE"/lib/core/*.sh "$TREE"/lib/bootstrap.sh "$TREE"/shellkit "$TREE"/install.sh "$TREE"/repair.sh "$TREE"/tools/release_gate.sh; do
    [ -f "$__f" ] || continue
    printf '%s\n' "$__f" >>"$BRANCH_LIST"
  done

  if [ ! -s "$BRANCH_LIST" ]; then
    log "no files to instrument in branch mode"
    exit 3
  fi

  INSTR_AWK="$WORK/branch_instr.awk"
  cat >"$INSTR_AWK" <<'AWKEOF'
# 分支级插桩器（POSIX awk）——由 tools/coverage.sh 生成。
# 在 if/elif 的 then 臂、else 臂、case 各臂、单行 || 守卫的右臂上插入
#   __cov_hit '<file>:<fn>:<n>'；ID 用「文件:函数:序号」而不是行号。
# 语义保持：__cov_hit 恒返回 0、只写日志文件；插入点都在引号之外；
# 插桩后的文件必须过 bash -n（调用方负责）。
# -v rel=文件相对路径 -v universe=ID清单 -v skips=跳过清单
BEGIN {
  fn = "<toplevel>"; armseq = 0; casedepth = 0
  hd = ""; hdstrip = 0; npend = 0; nif = 0
  BT = sprintf("%c", 96)
}
function norm(s) {
  gsub(/[ \t]+/, " ", s)
  sub(/^ /, "", s)
  sub(/ $/, "", s)
  sub(/;[ \t]*$/, "", s)
  return s
}
function addskip(r) { printf "%s:%d %s\n", rel, NR, r >> skips }
function alloc(ctx, id) {
  armseq++
  id = rel ":" fn ":" armseq
  printf "%s\t%s\n", id, norm(ctx) >> universe
  return id
}
function ins(id) { return " __cov_hit '" id "';" }
function kyp(c) { return (c == "" || c == " " || c == "\t" || c == ";" || c == "&" || c == "|" || c == "(") }
function kyn(c) { return (c == "" || c == " " || c == "\t" || c == ";" || c == "&" || c == "|" || c == ")") }
# rhs_end(p)：|| 右臂的结束位置（0 = 到行尾）。引号/括号感知。
function rhs_end(p,   j, q, d, c2, pv) {
  j = p; q = 0; d = 0; pv = ""
  while (j <= n) {
    c2 = substr(line, j, 1)
    if (q == 1) { if (c2 == "\\") j++; else if (c2 == "\"") q = 0; j++; continue }
    if (q == 2) { if (c2 == "'") q = 0; j++; continue }
    if (q == 3) { if (c2 == BT) q = 0; j++; continue }
    if (c2 == "\\") { j += 2; continue }
    if (c2 == "\"") { q = 1; j++; continue }
    if (c2 == "'") { q = 2; j++; continue }
    if (c2 == BT) { q = 3; j++; continue }
    if (c2 == "#" && (j == p || pv == " " || pv == "\t" || pv == ";" || pv == "&" || pv == "|" || pv == "(")) return j
    if (c2 == "(") { d++; pv = c2; j++; continue }
    if (c2 == ")") { if (d == 0) return j; d--; pv = c2; j++; continue }
    if (d == 0) {
      if (c2 == ";") return j
      if (c2 == "&" && substr(line, j + 1, 1) == "&") return j
      if (c2 == "|" && substr(line, j + 1, 1) == "|") return j
    }
    pv = c2; j++
  }
  return 0
}
{
  line = $0
  n = length(line)
  # ---- heredoc 体内：原文输出，只统计被跳过的疑似分支行 ----
  if (hd != "") {
    t = line
    if (hdstrip) { gsub(/^[ \t]+/, "", t); gsub(/[ \t]+$/, "", t) }
    if (line == hd || (hdstrip && t == hd)) { hd = ""; print line; next }
    if (line ~ /^[ \t]*(if|elif|else)([ \t]|$)/ || line ~ /^[ \t]*case([ \t]|$)/) addskip("heredoc")
    print line
    next
  }
  # ---- 函数归属（决定 ID 的 fn 段）----
  if (line ~ /^[A-Za-z_][A-Za-z0-9_]*\(\)[ \t]*\{/) {
    fn = line
    sub(/\(.*/, "", fn)
    armseq = 0
  } else if (line ~ /^}/) {
    fn = "<toplevel>"
    armseq = 0
  }
  orig = line
  out = ""
  i = 1
  depth = 0
  in_dq = 0
  in_sq = 0
  in_bt = 0
  in_wrap = 0
  wend = 0
  prev = ""
  armdone = 0
  while (i <= n) {
    c = substr(line, i, 1)
    nx = substr(line, i + 1, 1)
    nx2 = substr(line, i + 2, 1)
    # 已开的 || 右臂到收口位：先闭合再处理该字符
    if (in_wrap && wend > 0 && i == wend) { out = out "; }"; in_wrap = 0 }
    # 右臂里的 $? 必须看到的是 || 左边的失败状态：开口处已 __cov_rc=$? 捕获，
    # 这里把文本换掉（单引号内不展开，保持字面量）
    if (in_wrap && !in_sq && c == "$" && nx == "?") {
      out = out "$__cov_rc"
      if (npend > 0) pend_c[npend] = pend_c[npend] "$?"
      i += 2
      prev = "?"
      continue
    }
    if (in_dq) {
      out = out c
      if (npend > 0) pend_c[npend] = pend_c[npend] c
      if (c == "\\") { out = out nx; i += 2; prev = nx; continue }
      if (c == "\"") in_dq = 0
      i++; prev = c
      continue
    }
    if (in_sq) {
      out = out c
      if (npend > 0) pend_c[npend] = pend_c[npend] c
      if (c == "'") in_sq = 0
      i++; prev = c
      continue
    }
    if (in_bt) {
      out = out c
      if (npend > 0) pend_c[npend] = pend_c[npend] c
      if (c == BT) in_bt = 0
      i++; prev = c
      continue
    }
    # 注释起点（词首 #）：原样输出剩余部分
    if (c == "#" && kyp(prev)) {
      if (in_wrap) { out = out "; }"; in_wrap = 0 }
      out = out substr(line, i)
      break
    }
    if (c == "\"") { in_dq = 1; out = out c; if (npend > 0) pend_c[npend] = pend_c[npend] c; i++; prev = c; continue }
    if (c == "'") { in_sq = 1; out = out c; if (npend > 0) pend_c[npend] = pend_c[npend] c; i++; prev = c; continue }
    if (c == BT) { in_bt = 1; out = out c; if (npend > 0) pend_c[npend] = pend_c[npend] c; i++; prev = c; continue }
    if (c == "\\") { out = out c nx; if (npend > 0) pend_c[npend] = pend_c[npend] c nx; i += 2; prev = nx; continue }
    # heredoc 起点（<<< 是 herestring，不是多行）
    if (c == "<" && nx == "<") {
      if (nx2 == "<") { out = out "<<<"; i += 3; prev = "<"; continue }
      j2 = i + 2
      strip = 0
      if (substr(line, j2, 1) == "-") { strip = 1; j2++ }
      q2 = substr(line, j2, 1)
      word = ""
      if (q2 == "'" || q2 == "\"") {
        j2++
        while (j2 <= n && substr(line, j2, 1) != q2) { word = word substr(line, j2, 1); j2++ }
        j2++
      } else {
        while (j2 <= n && substr(line, j2, 1) ~ /[A-Za-z_]/) { word = word substr(line, j2, 1); j2++ }
      }
      if (word != "") { hd = word; hdstrip = strip }
      out = out substr(line, i, j2 - i)
      i = j2
      prev = " "
      continue
    }
    # || 短路守卫：右臂包进 { __cov_hit ID; ...; }
    if (c == "|" && nx == "|") {
      if (npend > 0) pend_c[npend] = pend_c[npend] "||"
      if (depth > 0) { out = out "||"; addskip("nested-or"); i += 2; prev = "|"; continue }
      if (in_wrap) { out = out "; }"; in_wrap = 0 }
      k2 = i + 2
      while (k2 <= n && (substr(line, k2, 1) == " " || substr(line, k2, 1) == "\t")) k2++
      we = rhs_end(k2)
      if (we == 0) re = substr(line, k2); else re = substr(line, k2, we - k2)
      rt = re
      gsub(/^[ \t]+/, "", rt)
      gsub(/[ \t]+$/, "", rt)
      skipr = ""
      lastc = ""
      if (rt != "") lastc = substr(rt, length(rt), 1)
      if (rt == "") skipr = "continuation"
      else if (lastc == "\\" || lastc == "!" || lastc == "&" || lastc == "|" || lastc == "(" || lastc == "{" || lastc == "}") skipr = "complex-or"
      else {
        w3 = ""
        m3 = k2
        while (m3 <= n) {
          ch3 = substr(line, m3, 1)
          if (ch3 ~ /[A-Za-z_]/) { w3 = w3 ch3; m3++ } else break
        }
        if (w3 == "") w3 = substr(line, k2, 1)
        if (w3 == "if" || w3 == "then" || w3 == "else" || w3 == "elif" || w3 == "fi" || w3 == "case" || w3 == "esac" || w3 == "while" || w3 == "until" || w3 == "for" || w3 == "do" || w3 == "done" || w3 == "{" || w3 == "(" || w3 == "}") skipr = "complex-or"
      }
      if (skipr != "") { out = out "||"; addskip(skipr); i += 2; prev = "|"; continue }
      id = alloc(orig)
      out = out "|| {"
      if (index(re, "$?") > 0) out = out " __cov_rc=$?;"
      out = out ins(id)
      in_wrap = 1
      wend = we
      i += 2
      prev = "|"
      continue
    }
    # 括号深度
    if (c == "(") {
      depth++
      out = out c
      if (npend > 0) pend_c[npend] = pend_c[npend] c
      i++; prev = c
      continue
    }
    if (c == ")") {
      if (depth > 0) depth--
      out = out c
      if (npend > 0) pend_c[npend] = pend_c[npend] c
      # case 臂：行首到此 ) 的片段非空、不含 (、且 ) 后是边界 => 臂头
      if (!armdone && casedepth > 0) {
        seg = substr(line, 1, i - 1)
        s2 = seg
        sub(/^[ \t]+/, "", s2)
        nb = substr(line, i + 1, 1)
        if (s2 != "" && index(s2, "(") == 0 && (nb == "" || nb == " " || nb == "\t" || nb == ";" || nb == "&")) {
          id = alloc(s2)
          out = out ins(id)
          armdone = 1
        }
      }
      i++; prev = c
      continue
    }
    # 关键词（引号外、词边界）
    if (kyp(prev)) {
      if (substr(line, i, 4) == "elif" && kyn(substr(line, i + 4, 1))) {
        out = out "elif"
        npend++
        pend_t[npend] = "elif"
        pend_c[npend] = ""
        i += 4; prev = "f"
        continue
      }
      if (substr(line, i, 4) == "then" && kyn(substr(line, i + 4, 1))) {
        out = out "then"
        if (npend > 0) {
          cond = pend_c[npend]
          ptype = pend_t[npend]
          npend--
          id = alloc(cond)
          if (ptype == "elif") {
            if (nif > 0) if_c[nif] = cond; else { nif++; if_c[nif] = cond }
          } else { nif++; if_c[nif] = cond }
          out = out ins(id)
        } else addskip("orphan-then")
        i += 4; prev = "n"
        continue
      }
      if (substr(line, i, 4) == "else" && kyn(substr(line, i + 4, 1))) {
        out = out "else"
        if (nif > 0) {
          id = alloc("else: " if_c[nif])
          out = out ins(id)
        } else addskip("orphan-else")
        i += 4; prev = "e"
        continue
      }
      if (substr(line, i, 4) == "case" && kyn(substr(line, i + 4, 1))) {
        out = out "case"
        casedepth++
        i += 4; prev = "e"
        continue
      }
      if (substr(line, i, 4) == "esac" && kyn(substr(line, i + 4, 1))) {
        out = out "esac"
        if (casedepth > 0) casedepth--
        i += 4; prev = "c"
        continue
      }
      if (substr(line, i, 2) == "if" && kyn(substr(line, i + 2, 1))) {
        out = out "if"
        npend++
        pend_t[npend] = "if"
        pend_c[npend] = ""
        i += 2; prev = "f"
        continue
      }
      if (substr(line, i, 2) == "fi" && kyn(substr(line, i + 2, 1))) {
        out = out "fi"
        if (nif > 0) nif--
        i += 2; prev = "i"
        continue
      }
    }
    out = out c
    if (npend > 0) pend_c[npend] = pend_c[npend] c
    i++
    prev = c
  }
  if (in_wrap) out = out "; }"
  print out
}
AWKEOF

  while IFS= read -r __f; do
    [ -n "$__f" ] || continue
    __rel=${__f#"$TREE/"}
    __tmp="$__f.covtmp"
    # 先 cp -p 保留模式：重定向新建的临时文件是 644，mv 回去会让
    # shellkit / install.sh / repair.sh 丢可执行位（调用方当场 126）
    cp -p "$__f" "$__tmp" || {
      log "cannot preserve the mode of $__f"
      exit 3
    }
    awk -v rel="$__rel" -v universe="$UNIVERSE" -v skips="$WORK/skipped.list" -f "$INSTR_AWK" "$__f" >"$__tmp" || {
      log "cannot instrument $__f"
      exit 3
    }
    mv "$__tmp" "$__f" || {
      log "cannot replace $__f"
      exit 3
    }
    # 每个被插桩文件自带 __cov_hit 定义（独立入口脚本先于 i18n 执行）
    __first=""
    IFS= read -r __first <"$__f" || true
    __tmp="$__f.covtmp"
    cp -p "$__f" "$__tmp" || {
      log "cannot preserve the mode of $__f"
      exit 3
    }
    {
      case "$__first" in
        '#!'*)
          printf '%s\n' "$__first"
          printf '\n'
          cat "$COV_DEF"
          awk 'NR > 1' "$__f"
          ;;
        *)
          cat "$COV_DEF"
          cat "$__f"
          ;;
      esac
    } >"$__tmp" || {
      log "cannot inject __cov_hit into $__f"
      exit 3
    }
    mv "$__tmp" "$__f" || {
      log "cannot replace $__f"
      exit 3
    }
    # 语法门：插桩改写过的文件必须还是合法 bash（$BASH 就是跑本工具的那个解释器）
    if ! "$BASH" -n "$__f" 2>"$WORK/bashn.err"; then
      log "the instrumented $__f does not parse - aborting"
      cat "$WORK/bashn.err" >&2
      exit 3
    fi
  done <"$BRANCH_LIST"

  TOTAL="$(cut -f1 "$UNIVERSE" | LC_ALL=C sort -u | wc -l | tr -d ' ')"
  log "instrumented $TOTAL branch arms"

fi

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

if [ "$MODE" = "branch" ]; then
  cut -f1 "$UNIVERSE" | LC_ALL=C sort -u >"$WORK/universe.sorted"
else
  LC_ALL=C sort -u "$UNIVERSE" >"$WORK/universe.sorted"
fi
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
if [ "$MODE" = "function" ]; then
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
fi

VIOLATIONS=0

if [ "$MODE" = "function" ]; then
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

else
  # ---- 分支棘轮（三条规则，与函数级同构）----
  BASELINE_IDS=" "
  if [ -f "$BASELINE" ]; then
    while IFS= read -r __line || [ -n "$__line" ]; do
      __line="${__line%%#*}"
      __line="${__line#"${__line%%[![:space:]]*}"}"
      __line="${__line%"${__line##*[![:space:]]}"}"
      [ -n "$__line" ] || continue
      BASELINE_IDS="$BASELINE_IDS$__line "
    done <"$BASELINE"
  else
    log "no baseline file at $BASELINE - every uncovered branch counts as a violation"
  fi

  if [ "$WRITE_BASELINE" != "1" ]; then
    # 规则一：实际未覆盖、且不在基线里 => 红（新增了没人测的分支）
    while IFS= read -r __id || [ -n "$__id" ]; do
      [ -n "$__id" ] || continue
      case "$BASELINE_IDS" in
        *" $__id "*) ;;
        *)
          printf 'coverage: branch not in the baseline: %s\n' "$__id" >&2
          VIOLATIONS=1
          ;;
      esac
    done <"$WORK/uncovered.txt"

    # 规则二/三：基线里的分支必须还在、且确实未覆盖（名单失效 / 该瘦身）
    if [ -f "$BASELINE" ]; then
      while IFS= read -r __raw || [ -n "$__raw" ]; do
        [ -n "$__raw" ] || continue
        __id="${__raw%%#*}"
        __id="${__id#"${__id%%[![:space:]]*}"}"
        __id="${__id%"${__id##*[![:space:]]}"}"
        [ -n "$__id" ] || continue
        case "$BASELINE_IDS" in
          *" $__id "*) ;;
          *) continue ;;
        esac
        if ! grep -qxF -- "$__id" "$WORK/universe.sorted"; then
          printf 'coverage: the baseline lists a branch that no longer exists: %s\n' "$__id" >&2
          VIOLATIONS=1
          continue
        fi
        if grep -qxF -- "$__id" "$WORK/covered.txt"; then
          printf 'coverage: the baseline lists a covered branch: %s (remove it: bash tools/coverage.sh --branch --write-baseline)\n' "$__id" >&2
          VIOLATIONS=1
        fi
      done <"$BASELINE"
    fi
  fi

  # ---- P0 守卫分支（#39-#42）：必须命中，白名单救不了 ----
  if [ "$GUARDS_MODE" != "none" ]; then
    if [ "$GUARDS_MODE" = "default" ]; then
      GUARDS_FILE="$WORK/guards.def"
      cat >"$GUARDS_FILE" <<'GDEFE'
#39|shellkit|_sk_skill_uninstall_from|_SK_OWN_RELS[@]}" -gt 0
#39|shellkit|_sk_skill_uninstall_from|_sk_fs_rel_safe
#39|shellkit|_sk_skill_uninstall_from|__cur" = "$__sum
#40|shellkit|_sk_skill_install_into|_sk_fs_no_symlink_below
#41|repair.sh|_complete|lib/core/$__mod.sh
#41|repair.sh|_complete|lib/bootstrap.sh
#42|tools/release_gate.sh|<toplevel>|MISSING
#42|tools/release_gate.sh|<toplevel>|QUERY_FAILED
#42|tools/release_gate.sh|<toplevel>|completed/*
GDEFE
    fi
    if [ ! -f "$GUARDS_FILE" ]; then
      log "guards file not found: $GUARDS_FILE"
      exit 3
    fi
    : >"$WORK/guards.stats"
    while IFS= read -r __g || [ -n "$__g" ]; do
      # 注释 = 行独一个 #，或 # 后跟空格；守卫的 issue 标签是 "#39|..."，
      # 不是注释 —— 写成 '#*' 会把默认清单整段吃掉（守卫静默失效）。
      case "$__g" in '' | '#' | '# '*) continue ;; esac
      __tag=${__g%%|*}
      __rest=${__g#*|}
      __gfile=${__rest%%|*}
      __rest=${__rest#*|}
      __gfn=${__rest%%|*}
      __gsub=${__rest#*|}
      # 子串与 universe 里的 context 同一口径：空白折叠
      __gsub=$(printf '%s' "$__gsub" | awk '{$1=$1; print}')
      [ -n "$__gsub" ] || continue
      __matched=$(awk -v p="$__gfile:$__gfn:" -v s="$__gsub" -F'\t' 'index($1, p) == 1 && index($2, s) > 0 { print $1 }' "$UNIVERSE")
      if [ -z "$__matched" ]; then
        printf 'coverage: guard has no matching branch: [%s] %s:%s ~ %s\n' "$__tag" "$__gfile" "$__gfn" "$__gsub" >&2
        VIOLATIONS=1
        continue
      fi
      __gt=0
      __gh=0
      while IFS= read -r __id || [ -n "$__id" ]; do
        [ -n "$__id" ] || continue
        __gt=$((__gt + 1))
        if grep -qxF -- "$__id" "$WORK/covered.txt"; then
          __gh=$((__gh + 1))
        else
          printf 'coverage: guard branch not hit: [%s] %s\n' "$__tag" "$__id" >&2
          VIOLATIONS=1
        fi
      done <<EOF
$__matched
EOF
      printf '%s|%s:%s|%s/%s\n' "$__tag" "$__gfile" "$__gfn" "$__gh" "$__gt" >>"$WORK/guards.stats"
    done <"$GUARDS_FILE"
  fi

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
if [ "$MODE" = "function" ]; then
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
else
  SKIPN="$(wc -l <"$WORK/skipped.list" | tr -d ' ')"
  {
    printf 'branch coverage: enumerated %s, hit %s (%s%%), skipped %s, whitelist %s\n' \
      "$TOTAL" "$COVERED" "$PCT" "$SKIPN" "$UNCOVERED"
    printf 'paths:\n'
    awk -F'\t' '
      function path_of(id,   file, rest, fn) {
        rest = id
        file = rest
        sub(/:.*/, "", file)
        rest = substr(id, length(file) + 2)
        fn = rest
        sub(/:[^:]*$/, "", fn)
        if (file == "repair.sh") return "Repair"
        if (fn ~ /skill/) return "Skill"
        if (fn ~ /upgrade/) return "Upgrade"
        if (file == "install.sh") return "Install"
        if (fn ~ /install_self|uninstall_self/) return "Install"
        if (fn ~ /vendor|dir_swap/) return "Install"
        return ""
      }
      FILENAME == ARGV[1] { hit[$1] = 1; next }
      {
        p = path_of($1)
        if (p == "") next
        enum[p]++
        if ($1 in hit) h[p]++
      }
      END {
        order[1] = "Upgrade"
        order[2] = "Install"
        order[3] = "Skill"
        order[4] = "Repair"
        for (k = 1; k <= 4; k++) {
          p = order[k]
          printf "  %s: %s/%s arms hit\n", p, h[p] + 0, enum[p] + 0
        }
      }
    ' "$WORK/covered.txt" "$UNIVERSE"
    printf 'guards:\n'
    if [ "$GUARDS_MODE" = "none" ]; then
      printf '  (disabled)\n'
    elif [ -s "$WORK/guards.stats" ]; then
      while IFS= read -r __line || [ -n "$__line" ]; do
        [ -n "$__line" ] || continue
        __tag=${__line%%|*}
        __rest=${__line#*|}
        __head=${__rest%%|*}
        __ht=${__rest#*|}
        printf '  [%s] %s: %s guard arms hit\n' "$__tag" "$__head" "$__ht"
      done <"$WORK/guards.stats"
    else
      printf '  (no guard entries matched the instrumented universe)\n'
    fi
    printf 'skipped %s:\n' "$SKIPN"
    if [ ! -s "$WORK/skipped.list" ]; then
      printf '  (none)\n'
    else
      while IFS= read -r __line || [ -n "$__line" ]; do
        [ -n "$__line" ] || continue
        printf '  %s\n' "$__line"
      done <"$WORK/skipped.list"
    fi
    printf 'whitelist %s:\n' "$UNCOVERED"
    if [ "$UNCOVERED" -eq 0 ]; then
      printf '  (none)\n'
    else
      while IFS= read -r __id || [ -n "$__id" ]; do
        [ -n "$__id" ] || continue
        printf '  %s\n' "$__id"
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
fi

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
  if [ "$MODE" = "branch" ]; then
    {
      printf '# 分支覆盖白名单：当前确实没被测试覆盖的分支臂。\n'
      printf '# 由 bash tools/coverage.sh --branch --write-baseline 生成，不要手工维护。\n'
      printf '# 棘轮规则：这里面的分支一旦被覆盖，CI 就要求把它移出（防覆盖回退）。\n'
      cat "$WORK/uncovered.txt"
    } >"$BASELINE.tmp" || {
      log "cannot write the baseline"
      exit 3
    }
  else
    {
      printf '# 覆盖率白名单：当前确实没被测试覆盖的公开函数。\n'
      printf '# 由 bash tools/coverage.sh --write-baseline 生成，不要手工维护。\n'
      printf '# 棘轮规则：这里面的函数一旦被覆盖，CI 就要求把它移出（防覆盖回退）。\n'
      cat "$WORK/uncovered.txt"
    } >"$BASELINE.tmp" || {
      log "cannot write the baseline"
      exit 3
    }
  fi
  mv -f "$BASELINE.tmp" "$BASELINE" || {
    log "cannot replace the baseline: $BASELINE"
    exit 3
  }
  if [ "$MODE" = "branch" ]; then
    log "wrote $BASELINE ($UNCOVERED uncovered branch arm(s))"
    if [ "$VIOLATIONS" -ne 0 ]; then
      log "baseline written, but guards are violated (see the messages above)"
      exit 1
    fi
  else
    log "wrote $BASELINE ($UNCOVERED uncovered function(s))"
  fi
  exit 0
fi

if [ "$VIOLATIONS" -ne 0 ]; then
  log "ratchet violated (see the messages above)"
  exit 1
fi

log "coverage $PCT% - ratchet OK"
exit 0
