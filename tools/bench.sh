#!/usr/bin/env bash
#
# 性能基准 —— 四条关键路径的耗时基线。
#
# 用法：
#   bash tools/bench.sh [选项]
#
#   --runs N            每条路径跑几次取中位数（默认 3；少于 3 视为用法错）
#   --retries N         一次运行失败后重试几次（默认 0；套件偶发抖动不该作废整次基准）
#   --json              stdout 输出 JSON（供 CI 报告消费）
#   --check             拿实测值跟基线比：超出浮动范围 ⇒ 退出码 1
#   --write-baseline    按本次实测重写基线文件（数值必须是真跑出来的）
#   --baseline FILE     基线文件（默认 <repo>/tools/bench_baseline.txt）
#   --tolerance PCT     允许浮动比例（默认 0.30，即 ±30%）
#   --root DIR          被测的代码根（默认：脚本所在的仓库；对着代码快照测时用）
#   --only PATH[,PATH]  只测其中几条路径（逗号分隔）
#   --list              列出四条路径的名字
#   --profile           不计时：跑一遍 xtrace，数被测进程内部的热点（命令/文件/source）
#   -h, --help          显示帮助
#
# 测的四条路径：
#   cli_bootstrap  CLI 启动：起一个 bash 进程 source lib/bootstrap.sh，
#                  按 lib/modules.txt 加载全部模块（SHELLKIT_MODULES 置空）
#   cli_new        shellkit new：模板渲染 + 落盘 + 写清单 + vendor 库
#   cli_upgrade    shellkit upgrade：指纹比对 + 渲染 + 逐文件原子替换 + vendor 库
#   test_suite     bash tests/run.sh（只计时；不代替它跑）
#
# 计时口径（为什么不用 date +%s.%N）：
#   macOS 的 date 没有 %N（那是 GNU date 的）⇒ 不能假设 GNU date。
#   这里按优先级挑一个能出浮点秒的时钟：
#     1) python3：time.time()（跨进程可比的墙上时钟）
#     2) perl：Time::HiRes=time（macOS 自带 perl）
#     3) 兜底：bash 的 SECONDS（只有整秒精度 ⇒ 快路径会记成 0；
#        此时 stderr 提示一次，不静默降级）
#   每次测量前后各取一个时间戳，差值用 awk 算（bash 没有浮点）。
#
# 统计口径：每条路径跑 N 次（N ≥ 3），取中位数 —— 单次噪音不进基线。
# 建工程（new / upgrade）一律在临时目录里做，**绝不碰仓库自身的工作树**；
# 建工程的时间算准备时间，不计入被测路径。
#
# 递归保护：测试套件里会跑 tests/test_bench.sh，那个用例又会调本脚本。
# 没有这层保护 ⇒ bench 测套件 → 套件测 bench → bench 再测套件 ⇒ 无限套娃。
# 所以跑套件时给子进程带上 SHELLKIT_BENCH_CHILD=1，本脚本见到它就跳过套件路径。
# BENCH_SUITE_CMD 换掉套件命令时没有套娃风险，此时套件路径照常测。
#
# 退出码：
#   0  全部路径测成功（--check 时：全部落在基线的浮动范围内）
#   1  有路径测失败 / 环境准备失败（--check 时：超出基线的浮动范围）
#   2  用法错
#
# stdout 只给数据，日志一律 stderr。
set -uo pipefail

# SELF_ROOT = 本脚本所在的仓库；ROOT = 被测的代码根（默认就是它）
#
# --root 用来对着「代码快照」测：共享工作树里别人正在改代码时，测出来的数
# 随时会变；对着快照测，数才是稳的、可复现的。
SELF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ROOT="$SELF_ROOT"

# 浮点格式化的小数点必须是 '.'：德语 locale 下 bash 的 printf 会出逗号，
# 那样 JSON 与基线文件里的数字就不是合法的 JSON 数字了。
export LC_ALL=C

RUNS=3
RETRIES=0
JSON=0
CHECK=0
WRITE=0
LIST=0
TOLERANCE="0.30"
BASELINE=""
SUMMARY=""
ONLY=""
PROFILE=0
ALL_PATHS="cli_bootstrap cli_new cli_upgrade test_suite"
MIN_RUNS=3

# 测套件路径时执行的命令。默认就是套件本身；BENCH_SUITE_CMD 只给测试用
# （把套件路径换成一条空命令，验证工具结构时不用真跑一遍套件）。
# ⚠ 换掉它之后，套件路径量到的就不是真套件的时间了 —— 别拿它当性能结论。
DEFAULT_SUITE_CMD="bash tests/run.sh"
SUITE_CMD="${BENCH_SUITE_CMD:-$DEFAULT_SUITE_CMD}"

# 建工程时用的临时路径（准备阶段填好，执行阶段读）
__new_dir=""
__up_dir=""
__up_tpl=""
# profile 模式下给被测命令开 xtrace（bash -x）用的开关；平时为空。
# 不加引号是刻意的：空值展开成零个词（加引号会变成一个空参数）。
__xtrace=""

usage() {
  cat <<'EOF'
usage: bash tools/bench.sh [options]

  --runs N            每条路径跑几次取中位数（默认 3，最少 3）
  --retries N         一次运行失败后重试几次（默认 0）
  --json              stdout 输出 JSON
  --check             跟基线比：超出浮动范围 ⇒ 退出码 1
  --write-baseline    按本次实测重写基线文件
  --baseline FILE     基线文件（默认 tools/bench_baseline.txt）
  --summary FILE      额外写一份 markdown 报告（CI 的 job summary 用）
  --tolerance PCT     允许浮动比例（默认 0.30）
  --root DIR          被测的代码根（默认：脚本所在的仓库）
  --only PATH[,PATH]  只测其中几条路径
  --list              列出四条路径的名字
  --profile           不计时：跑一遍 xtrace，数被测进程内部的热点
EOF
}

log() {
  printf 'bench: %s\n' "$*" >&2
}

die_usage() {
  printf 'bench: %s\n' "$*" >&2
  usage >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --runs)
      [ $# -ge 2 ] || die_usage "--runs needs a value"
      RUNS=$2
      shift 2
      ;;
    --runs=*)
      RUNS=${1#*=}
      shift
      ;;
    --retries)
      [ $# -ge 2 ] || die_usage "--retries needs a value"
      RETRIES=$2
      shift 2
      ;;
    --retries=*)
      RETRIES=${1#*=}
      shift
      ;;
    --json)
      JSON=1
      shift
      ;;
    --check)
      CHECK=1
      shift
      ;;
    --write-baseline)
      WRITE=1
      shift
      ;;
    --baseline)
      [ $# -ge 2 ] || die_usage "--baseline needs a value"
      BASELINE=$2
      shift 2
      ;;
    --summary)
      [ $# -ge 2 ] || die_usage "--summary needs a value"
      SUMMARY=$2
      shift 2
      ;;
    --summary=*)
      SUMMARY=${1#*=}
      shift
      ;;
    --baseline=*)
      BASELINE=${1#*=}
      shift
      ;;
    --tolerance)
      [ $# -ge 2 ] || die_usage "--tolerance needs a value"
      TOLERANCE=$2
      shift 2
      ;;
    --tolerance=*)
      TOLERANCE=${1#*=}
      shift
      ;;
    --root)
      [ $# -ge 2 ] || die_usage "--root needs a value"
      ROOT=$2
      shift 2
      ;;
    --root=*)
      ROOT=${1#*=}
      shift
      ;;
    --only)
      [ $# -ge 2 ] || die_usage "--only needs a value"
      ONLY=$2
      shift 2
      ;;
    --only=*)
      ONLY=${1#*=}
      shift
      ;;
    --list)
      LIST=1
      shift
      ;;
    --profile)
      PROFILE=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die_usage "unknown option: $1" ;;
  esac
done

case "$RUNS" in
  '' | *[!0-9]*) die_usage "--runs takes a positive integer" ;;
esac
if [ "$RUNS" -lt "$MIN_RUNS" ]; then
  die_usage "--runs must be at least $MIN_RUNS (a single run is noise, not a baseline)"
fi

case "$TOLERANCE" in
  '' | *[!0-9.]*) die_usage "--tolerance takes a number (e.g. 0.30)" ;;
esac

case "$RETRIES" in
  '' | *[!0-9]*) die_usage "--retries takes a non-negative integer" ;;
esac

# --profile 数的是内部热点，不产出可比的耗时值 —— 拿它做基线判定没有意义
if [ "$PROFILE" = "1" ] && { [ "$CHECK" = "1" ] || [ "$WRITE" = "1" ]; }; then
  die_usage "--profile cannot be combined with --check or --write-baseline"
fi

if [ -z "$BASELINE" ]; then
  BASELINE="$SELF_ROOT/tools/bench_baseline.txt"
fi

# 被测的代码根必须真的是一棵 shellkit 树
if [ ! -d "$ROOT" ]; then
  die_usage "--root is not a directory: $ROOT"
fi
ROOT="$(cd "$ROOT" && pwd -P)" || die_usage "--root is not a directory: $ROOT"
if [ ! -f "$ROOT/shellkit" ] || [ ! -d "$ROOT/templates" ] || [ ! -d "$ROOT/tests" ]; then
  die_usage "--root does not look like a shellkit tree: $ROOT"
fi

# --only 的路径名必须在那四条里：拼错的路径名静默跑空 ⇒ 假绿
SELECTED="$ALL_PATHS"
if [ -n "$ONLY" ]; then
  SELECTED=""
  __rest=$ONLY
  while [ -n "$__rest" ]; do
    case "$__rest" in
      *,*)
        __p=${__rest%%,*}
        __rest=${__rest#*,}
        ;;
      *)
        __p=$__rest
        __rest=""
        ;;
    esac
    [ -n "$__p" ] || continue
    case " $ALL_PATHS " in
      *" $__p "*) ;;
      *) die_usage "unknown path: $__p" ;;
    esac
    SELECTED="$SELECTED $__p"
  done
fi

if [ "$LIST" = "1" ]; then
  for __p in $ALL_PATHS; do
    printf '%s\n' "$__p"
  done
  exit 0
fi

# ---------------------------------------------------------------------------
# 工作区：所有临时工程都建在这里，退出时连根拔掉
# ---------------------------------------------------------------------------

WORK="$(mktemp -d "${TMPDIR:-/tmp}/shellkit-bench.XXXXXX")" || {
  log "cannot create the work directory"
  exit 1
}
WORK="$(cd "$WORK" && pwd -P)"
cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ---------------------------------------------------------------------------
# 时钟
# ---------------------------------------------------------------------------

_CLOCK=""

# _detect_clock —— 挑一个能出浮点秒的时钟
#
# macOS 的 date 不支持 %N ⇒ 不能用 GNU date 的 date +%s.%N。
# 优先 python3（最常见），其次 macOS 自带的 perl，最后才退到 bash 的 SECONDS
# （只有整秒精度，快路径会记成 0 —— 这种降级要出声，不许静默）。
_detect_clock() {
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import time' >/dev/null 2>&1; then
    _CLOCK=python3
  elif command -v perl >/dev/null 2>&1 && perl -MTime::HiRes=time -e '1' >/dev/null 2>&1; then
    _CLOCK=perl
  else
    _CLOCK=seconds
    log "neither python3 nor perl found: falling back to bash SECONDS (whole seconds only - sub-second paths read as 0)"
  fi
}

# _now —— 当前时间戳（秒，浮点；跨进程可比）
_now() {
  case "$_CLOCK" in
    python3) python3 -c 'import time; print("%.6f" % time.time())' ;;
    perl) perl -MTime::HiRes=time -e 'printf "%.6f\n", time' ;;
    *) printf '%s' "$SECONDS" ;;
  esac
}

# _elapsed START END —— 两个时间戳之间过了多少秒
_elapsed() {
  awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN { printf "%.6f", b - a }'
}

# _is_num TEXT —— 这个字符串是不是一个合法的数字
_is_num() {
  local __v=${1:-}
  case "$__v" in
    '' | *[!0-9.]*) return 1 ;;
  esac
  case "$__v" in
    .* | *. | *.*.*) return 1 ;;
  esac
  return 0
}

# _median FILE —— 一组秒数的中位数（偶数个取中间两个的平均）
_median() {
  sort -n "$1" | awk '{ v[NR] = $1 } END {
    n = NR
    if (n == 0) { printf "%.6f\n", 0 }
    else if (n % 2 == 1) { printf "%.6f\n", v[(n + 1) / 2] }
    else { printf "%.6f\n", (v[n / 2] + v[n / 2 + 1]) / 2 }
  }'
}

# ---------------------------------------------------------------------------
# 四条路径的准备与执行
#
# 准备（建工程）不计时：被测的是「升级」这件事，不是「造工程」这件事。
# ---------------------------------------------------------------------------

_prep_cli_bootstrap() {
  return 0
}

_run_cli_bootstrap() {
  # 起一个 bash 进程，source lib/bootstrap.sh —— 它按 lib/modules.txt 的顺序
  # source lib/core/*.sh（SHELLKIT_MODULES 置空 = 全部模块）。
  # 与 CLI 的启动路径同口径：CLI 自己也是 set -euo pipefail + source bootstrap。
  # $__xtrace 平时为空、profile 模式下是 -x（把被测进程的命令吐给热点统计）
  # shellcheck disable=SC2086  # 空值要展开成零个词，加引号反而变成空参数
  (cd "$ROOT" && SHELLKIT_MODULES='' bash $__xtrace -c 'set -euo pipefail; . "$1/lib/bootstrap.sh"' _ "$ROOT")
}

_prep_cli_new() {
  local __path=$1 __run=$2
  local __d="$WORK/new-$__run"
  rm -rf "$__d"
  mkdir -p "$__d" || return 1
  __new_dir="$__d/proj"
  return 0
}

_run_cli_new() {
  # shellcheck disable=SC2086  # $__xtrace 空值要展开成零个词（见 _run_cli_bootstrap）
  bash $__xtrace "$ROOT/shellkit" new "$__new_dir" --name benchproj --cmd run --yes
}

_prep_cli_upgrade() {
  local __path=$1 __run=$2
  local __d="$WORK/upgrade-$__run"
  rm -rf "$__d"
  mkdir -p "$__d" || return 1
  # 两份模板：v1 用来建工程（记录进清单的指纹），v2 比 v1 多一行 ⇒
  # 升级时真的会走「指纹比对 → 渲染 → 逐文件原子替换」这条路，
  # 而不是比完发现没差异、什么活都没干。
  cp -Rp "$ROOT/templates" "$__d/tpl-v1" || return 1
  cp -Rp "$ROOT/templates" "$__d/tpl-v2" || return 1
  printf '\n# shellkit bench: the template changed\n' >>"$__d/tpl-v2/lib/app.sh" || return 1
  bash "$ROOT/shellkit" new "$__d/proj" --name benchproj --cmd run --template "$__d/tpl-v1" --yes || return 1
  __up_dir="$__d/proj"
  __up_tpl="$__d/tpl-v2"
  return 0
}

_run_cli_upgrade() {
  # shellcheck disable=SC2086  # $__xtrace 空值要展开成零个词（见 _run_cli_bootstrap）
  bash $__xtrace "$ROOT/shellkit" upgrade "$__up_dir" --template "$__up_tpl" --yes
}

_prep_test_suite() {
  return 0
}

_run_test_suite() {
  # 只计时，不代替它跑：套件仍然是唯一的正确性判据。
  # SHELLKIT_BENCH_CHILD=1 让套件里的 test_bench.sh 知道自己在套件里，
  # 别再回头测套件（无限套娃）。
  (cd "$ROOT" && SHELLKIT_BENCH_CHILD=1 bash -c "$SUITE_CMD")
}

# _path_desc PATH —— 这条路径的口径说明（写进基线文件）
_path_desc() {
  case "$1" in
    cli_bootstrap)
      printf '%s' 'CLI 启动：bash 进程 source lib/bootstrap.sh，按 lib/modules.txt 加载全部模块'
      ;;
    cli_new)
      printf '%s' 'shellkit new：模板渲染 + 落盘 + 写清单 + vendor 库（建工程的时间不计入）'
      ;;
    cli_upgrade)
      printf '%s' 'shellkit upgrade：指纹比对 + 渲染 + 逐文件原子替换 + vendor 库（建工程的时间不计入）'
      ;;
    test_suite)
      printf '%s' 'bash tests/run.sh：整套测试的墙钟时间（只计时，不代替它跑）'
      ;;
    *) printf '%s' '' ;;
  esac
}

# ---------------------------------------------------------------------------
# profile 模式：不计时，数被测进程内部的热点
#
# 为什么用 xtrace：bash 自带的 set -x 能把被测进程执行过的每条命令吐到
# stderr —— 不给产品代码插桩、不需要 root、macOS 与 Linux 同一套判据
# （strace/dtruss 要 root 或被 SIP 挡，跨平台门禁不能建在它上面）。
# 代价是 xtrace 本身有开销，所以 profile **不产出耗时数字**，只产计数；
# 耗时仍归 --runs 的干净测量管。两件事分开跑，互不污染。
#
# 统计口径：
#   trace_lines     非空 trace 行数（规模感，不参与判定）
#   external_total  非内建、非下划线开头的命令词次数（fork 候选，见下）
#   internal_calls  下划线开头的库内私有函数调用次数（同进程零 fork，单列）
#   source_count    source / . 的次数 —— 模块加载成本的直接线索
#   file_refs_total 命令行里「像文件路径」的 token 出现总次数（启发式，见下）
#   top_commands    fork 候选命令的频次 top 15
#   repeated_files  出现 ≥2 次的文件 token top 15（重复读盘候选）
#
# xtrace 分不清 bash 函数调用与外部命令（都是一行 + name args）：下划线开头
# 按本仓库约定归 internal_calls（私有函数同进程执行、零 fork），不带下划线的
# 公共函数（log_info 之类）仍可能留在 top_commands 里 —— 报告是给人复核的
# 线索，不是精确 fork 计数。
#
# 文件 token 是启发式提取：整体落在 [A-Za-z0-9_./-]、且是路径或带常见
# 扩展名才算 —— 宁可漏报，也不把 "foo];" 这种 shell 语法残渣算成文件。
# 报告是给人复核的线索，不是精确 syscall 记录。
#
# 范围：只统计主进程 + 它自己的命令替换子 shell；被测命令另外 fork 的
# 独立 bash 进程（如 vendor 副本）不继承 xtrace，不在统计内。
# test_suite 不做 profile：整套测试的 trace 有几十万行，且「哪条路径有
# 热点」只有按路径拆开才有意义 —— 跳过并出声。
# ---------------------------------------------------------------------------

PROFILE_PATHS=()
PROFILE_TRACES=()
PROFILE_STATUS=()

# _push_profile PATH TRACE STATUS —— 记一条 profile 结果（TRACE 为空 = 没跑成）
_push_profile() {
  PROFILE_PATHS[${#PROFILE_PATHS[@]}]=$1
  PROFILE_TRACES[${#PROFILE_TRACES[@]}]=$2
  PROFILE_STATUS[${#PROFILE_STATUS[@]}]=$3
}

# _profile_one PATH —— 跑一遍带 xtrace 的被测命令，trace 落盘
#
# 与计时路径共用同一套 _prep_/_run_（只是给被测 bash 多个 -x），
# 保证 profile 数的和 --runs 量的是同一条路。
_profile_one() {
  local __p=$1 __trace __rc=0
  __trace="$WORK/trace-$__p.txt"
  if ! "_prep_$__p" "$__p" prof >"$WORK/prep-$__p-prof.txt" 2>&1; then
    log "profile $__p: preparation failed"
    _log_tail "$WORK/prep-$__p-prof.txt" 20
    _push_profile "$__p" "" failed
    return 1
  fi
  __xtrace="-x"
  "_run_$__p" "$__p" prof >"$WORK/run-$__p-prof.txt" 2>"$__trace"
  __rc=$?
  __xtrace=""
  if [ "$__rc" -ne 0 ]; then
    log "profile $__p: run failed (rc=$__rc)"
    _log_tail "$WORK/run-$__p-prof.txt" 10
    _push_profile "$__p" "$__trace" failed
    return 1
  fi
  _push_profile "$__p" "$__trace" ok
  return 0
}

# _profile_awk PATH TRACE STATUS MODE —— 解析 trace，按 MODE=json|text 输出片段
#
# TRACE 不存在按空输入处理（prep 失败的路径也走这里，出全 0 的统一结构，
# 消费者不用判两种形态）。awk 内做插入排序：BWK awk（macOS）没有 asort。
_profile_awk() {
  local __p=$1 __trace=$2 __st=$3 __mode=$4
  [ -f "$__trace" ] || : >"$__trace"
  awk -v path="$__p" -v status="$__st" -v mode="$__mode" '
  BEGIN {
    n = split("if then else elif fi for while until do done case esac in function select time coproc " \
              ". : [ [[ ]] alias break builtin caller cd command continue declare dirs disown " \
              "echo enable eval exec exit export false fc fg getopts hash help history jobs kill let " \
              "local logout popd printf pushd pwd read readonly return set shift shopt source suspend " \
              "test times trap true type ulimit umask unalias unset wait", K, " ")
    for (i = 1; i <= n; i++) B[K[i]] = 1
    TOP = 15
  }
  {
    line = $0
    while (substr(line, 1, 1) == "+") line = substr(line, 2)
    if (substr(line, 1, 1) == " ") line = substr(line, 2)
    if (line == "") next
    total++
    sp = index(line, " ")
    if (sp == 0) { cmd = line; rest = "" }
    else { cmd = substr(line, 1, sp - 1); rest = substr(line, sp + 1) }
    # xtrace 会把保留词加引号显示（左方括号前后各带一个单引号字符）——
    # 先去掉命令词外侧的单引号再查内建表
    gsub(/\047/, "", cmd)
    if (cmd == "") next
    # 赋值整行跳过（含数组下标赋值与 FOO=bar cmd 前置赋值）：按空格切词会把
    # 引号赋值里的内容当成下一个命令，那是解析残渣不是被执行的命令。
    # 代价是 FOO=1 cmd 这种前置赋值行不计数 —— 库代码里几乎没有，
    # 漏报比把残渣算成 fork 大户强。
    if (cmd ~ /=/) next
    # 文件提取对每一行都做（放在内建判定之前）：source 行的目标文件正是
    # 重复读盘统计的最大头，按命令分类跳过会把它整个漏掉。
    m = split(rest, W, /[ \t]+/)
    for (i = 1; i <= m; i++) {
      t = W[i]
      gsub(/\047/, "", t)
      gsub(/"/, "", t)
      if (t == "" || substr(t, 1, 1) == "-") continue
      if (t !~ /^[A-Za-z0-9_.\/-]+$/) continue
      if (t ~ /\// || t ~ /\.(sh|txt|md|json|awk|in|yml|yaml|conf|po|pot|css|js|svg|html|list)$/) {
        files[t]++
        file_total++
      }
    }
    if (cmd in B) { if (cmd == "." || cmd == "source") src++; next }
    # 下划线开头按本仓库约定归为库内私有函数调用：同进程执行、零 fork，
    # 混进 external 会把 _sk_mod_index 这种每模块都调的函数顶成假的 fork 大户。
    # 不带下划线的公共函数（log_info 之类）xtrace 分不清，仍会留在
    # top_commands 里 —— 报告是给人复核的线索，不是精确 fork 计数。
    if (substr(cmd, 1, 1) == "_") { internal++; next }
    ext[cmd]++
    ext_total++
  }
  END {
    ne = 0
    for (k in ext) E[++ne] = k
    for (i = 2; i <= ne; i++) {
      v = E[i]; j = i - 1
      while (j >= 1 && ext[E[j]] < ext[v]) { E[j + 1] = E[j]; j-- }
      E[j + 1] = v
    }
    nf = 0
    for (k in files) if (files[k] >= 2) F[++nf] = k
    for (i = 2; i <= nf; i++) {
      v = F[i]; j = i - 1
      while (j >= 1 && files[F[j]] < files[v]) { F[j + 1] = F[j]; j-- }
      F[j + 1] = v
    }
    te = ne; if (te > TOP) te = TOP
    tf = nf; if (tf > TOP) tf = TOP
    if (mode == "json") {
      printf "{\"path\": \"%s\", \"status\": \"%s\", \"trace_lines\": %d, ", path, status, total
      printf "\"external_total\": %d, \"internal_calls\": %d, \"source_count\": %d, ", ext_total, internal, src
      printf "\"file_refs_total\": %d, ", file_total
      printf "\"top_commands\": ["
      for (i = 1; i <= te; i++) printf "%s{\"cmd\": \"%s\", \"count\": %d}", (i > 1 ? ", " : ""), E[i], ext[E[i]]
      printf "], \"repeated_files\": ["
      for (i = 1; i <= tf; i++) printf "%s{\"file\": \"%s\", \"count\": %d}", (i > 1 ? ", " : ""), F[i], files[F[i]]
      printf "]}"
    } else {
      printf "profile %s: status=%s trace_lines=%d external=%d internal=%d source=%d file_refs=%d\n", \
        path, status, total, ext_total, internal, src, file_total
      printf "  top commands:\n"
      if (te == 0) printf "    (none)\n"
      for (i = 1; i <= te; i++) printf "    %-24s %6d\n", E[i], ext[E[i]]
      printf "  repeated files (>=2):\n"
      if (tf == 0) printf "    (none)\n"
      for (i = 1; i <= tf; i++) printf "    %-44s %6d\n", F[i], files[F[i]]
    }
  }' "$__trace"
}

# ---------------------------------------------------------------------------
# 测量
# ---------------------------------------------------------------------------

_log_tail() {
  local __f=${1:-} __n=${2:-20}
  [ -f "$__f" ] || return 0
  printf -- '--- last %s lines of %s ---\n' "$__n" "$__f" >&2
  tail -n "$__n" "$__f" >&2
  printf -- '--- end ---\n' >&2
  return 0
}

RESULT_PATHS=()
RESULT_MEDIAN=()
RESULT_MIN=()
RESULT_MAX=()
RESULT_STATUS=()

# _push_result PATH MEDIAN MIN MAX STATUS —— 记一条结果
_push_result() {
  RESULT_PATHS[${#RESULT_PATHS[@]}]=$1
  RESULT_MEDIAN[${#RESULT_MEDIAN[@]}]=$2
  RESULT_MIN[${#RESULT_MIN[@]}]=$3
  RESULT_MAX[${#RESULT_MAX[@]}]=$4
  RESULT_STATUS[${#RESULT_STATUS[@]}]=$5
  return 0
}

# _measure PATH —— 跑一条路径；成功记下中位数等，失败返回 1
#
# 一次失败重试 RETRIES 次（默认不重试）：套件偶发抖动不该作废整次基准。
# 重试时**准备阶段也重做** —— upgrade 跑失败后工程已经是半升级状态，
# 拿它再量一次，量到的是「无事可做」的快路径，不是被测的那条路。
_measure() {
  local __path=$1
  local __i=1 __attempt=0 __ok=0 __start __end __dur
  # 失败要分两种（issue #75）：test_suite 路径的失败是**被测功能不通过**，
  # 其余路径的失败才是**性能采集本身没测出来**。混成一个 failed，报告里
  # 就会把「功能挂了」读成「性能回归」—— 而功能已经有单独的 test job 在报。
  local __fail_status=failed
  if [ "$__path" = "test_suite" ]; then
    __fail_status=func-failed
  fi
  local __file="$WORK/dur-$__path.txt" __log="$WORK/log-$__path.txt" __prep="$WORK/prep-$__path.txt"
  : >"$__file"
  while [ "$__i" -le "$RUNS" ]; do
    __attempt=0
    __ok=0
    while [ "$__attempt" -le "$RETRIES" ]; do
      __attempt=$((__attempt + 1))
      if ! "_prep_$__path" "$__path" "$__i" >"$__prep" 2>&1; then
        log "path $__path: preparation failed (run $__i, attempt $__attempt)"
        _log_tail "$__prep" 20
        _push_result "$__path" 0 0 0 "$__fail_status"
        return 1
      fi
      __start=$(_now)
      if "_run_$__path" "$__path" "$__i" >"$__log" 2>&1; then
        __ok=1
      else
        log "path $__path: run $__i failed (attempt $__attempt)"
        _log_tail "$__log" 10
      fi
      __end=$(_now)
      if [ "$__ok" = "1" ]; then
        __dur=$(_elapsed "$__start" "$__end")
        if ! _is_num "$__dur"; then
          log "path $__path: cannot read the clock (start=$__start end=$__end)"
          _push_result "$__path" 0 0 0 "$__fail_status"
          return 1
        fi
        printf '%s\n' "$__dur" >>"$__file"
        break
      fi
    done
    if [ "$__ok" != "1" ]; then
      _push_result "$__path" 0 0 0 "$__fail_status"
      return 1
    fi
    __i=$((__i + 1))
  done

  local __med __mn __mx
  __med=$(_median "$__file")
  __mn=$(sort -n "$__file" | awk 'NR == 1 { print $1 }')
  __mx=$(sort -n "$__file" | awk 'END { print $1 }')
  _push_result "$__path" "$__med" "$__mn" "$__mx" ok
  log "path $__path: median ${__med}s over $RUNS run(s)"
  return 0
}

# ---------------------------------------------------------------------------
# 基线文件
#
# 格式：<路径> TAB <基线秒> TAB <浮动比例> TAB # <口径说明>
#
# 基线口径取**多次实测的最小值**，不是中位数：
# 机器上的干扰（别的进程、热节流、容器抢 CPU）只会让程序变慢，不会让它变快，
# 所以「最快的一次」最接近这套代码在空闲时的真实成本。拿中位数当基线，
# 等于把当时的负载固化进基线 —— 之后每次量都显得「变快了」，回归反而看不出来。
# 中位数照旧出现在 JSON 与 summary 里（那是「典型耗时」），但判定用最小值。
# ---------------------------------------------------------------------------

# _baseline_row PATH —— 从基线文件里取一行，输出 "<基线秒> <浮动>"
_baseline_row() {
  local __p=$1 __line __f1 __f2 __f3
  [ -f "$BASELINE" ] || return 1
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
  done <"$BASELINE"
  return 1
}

# _load_avg —— 1 分钟负载均值（写进基线文件：这个数是在什么条件下量的）
#
# macOS 没有 /proc/loadavg，走 sysctl；两个平台都取不到就写 unknown。
_load_avg() {
  local __v=""
  if [ -r /proc/loadavg ]; then
    __v=$(awk '{ print $1 }' /proc/loadavg 2>/dev/null)
  else
    __v=$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{ print $1 }')
  fi
  printf '%s' "${__v:-unknown}"
}

# _result_index PATH —— 这条路径在本次结果里的下标；本次没测到返回 1
_result_index() {
  local __p=$1 __i=0
  while [ "$__i" -lt "${#RESULT_PATHS[@]}" ]; do
    if [ "${RESULT_PATHS[$__i]}" = "$__p" ]; then
      printf '%s' "$__i"
      return 0
    fi
    __i=$((__i + 1))
  done
  return 1
}

# _baseline_line FILE PATH —— 基线文件里这条路径的原始行（分批测时合并写回用）
#
# FILE 是显式传进来的：写基线时目标文件已经被重定向截断了，
# 只能从写之前另存的那份里读 —— 直接读目标文件永远读到空。
_baseline_line() {
  local __f=$1 __p=$2 __line
  [ -f "$__f" ] || return 1
  while IFS= read -r __line || [ -n "$__line" ]; do
    case "$__line" in
      '' | '#'*) continue ;;
    esac
    case "${__line%%$'\t'*}" in
      "$__p")
        printf '%s\n' "$__line"
        return 0
        ;;
    esac
  done <"$__f"
  return 1
}

# _write_baseline OLDFILE —— 按本次实测重写基线文件
#
# 只重写本次测到的路径；没测到的保留 OLDFILE 里的旧行 —— 分批测（比如把最慢的
# 套件路径单独跑一轮）不能把别的路径从基线里抹掉。
_write_baseline() {
  local __oldf=$1 __p __i __old
  printf '%s\n' '# shellkit 性能基线 —— 由 bash tools/bench.sh --write-baseline 生成'
  printf '%s\n' '#'
  printf '%s\n' '# 格式：<路径> TAB <基线秒> TAB <允许浮动比例> TAB # <口径说明>'
  printf '%s\n' '# 基线取的是**多次实测的最小值**：机器上的干扰只会让程序变慢，'
  printf '%s\n' '# 最快的一次最接近空闲时的真实成本（拿中位数当基线 = 把当时的负载'
  printf '%s\n' '# 固化进基线，之后每次量都显得「变快了」，回归反而看不出来）。'
  printf '%s\n' '# 中位数在 JSON / summary 里照旧给出（那是「典型耗时」）。'
  printf '%s\n' '# 判定：本次实测的最小值必须落在 [基线 × (1 - 浮动), 基线 × (1 + 浮动)] 内，'
  printf '%s\n' '#       否则判为回归（bash tools/bench.sh --check 退出码 1）。'
  printf '%s\n' '# 数值必须真跑出来，不许手编：每条路径跑 N 次，单次噪音不进基线。'
  printf '%s\n' '# 计时用 python3/perl 的浮点墙上时钟（macOS 的 date 没有 %N）；'
  printf '%s\n' '# 建工程（new / upgrade）的时间不计入被测路径。'
  printf '%s\n' '#'
  printf '%s\n' "# 测量环境：bash ${BASH_VERSION} / $(uname -sm) / load $(_load_avg) / $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf '%s\n' '# 换一台机器重测，这个数会变 —— 基线只在同一台机器同一环境里可比。'
  printf '%s\n' '# band 同理只在**负载相当**时有意义（load 记在上一行）：拿 load 40 下量的基线'
  printf '%s\n' '# 去判一台空闲机器，只会得到「快得离谱」的假回归 —— 那种情况先重写基线再谈回归。'
  for __p in $ALL_PATHS; do
    if __i=$(_result_index "$__p"); then
      printf '%s\t%s\t%s\t# %s\n' "$__p" "${RESULT_MIN[$__i]}" "$TOLERANCE" "$(_path_desc "$__p")"
    elif __old=$(_baseline_line "$__oldf" "$__p"); then
      printf '%s\n' "$__old"
    fi
  done
  return 0
}

# _write_summary FILE —— 写一份 markdown 报告（CI 的 job summary 用）
#
# 比基线快/慢多少必须写出来：光给一个绝对秒数，读者不知道该拿它跟什么比。
# 基线缺失时那一列留「-」，不猜。
_write_summary() {
  local __f=$1 __i __p __m __mn __b __row __delta __t __v
  local __any_func=0
  {
    printf '### shellkit 性能基准

'
    printf '共享 runner 的波动很大，本报告只看趋势，**不阻断合并**。

'
    printf '| 路径 | 中位数(s) | 最小(s) | 最大(s) | 次数 | 基线(s) | 相对基线 | 判定 | 状态 |
'
    printf '|---|---|---|---|---|---|---|---|---|
'
    __i=0
    while [ "$__i" -lt "${#RESULT_PATHS[@]}" ]; do
      __p=${RESULT_PATHS[$__i]}
      __m=${RESULT_MEDIAN[$__i]}
      __mn=${RESULT_MIN[$__i]}
      __b="-"
      __delta="-"
      __v="-"
      if [ -f "$BASELINE" ] && __row=$(_baseline_row "$__p"); then
        __b=${__row%% *}
        __t=${__row##* }
        # 相对基线按最小值算：基线是最小值口径，判定也比最小值 —— 报告跟判定同口径。
        if _is_num "$__b" && _is_num "$__mn"; then
          __delta=$(awk -v m="$__mn" -v b="$__b" 'BEGIN {
            if (b <= 0) { print "-" } else { printf "%+.1f%%", (m - b) * 100 / b }
          }')
        fi
        # 判定列与 --check 是同一条判据（最小值落在 [基线 × (1±浮动)] 内即 in band），
        # 而且**不依赖 --check 有没有传** —— CI 那条只给 --summary，报告里
        # 只有「慢了多少」没有「这算不算回归」，读者还得自己翻基线文件对一遍。
        if _is_num "$__b" && _is_num "$__t" && _is_num "$__mn"; then
          __v=$(awk -v m="$__mn" -v b="$__b" -v t="$__t" 'BEGIN {
            lo = b * (1 - t); hi = b * (1 + t)
            if (m < lo || m > hi) { print "out band" } else { print "in band" }
          }')
        fi
      fi
      printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s |
' \
        "$__p" "$__m" "${RESULT_MIN[$__i]}" "${RESULT_MAX[$__i]}" "$RUNS" \
        "$__b" "$__delta" "$__v" "${RESULT_STATUS[$__i]}"
      if [ "${RESULT_STATUS[$__i]}" = "func-failed" ]; then
        __any_func=1
      fi
      __i=$((__i + 1))
    done
    printf '
口径：每条路径跑 %s 次；中位数是典型耗时，**基线 / 相对基线 / 判定都取最小值**（干扰只会让程序变慢，最小值最接近空闲成本）；判定 = 最小值是否落在**基线文件里该路径自己的浮动比例**区间内，与 --check 同一条判据（写基线时的缺省浮动比例 ±%s）。
' "$RUNS" "$TOLERANCE"
    if [ "$__any_func" = "1" ]; then
      printf '
> ⚠️ test_suite 的失败是**被测功能不通过**，不是性能回归 —— 看 test job 的日志；本 Job 只负责性能指标（issue #75）。
'
    fi
  } >"$__f"
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

_detect_clock
log "clock: $_CLOCK, runs: $RUNS"

# ---------------------------------------------------------------------------
# profile 分支：跳过计时，出热点统计后直接退出
# ---------------------------------------------------------------------------
if [ "$PROFILE" = "1" ]; then
  __pf_failed=0
  for __p in $SELECTED; do
    if [ "$__p" = "test_suite" ]; then
      log "profile: skipping test_suite (a whole-suite trace is hundreds of thousands of lines; profile each product path instead)"
      _push_profile test_suite "" skipped
      continue
    fi
    if ! _profile_one "$__p"; then
      __pf_failed=1
    fi
  done
  if [ "$JSON" = "1" ]; then
    printf '{\n'
    printf '  "schema": "shellkit.bench.profile.v1",\n'
    printf '  "root": "%s",\n' "$ROOT"
    printf '  "results": [\n'
    __i=0
    while [ "$__i" -lt "${#PROFILE_PATHS[@]}" ]; do
      __sep=","
      [ "$__i" -lt "$((${#PROFILE_PATHS[@]} - 1))" ] || __sep=""
      _profile_awk "${PROFILE_PATHS[$__i]}" "${PROFILE_TRACES[$__i]}" \
        "${PROFILE_STATUS[$__i]}" json
      printf '%s\n' "$__sep"
      __i=$((__i + 1))
    done
    printf '  ]\n'
    printf '}\n'
  else
    __i=0
    while [ "$__i" -lt "${#PROFILE_PATHS[@]}" ]; do
      _profile_awk "${PROFILE_PATHS[$__i]}" "${PROFILE_TRACES[$__i]}" \
        "${PROFILE_STATUS[$__i]}" text
      __i=$((__i + 1))
    done
  fi
  exit "$__pf_failed"
fi

FAILED=0
for __p in $SELECTED; do
  if [ "$__p" = "test_suite" ] && [ "${SHELLKIT_BENCH_CHILD:-0}" = "1" ] && [ "$SUITE_CMD" = "$DEFAULT_SUITE_CMD" ]; then
    log "skipping the test_suite path: this run is inside the suite (SHELLKIT_BENCH_CHILD=1)"
    continue
  fi
  if ! _measure "$__p"; then
    FAILED=1
  fi
done

if [ "$FAILED" -ne 0 ]; then
  log "at least one path failed to measure"
fi

# --check：跟基线比
if [ "$CHECK" = "1" ] && [ "$FAILED" -eq 0 ]; then
  if [ ! -f "$BASELINE" ]; then
    log "baseline file not found: $BASELINE"
    exit 1
  fi
  __i=0
  while [ "$__i" -lt "${#RESULT_PATHS[@]}" ]; do
    __p=${RESULT_PATHS[$__i]}
    # 判定用最小值：基线也是最小值口径，两边都是「最快的一次」——
    # 机器上的干扰不会把最快的一次拖慢太多，而中位数会（负载一起变慢）。
    __m=${RESULT_MIN[$__i]}
    if ! __row=$(_baseline_row "$__p"); then
      log "baseline has no entry for $__p"
      exit 1
    fi
    __b=${__row%% *}
    __t=${__row##* }
    if ! _is_num "$__b" || ! _is_num "$__t"; then
      log "baseline entry for $__p is not numeric: median=$__b tolerance=$__t"
      exit 1
    fi
    __v=$(awk -v m="$__m" -v b="$__b" -v t="$__t" 'BEGIN {
      lo = b * (1 - t)
      hi = b * (1 + t)
      if (m < lo || m > hi) { print "out" } else { print "in" }
    }')
    if [ "$__v" = "out" ]; then
      log "$__p: ${__m}s (fastest of $RUNS) is outside the baseline band (${__b}s ±${__t})"
      FAILED=1
    else
      log "$__p: ${__m}s (fastest of $RUNS) is inside the baseline band (${__b}s ±${__t})"
    fi
    __i=$((__i + 1))
  done
fi

# 输出
if [ "$WRITE" = "1" ]; then
  if [ "$FAILED" -ne 0 ]; then
    log "refusing to write the baseline from a failed run"
    exit 1
  fi
  # 先把旧基线另存：> "$BASELINE" 的重定向会先把目标截断，
  # 不另存的话分批测时读不到别的路径的旧行（合并就变成了覆盖）。
  __old_base="$WORK/base-old.txt"
  if [ -f "$BASELINE" ]; then
    cp "$BASELINE" "$__old_base" 2>/dev/null || : >"$__old_base"
  else
    : >"$__old_base"
  fi
  _write_baseline "$__old_base" >"$BASELINE" || {
    log "cannot write the baseline file: $BASELINE"
    exit 1
  }
  log "baseline written: $BASELINE"
fi

if [ "$JSON" = "1" ]; then
  printf '{\n'
  printf '  "schema": "shellkit.bench.v1",\n'
  printf '  "runs": %s,\n' "$RUNS"
  printf '  "clock": "%s",\n' "$_CLOCK"
  printf '  "tolerance": %s,\n' "$TOLERANCE"
  printf '  "status": "%s",\n' "$([ "$FAILED" -eq 0 ] && printf 'ok' || printf 'failed')"
  printf '  "results": [\n'
  __i=0
  while [ "$__i" -lt "${#RESULT_PATHS[@]}" ]; do
    __sep=","
    [ "$__i" -lt "$((${#RESULT_PATHS[@]} - 1))" ] || __sep=""
    printf '    {"path": "%s", "median": %s, "min": %s, "max": %s, "runs": %s, "status": "%s"}%s\n' \
      "${RESULT_PATHS[$__i]}" "${RESULT_MEDIAN[$__i]}" "${RESULT_MIN[$__i]}" "${RESULT_MAX[$__i]}" "$RUNS" \
      "${RESULT_STATUS[$__i]}" "$__sep"
    __i=$((__i + 1))
  done
  printf '  ]\n'
  printf '}\n'
else
  printf '%-16s %12s %12s %12s %6s\n' "path" "median(s)" "min(s)" "max(s)" "runs"
  __i=0
  while [ "$__i" -lt "${#RESULT_PATHS[@]}" ]; do
    printf '%-16s %12s %12s %12s %6s\n' \
      "${RESULT_PATHS[$__i]}" "${RESULT_MEDIAN[$__i]}" "${RESULT_MIN[$__i]}" "${RESULT_MAX[$__i]}" "$RUNS"
    __i=$((__i + 1))
  done
fi

if [ -n "$SUMMARY" ]; then
  _write_summary "$SUMMARY" || {
    log "cannot write the summary file: $SUMMARY"
    exit 1
  }
  log "summary written: $SUMMARY"
fi

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi
exit 0
