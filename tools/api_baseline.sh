#!/usr/bin/env bash
#
# 公开 API 行为基线门禁。
#
# 为什么要有这道门：仓库里承诺过「改了既有函数的结果（返回码、产出文件名、
# 输出文本）就要升 minor 并在 docs/MIGRATING.md 写迁移说明」—— 但那句话靠自觉，
# 没有机器判据。于是「改了返回码、没写迁移说明」能一路合进去：调用方升级后
# 拿到的是另一个退出码，文档里却只字未提。
#
# 这道门把它变成机器判据，三条互相独立的网：
#
#   1. **基线对账**：tools/api_baseline.txt 记着每个公开函数**承诺的返回码集合**，
#      唯一真相源是源码注释里的 @exitcode 行（不是手抄的第二份清单）。
#      基线与源码对不上（改了承诺、删了函数、加了新函数）就红。
#
#   2. **变更必须声明**：承诺变了 / 函数被删了 ⇒ 必须写进 docs/MIGRATING.md 的
#      「会改变结果的行为变化」表格，否则红。声明的判据写在 _sk_ab_scan_migrating 上：
#      只认「会改变结果的行为变化」小节、只认表格行里以反引号出现的函数名、
#      且该小节的目标版本必须新于这个函数上一次被声明的版本。
#      声明记在基线里（declared=版本号）⇒ 这道门在**已提交的状态**上也能查，
#      CI 里不需要比较历史 —— 手改基线也躲不过（门禁会回查 MIGRATING）。
#
#   3. **探针**：被探针覆盖的公开函数在沙箱里真调一遍，实际退出码必须与基线
#      里断言的一致，且断言的码必须落在 @exitcode 承诺集合内。
#
# 用法：
#   bash tools/api_baseline.sh                  # 门禁检查（0 绿 / 5 红）
#   bash tools/api_baseline.sh --write-baseline # 重生成基线
#
# 退出码：0 通过 / 2 用法错 / 3 前置条件不满足 / 5 校验失败（门禁红）。
set -u

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)/$(basename "${BASH_SOURCE[0]}")"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"
MODE=check
PROBE_WORKER=0
PROBE_FILE=""
PROBE_DIR=""
PROBE_FILTER=""

while [ $# -gt 0 ]; do
  case "$1" in
    --write-baseline)
      MODE="write"
      ;;
    --root)
      if [ $# -lt 2 ]; then
        printf 'api_baseline: --root needs a directory\n' >&2
        exit 2
      fi
      shift
      ROOT=$1
      ;;
    --probes)
      if [ $# -lt 2 ]; then
        printf 'api_baseline: --probes needs a list of function names\n' >&2
        exit 2
      fi
      shift
      PROBE_FILTER=$1
      ;;
    --probe-worker)
      if [ $# -lt 3 ]; then
        printf 'api_baseline: --probe-worker needs FILE and DIR\n' >&2
        exit 2
      fi
      shift
      PROBE_WORKER=1
      PROBE_FILE=$1
      shift
      PROBE_DIR=$1
      ;;
    -h | --help)
      printf 'usage: bash tools/api_baseline.sh [--write-baseline] [--root DIR] [--probes NAME[,NAME...]]\n'
      exit 0
      ;;
    *)
      printf 'api_baseline: unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
  shift
done

_SK_AB_ROOT_ABS="$(cd "$ROOT" 2>/dev/null && pwd)" || {
  printf 'api_baseline: cannot enter the root directory: %s\n' "$ROOT" >&2
  exit 3
}
ROOT="$_SK_AB_ROOT_ABS"
LIB_DIR="$ROOT/lib/core"
BASELINE="$ROOT/tools/api_baseline.txt"
MIGRATING="$ROOT/docs/MIGRATING.md"
VERSION_FILE="$ROOT/VERSION"

_sk_ab_log() { printf 'api_baseline: %s\n' "$*" >&2; }

_sk_ab_die() {
  _sk_ab_log "$1"
  exit "${2:-5}"
}

# ---------------------------------------------------------------------------
# 版本号：规范化成可比较的整数键
# ---------------------------------------------------------------------------

# _sk_ab_ver_key VERSION —— 版本号折成一个整数键（0.17.0 -> 17000）
_sk_ab_ver_key() {
  local v="${1:-}" major minor patch
  v=${v#v}
  v=${v#V}
  v=$(printf '%s' "$v" | tr -cd '0-9.')
  local -a parts
  IFS=. read -r -a parts <<EOF
$v
EOF
  major=${parts[0]:-0}
  minor=${parts[1]:-0}
  patch=${parts[2]:-0}
  [ -n "$major" ] || major=0
  [ -n "$minor" ] || minor=0
  [ -n "$patch" ] || patch=0
  major=$((10#$major))
  minor=$((10#$minor))
  patch=$((10#$patch))
  printf '%s' "$((major * 1000000 + minor * 1000 + patch))"
}

# ---------------------------------------------------------------------------
# 源码扫描：公开函数 + 它们承诺的返回码
# ---------------------------------------------------------------------------

_SK_AB_SRC_NAMES=()
_SK_AB_SRC_CODES=()
_SK_AB_SRC_STAB=() # 分级：stable | experimental（缺省按 experimental，见 issue #79）

# _sk_ab_scan_source —— 扫 lib/core/*.sh，输出「名字<TAB>承诺返回码」
# 取法与 tools/check_exitcode_docs.sh 同源：函数定义行匹配 ^name()，
# 下划线开头视为私有；注释块必须紧邻（中间有空行就当没有）。
_sk_ab_scan_source() {
  local f
  for f in "$LIB_DIR"/*.sh; do
    [ -f "$f" ] || continue
    awk '
      /^[A-Za-z_][A-Za-z0-9_]*\(\)/ {
        fname = $0
        sub(/\(.*/, "", fname)
        if (fname ~ /^_/) { want = 0 } else { want = 1 }
        blk = ""
        if (prev ~ /^#/) {
          blk = prev
          for (i = NR - 2; i >= 1; i--) {
            if (lines[i] ~ /^#/) { blk = lines[i] "\n" blk }
            else { break }
          }
        }
        if (want == 1) {
          codes = ""
          stab = ""
          n = split(blk, L, "\n")
          for (j = 1; j <= n; j++) {
            if (L[j] ~ /@exitcode[ \t]+/) {
              rest = L[j]
              sub(/^[^@]*@exitcode[ \t]+/, "", rest)
              split(rest, W, /[ \t]+/)
              c = W[1]
              if (c != "" && index("," codes, "," c ",") == 0) {
                codes = (codes == "" ? c : codes "," c)
              }
            }
            if (L[j] ~ /@stability[ \t]+/) {
              rest = L[j]
              sub(/^[^@]*@stability[ \t]+/, "", rest)
              split(rest, W, /[ \t]+/)
              stab = W[1]
            }
          }
          printf "%s\t%s\t%s\n", fname, codes, stab
        }
        want = 0
        next
      }
      { lines[NR] = $0; prev = $0 }
    ' "$f"
  done
}

# _sk_ab_codes_norm CODES —— 返回码集合规范化（去重 + 排序），保证逐字可比
# 数字码按数值升序；非数字的码（源码里只有「其他」一个）排在最后。
# 纯 bash 实现：这道门每个函数都要比一次集合，fork 一次 tr/sort/paste 就是几百个
# 进程 —— 在慢机器上光这一项就要十几秒。
_sk_ab_codes_norm() {
  local codes="${1:-}" out="" c
  local -a nums=() others=()
  local old_ifs=$IFS
  IFS=,
  for c in $codes; do
    [ -n "$c" ] || continue
    case ",$out," in
      *",$c,"*) ;;
      *) out="${out:+$out,}$c" ;;
    esac
  done
  IFS=,
  for c in $out; do
    [ -n "$c" ] || continue
    case "$c" in
      '' | *[!0-9]*) others[${#others[@]}]=$c ;;
      *) nums[${#nums[@]}]=$c ;;
    esac
  done
  IFS=$old_ifs
  local i j key
  i=1
  while [ "$i" -lt "${#nums[@]}" ]; do
    key=${nums[$i]}
    j=$((i - 1))
    while [ "$j" -ge 0 ] && [ "$((10#${nums[$j]}))" -gt "$((10#$key))" ]; do
      nums[$((j + 1))]=${nums[$j]}
      j=$((j - 1))
    done
    nums[$((j + 1))]=$key
    i=$((i + 1))
  done
  out=""
  for c in ${nums[@]+"${nums[@]}"}; do
    out="${out:+$out,}$c"
  done
  for c in ${others[@]+"${others[@]}"}; do
    out="${out:+$out,}$c"
  done
  printf '%s' "$out"
}

_sk_ab_src_index() {
  local want=$1 i=0
  while [ "$i" -lt "${#_SK_AB_SRC_NAMES[@]}" ]; do
    if [ "${_SK_AB_SRC_NAMES[$i]}" = "$want" ]; then
      printf '%s' "$i"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# ---------------------------------------------------------------------------
# MIGRATING 扫描：行为变化小节里声明过的函数
# ---------------------------------------------------------------------------

_SK_AB_DECL_VER=()
_SK_AB_DECL_NAME=()

# _sk_ab_scan_migrating —— 输出「目标版本<TAB>函数名」，每行一条声明
#
# 判据（这就是「行为变更必须显式声明」的匹配口径）：
#   * 只认标题里含「会改变结果的行为变化」的小节 —— 「不改变结果的改进/修复」
#     小节不算声明（那里讲的是没有行为变化的改动）。
#   * 只认**表格行**（以 | 开头的行）里以反引号出现的函数名 —— 正文里随口提一句
#     函数名不算声明；反引号里必须是**整个**函数名（conf_get 命中，
#     conf_get_any 不命中 conf_get）。
#   * 小节标题的版本区间写成「X → Y」，Y 是这次行为变化发布到的版本。
_sk_ab_scan_migrating() {
  [ -f "$MIGRATING" ] || return 0
  LC_ALL=C awk '
    /^### / {
      h = substr($0, 5)
      n = split(h, w, /[ \t]+/)
      if (n < 3 || w[2] != "→") { insec = 0; next }
      rest = w[3]
      j = index(rest, "：")
      if (j == 0) j = index(rest, ":")
      if (j > 0) { to = substr(rest, 1, j - 1); title = substr(rest, j + 1) }
      else { to = rest; title = "" }
      gsub(/^[ \t]+|[ \t]+$/, "", to)
      gsub(/^[ \t]+|[ \t]+$/, "", title)
      insec = (title ~ /会改变结果的行为变化/) ? 1 : 0
      cur_to = to
      next
    }
    insec && /^[ \t]*\|/ {
      line = $0
      while (match(line, /`[^`]+`/)) {
        tok = substr(line, RSTART + 1, RLENGTH - 2)
        print cur_to "\t" tok
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' "$MIGRATING"
}

_sk_ab_load_declarations() {
  local ver name
  while IFS=$'\t' read -r ver name; do
    [ -n "$ver" ] || continue
    [ -n "$name" ] || continue
    _SK_AB_DECL_VER[${#_SK_AB_DECL_VER[@]}]=$ver
    _SK_AB_DECL_NAME[${#_SK_AB_DECL_NAME[@]}]=$name
  done <<EOF
$(_sk_ab_scan_migrating)
EOF
}

# _sk_ab_declared NAME REF_VERSION —— 这个函数有没有在「比 REF_VERSION 新」的
# 行为变化小节里被声明过；有的话打印那个小节的目标版本（最新的那个）。
_sk_ab_declared() {
  local want=$1 ref=$2 i=0 best="" bestkey=-1 key refkey
  refkey=$(_sk_ab_ver_key "$ref")
  while [ "$i" -lt "${#_SK_AB_DECL_NAME[@]}" ]; do
    if [ "${_SK_AB_DECL_NAME[$i]}" = "$want" ]; then
      key=$(_sk_ab_ver_key "${_SK_AB_DECL_VER[$i]}")
      if [ "$key" -gt "$refkey" ] && [ "$key" -gt "$bestkey" ]; then
        bestkey=$key
        best=${_SK_AB_DECL_VER[$i]}
      fi
    fi
    i=$((i + 1))
  done
  [ -n "$best" ] || return 1
  printf '%s' "$best"
}

# _sk_ab_declared_at NAME VERSION —— 版本 VERSION 那个小节里声明了这个函数吗
_sk_ab_declared_at() {
  local want=$1 ver=$2 i=0
  while [ "$i" -lt "${#_SK_AB_DECL_NAME[@]}" ]; do
    if [ "${_SK_AB_DECL_NAME[$i]}" = "$want" ] && [ "${_SK_AB_DECL_VER[$i]}" = "$ver" ]; then
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# ---------------------------------------------------------------------------
# 基线文件
# ---------------------------------------------------------------------------

_SK_AB_BASE_NAMES=()
_SK_AB_BASE_STAB=()
_SK_AB_BASE_CODES=()
_SK_AB_BASE_STATUS=()
_SK_AB_BASE_DECLARED=()
_SK_AB_BASE_PROBE=()
_SK_AB_BASE_EXPECT=()
_SK_AB_BASE_REASON=()
_SK_AB_BASE_VERSION=""

_sk_ab_base_index() {
  local want=$1 i=0
  while [ "$i" -lt "${#_SK_AB_BASE_NAMES[@]}" ]; do
    if [ "${_SK_AB_BASE_NAMES[$i]}" = "$want" ]; then
      printf '%s' "$i"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# _sk_ab_load_baseline —— 读基线文件
_sk_ab_load_baseline() {
  local line name codes status declared probe expect reason
  while IFS= read -r line; do
    case "$line" in
      '' | '#'*) continue ;;
    esac
    case "$line" in
      baseline-version:*)
        _SK_AB_BASE_VERSION=${line#baseline-version:}
        _SK_AB_BASE_VERSION=${_SK_AB_BASE_VERSION# }
        continue
        ;;
    esac
    name=${line%%$'	'*}
    rest=${line#*$'	'}
    codes=${rest%%$'	'*}
    rest=${rest#*$'	'}
    status=${rest%%$'	'*}
    rest=${rest#*$'	'}
    declared=${rest%%$'	'*}
    rest=${rest#*$'	'}
    probe=${rest%%$'	'*}
    rest=${rest#*$'	'}
    expect=${rest%%$'	'*}
    rest=${rest#*$'	'}
    # 第 8 列是分级；老基线（7 列）没有它 —— 那时 rest 里不再有分隔符，
    # 按「无分级列」读，门禁会提示重生成，而不是把 reason 当成分级。
    case "$rest" in
      *$'	'*)
        reason=${rest%%$'	'*}
        stability=${rest#*$'	'}
        ;;
      *)
        reason=$rest
        stability=""
        ;;
    esac
    [ -n "$name" ] || continue
    _SK_AB_BASE_NAMES[${#_SK_AB_BASE_NAMES[@]}]=$name
    _SK_AB_BASE_CODES[${#_SK_AB_BASE_CODES[@]}]=$codes
    _SK_AB_BASE_STATUS[${#_SK_AB_BASE_STATUS[@]}]=$status
    _SK_AB_BASE_DECLARED[${#_SK_AB_BASE_DECLARED[@]}]=$declared
    _SK_AB_BASE_PROBE[${#_SK_AB_BASE_PROBE[@]}]=$probe
    _SK_AB_BASE_EXPECT[${#_SK_AB_BASE_EXPECT[@]}]=$expect
    _SK_AB_BASE_REASON[${#_SK_AB_BASE_REASON[@]}]=$reason
    _SK_AB_BASE_STAB[${#_SK_AB_BASE_STAB[@]}]=$stability
  done <"$BASELINE"
}

# ---------------------------------------------------------------------------
# 探针表（脚本是唯一真相源；基线里那份是投影）
# ---------------------------------------------------------------------------

# 探针片段约定：片段跑在沙箱里（cwd 是临时目录、SHELLKIT_LANG=en、
# SHELLKIT_NONINTERACTIVE=1），**退出码 0 表示全部断言成立**；
# 非 0（这里用 81/82/83…区分是哪条断言挂了）表示行为与承诺不符。
_SK_AB_P_NAME=()
_SK_AB_P_EXPECT=()
_SK_AB_P_SNIPPET=()
_SK_AB_S_NAME=()
_SK_AB_S_REASON=()

_SK_AB_EXEMPT=()

# _sk_ab_load_exempt —— 读分级豁免名单（tools/stability_exempt.txt，issue #79）
#
# 名单记录「还没有 @stability 注解的公开函数」。它必须**只许变短**：
# 老函数逐个审过才摘出去，新函数第一天就要求显式声明（坑 15 的双向棘轮）。
_sk_ab_load_exempt() {
  local __f="$ROOT/tools/stability_exempt.txt" __n
  [ -f "$__f" ] || return 0
  while IFS= read -r __n || [ -n "$__n" ]; do
    case "$__n" in
      '' | '#'*) continue ;;
    esac
    _SK_AB_EXEMPT[${#_SK_AB_EXEMPT[@]}]=$__n
  done <"$__f"
  return 0
}

# _sk_ab_exempt_index NAME —— 在豁免名单里吗（在则输出下标并返回 0）
_sk_ab_exempt_index() {
  local __i=0 __n=${1:-}
  while [ "$__i" -lt "${#_SK_AB_EXEMPT[@]}" ]; do
    if [ "${_SK_AB_EXEMPT[$__i]}" = "$__n" ]; then
      printf '%s' "$__i"
      return 0
    fi
    __i=$((__i + 1))
  done
  return 1
}

_sk_ab_load_probe_tables() {
  local name expect snippet reason
  while IFS=$'\t' read -r name expect snippet; do
    [ -n "$name" ] || continue
    _SK_AB_P_NAME[${#_SK_AB_P_NAME[@]}]=$name
    _SK_AB_P_EXPECT[${#_SK_AB_P_EXPECT[@]}]=$expect
    _SK_AB_P_SNIPPET[${#_SK_AB_P_SNIPPET[@]}]=$snippet
  done <<'SK_AB_PROBES'
str_trim	0	pv="  x  "; str_trim pv || exit 81; [ "$pv" = "x" ] || exit 82; exit 0
str_lower	0	pv="AbC"; str_lower pv || exit 81; [ "$pv" = "abc" ] || exit 82; exit 0
str_upper	0	pv="AbC"; str_upper pv || exit 81; [ "$pv" = "ABC" ] || exit 82; exit 0
str_contains	0,1	str_contains abc b || exit 81; str_contains abc z; prc=$?; [ "$prc" = 1 ] || exit 82; exit 0
str_starts_with	0,1	str_starts_with abc ab || exit 81; str_starts_with abc bc; prc=$?; [ "$prc" = 1 ] || exit 82; exit 0
str_ends_with	0,1	str_ends_with abc bc || exit 81; str_ends_with abc ab; prc=$?; [ "$prc" = 1 ] || exit 82; exit 0
str_repeat	0	pv=""; str_repeat pv 3 ab || exit 81; [ "$pv" = "ababab" ] || exit 82; exit 0
str_suggest	0,1	[ "$(str_suggest depoy deploy)" = "deploy" ] || exit 81; str_suggest depoy; prc=$?; [ "$prc" = 1 ] || exit 82; exit 0
validate_not_empty	0,1	validate_not_empty x || exit 81; validate_not_empty ""; prc=$?; [ "$prc" = 1 ] || exit 82; exit 0
validate_single_line	0,1	validate_single_line "a" || exit 81; validate_single_line "$(printf 'a\nb')"; prc=$?; [ "$prc" = 1 ] || exit 82; exit 0
validate_key	0,1	validate_key Abc_1 || exit 81; validate_key "1abc"; prc=$?; [ "$prc" = 1 ] || exit 82; exit 0
validate_port	0,1	validate_port 80 || exit 81; validate_port 99999; prc=$?; [ "$prc" = 1 ] || exit 82; exit 0
validate_ip	0,1	validate_ip 1.2.3.4 || exit 81; validate_ip 010.1.1.1; prc=$?; [ "$prc" = 1 ] || exit 82; exit 0
validate_version	0,1	validate_version 1.2.3 || exit 81; validate_version "abc"; prc=$?; [ "$prc" = 1 ] || exit 82; exit 0
validate_abs_path	0,1	validate_abs_path /a || exit 81; validate_abs_path "a"; prc=$?; [ "$prc" = 1 ] || exit 82; exit 0
validate_url	0,1	validate_url "https://a.b" || exit 81; validate_url "ftp://a"; prc=$?; [ "$prc" = 1 ] || exit 82; exit 0
validate_enum	0,1	validate_enum a "a|b" || exit 81; validate_enum c "a|b"; prc=$?; [ "$prc" = 1 ] || exit 82; exit 0
ver_cmp	0	[ "$(ver_cmp 1.0 1.0)" = "0" ] || exit 81; [ "$(ver_cmp 1.0 2.0)" = "-1" ] || exit 82; [ "$(ver_cmp 2.0 1.0)" = "1" ] || exit 83; exit 0
ver_gt	0,1,2	ver_gt 2.0 1.0 || exit 81; ver_gt 1.0 2.0; prc=$?; [ "$prc" = 1 ] || exit 82; ver_gt bad 1.0; prc=$?; [ "$prc" = 2 ] || exit 83; exit 0
ver_lt	0,1,2	ver_lt 1.0 2.0 || exit 81; ver_lt 2.0 1.0; prc=$?; [ "$prc" = 1 ] || exit 82; ver_lt bad 1.0; prc=$?; [ "$prc" = 2 ] || exit 83; exit 0
ver_eq	0,1,2	ver_eq 1.0 1.0 || exit 81; ver_eq 1.0 2.0; prc=$?; [ "$prc" = 1 ] || exit 82; ver_eq bad 1.0; prc=$?; [ "$prc" = 2 ] || exit 83; exit 0
status_is_machine	0,1	SHELLKIT_STATUS_MODE=human status_is_machine; prc=$?; [ "$prc" = 1 ] || exit 81; SHELLKIT_STATUS_MODE=machine status_is_machine; prc=$?; [ "$prc" = 0 ] || exit 82; exit 0
status_state_valid	0,1	status_state_valid installed || exit 81; status_state_valid bogus; prc=$?; [ "$prc" = 1 ] || exit 82; exit 0
status_emit	0	status_emit installed "hello" >/dev/null || exit 81; exit 0
status_version	0	status_version 1.0 >/dev/null || exit 81; exit 0
status_extra	0	status_extra "a=b" >/dev/null || exit 81; exit 0
log_info	0	log_info probe >/dev/null 2>&1 || exit 81; exit 0
log_ok	0	log_ok probe >/dev/null 2>&1 || exit 81; exit 0
log_warn	0	log_warn probe >/dev/null 2>&1 || exit 81; exit 0
log_error	0	log_error probe >/dev/null 2>&1 || exit 81; exit 0
log_debug	0	log_debug probe >/dev/null 2>&1 || exit 81; exit 0
log_section	0	log_section probe >/dev/null 2>&1 || exit 81; exit 0
fail	0,2,7	fail 7 probe >/dev/null 2>&1; prc=$?; [ "$prc" = 7 ] || exit 82; fail bad probe >/dev/null 2>&1; prc=$?; [ "$prc" = 2 ] || exit 83; exit 0
require_cmd	0,3	require_cmd sh || exit 81; require_cmd sk-no-such-cmd-here; prc=$?; [ "$prc" = 3 ] || exit 82; exit 0
require_root	0,3	require_root; prc=$?; { [ "$prc" = 0 ] || [ "$prc" = 3 ]; } || exit 81; exit 0
require_file	0,3	printf 'x' > require_file-f; require_file require_file-f || exit 81; require_file require_file-missing; prc=$?; [ "$prc" = 3 ] || exit 82; exit 0
require_bash	0,3	require_bash 3 0 || exit 81; require_bash 99 0; prc=$?; [ "$prc" = 3 ] || exit 82; exit 0
os_name	0	os_name >/dev/null || exit 81; exit 0
os_arch	0	os_arch >/dev/null || exit 81; exit 0
os_is_root	0,1	os_is_root; prc=$?; { [ "$prc" = 0 ] || [ "$prc" = 1 ]; } || exit 81; exit 0
os_has_cmd	0,1	os_has_cmd sh || exit 81; os_has_cmd sk-no-such-cmd-here; prc=$?; [ "$prc" = 1 ] || exit 82; exit 0
os_pkg_manager	0,1	os_pkg_manager >/dev/null; prc=$?; { [ "$prc" = 0 ] || [ "$prc" = 1 ]; } || exit 81; exit 0
os_pkg_manager_full	0,1	os_pkg_manager_full >/dev/null; prc=$?; { [ "$prc" = 0 ] || [ "$prc" = 1 ]; } || exit 81; exit 0
os_release_field	0	printf 'ID=probeos\n' > os_release_field-osr; [ "$(os_release_field ID os_release_field-osr)" = "probeos" ] || exit 81; os_release_field ID os_release_field-missing >/dev/null || exit 82; exit 0
os_distro_id	0	printf 'ID=ProbeOS\n' > os_distro_id-osr; [ "$(os_distro_id os_distro_id-osr)" = "probeos" ] || exit 81; exit 0
os_distro_name	0	printf 'NAME=ProbeOS\n' > os_distro_name-osr; [ "$(os_distro_name os_distro_name-osr)" = "ProbeOS" ] || exit 81; exit 0
os_distro_family	0	printf 'ID=debian\n' > os_distro_family-osr; [ "$(os_distro_family os_distro_family-osr)" = "debian" ] || exit 81; exit 0
os_desktop_env	0	os_desktop_env >/dev/null || exit 81; exit 0
os_is_desktop	0,1	os_is_desktop; prc=$?; { [ "$prc" = 0 ] || [ "$prc" = 1 ]; } || exit 81; exit 0
os_md5	0	printf 'abc' > os_md5-f; [ -n "$(os_md5 os_md5-f)" ] || exit 81; exit 0
os_sha256	0	printf 'abc' > os_sha256-f; [ -n "$(os_sha256 os_sha256-f)" ] || exit 81; exit 0
os_sed_i	0	printf 'a\n' > os_sed_i-f; os_sed_i 's/a/b/' os_sed_i-f || exit 81; grep -q b os_sed_i-f || exit 82; exit 0
net_sha256	0	printf 'abc' > net_sha256-f; [ -n "$(net_sha256 net_sha256-f)" ] || exit 81; exit 0
net_verify	0,5	printf 'abc' > net_verify-f; net_verify net_verify-f "$(net_sha256 net_verify-f)" || exit 81; net_verify net_verify-f 0000000000000000000000000000000000000000000000000000000000000000; prc=$?; [ "$prc" = 5 ] || exit 82; exit 0
net_escape_json	0	out=$(net_escape_json 'a"b') || exit 81; case "$out" in *'a\"b'*) ;; *) exit 82 ;; esac; exit 0
profile_write	0	profile_write profile_write-f || exit 81; [ -f profile_write-f ] || exit 82; exit 0
profile_append	0	profile_write profile_append-f; profile_append profile_append-f mod k=v || exit 81; [ "$(cat profile_append-f)" = "mod k=v" ] || exit 82; exit 0
profile_parse	0	profile_write profile_parse-f; profile_append profile_parse-f mod k=v; [ "$(profile_parse profile_parse-f)" = "$(printf 'mod\tk=v')" ] || exit 81; exit 0
profile_env	0	[ "$(profile_env "$(printf 'mod\tk=v')" PX)" = "PXk=v" ] || exit 81; exit 0
registry_add	0	printf 'A=1\n' > registry_add-manifest; registry_add registry_add-entry registry_add-manifest || exit 81; exit 0
registry_scan	0	mkdir -p registry_scan-dir/registry_scan-entry; printf 'A=1\n' > registry_scan-dir/registry_scan-entry/.manifest; registry_scan registry_scan-dir .manifest || exit 81; [ "$(registry_list)" = "registry_scan-entry" ] || exit 82; exit 0
registry_scan_multi	0	mkdir -p registry_scan_multi-dir/registry_scan_multi-entry; printf 'A=1\n' > registry_scan_multi-dir/registry_scan_multi-entry/.manifest; registry_scan_multi .manifest registry_scan_multi-dir || exit 81; [ "$(registry_list)" = "registry_scan_multi-entry" ] || exit 82; exit 0
registry_get	0	mkdir -p registry_get-dir/registry_get-entry; printf 'A=1\n' > registry_get-dir/registry_get-entry/.manifest; registry_scan registry_get-dir .manifest; [ "$(registry_get registry_get-entry A)" = "1" ] || exit 81; exit 0
registry_list	0	mkdir -p registry_list-dir/registry_list-entry; printf 'A=1\n' > registry_list-dir/registry_list-entry/.manifest; registry_scan registry_list-dir .manifest; [ "$(registry_list)" = "registry_list-entry" ] || exit 81; exit 0
registry_visible	0	mkdir -p registry_visible-dir/registry_visible-entry; printf 'A=1\n' > registry_visible-dir/registry_visible-entry/.manifest; registry_scan registry_visible-dir .manifest; registry_visible registry_visible-entry PLATFORM || exit 81; exit 0
registry_deps	0	mkdir -p registry_deps-dir/registry_deps-b registry_deps-dir/registry_deps-a; printf 'DEPS=registry_deps-b\n' > registry_deps-dir/registry_deps-a/.manifest; printf 'A=1\n' > registry_deps-dir/registry_deps-b/.manifest; registry_scan registry_deps-dir .manifest; registry_deps registry_deps-a DEPS >/dev/null || exit 81; exit 0
registry_topo	0	mkdir -p registry_topo-dir/registry_topo-b registry_topo-dir/registry_topo-a; printf 'DEPS=registry_topo-b\n' > registry_topo-dir/registry_topo-a/.manifest; printf 'A=1\n' > registry_topo-dir/registry_topo-b/.manifest; registry_scan registry_topo-dir .manifest; registry_topo DEPS >/dev/null || exit 81; exit 0
conf_init	0	conf_init conf_init-conf || exit 81; exit 0
conf_file	0	conf_init conf_file-conf; [ "$(conf_file)" = "conf_file-conf" ] || exit 81; exit 0
conf_format	0	conf_init conf_format-conf; [ "$(conf_format)" = "auto" ] || exit 81; exit 0
conf_get	0	printf 'PROBE_K=v\n' > conf_get-conf; conf_init conf_get-conf; [ "$(conf_get PROBE_K)" = "v" ] || exit 81; [ "$(conf_get PROBE_MISSING dflt)" = "dflt" ] || exit 82; exit 0
conf_has	0,1	printf 'PROBE_K=v\n' > conf_has-conf; conf_init conf_has-conf; conf_has PROBE_K || exit 81; conf_has PROBE_MISSING; prc=$?; [ "$prc" = 1 ] || exit 82; exit 0
conf_get_any	0	printf 'PROBE_K=v\n' > conf_get_any-conf; conf_init conf_get_any-conf; [ "$(conf_get_any PROBE_K dflt)" = "v" ] || exit 81; exit 0
conf_load_dotenv	0	printf 'PROBE_K=v\n' > conf_load_dotenv-dotenv; conf_load_dotenv conf_load_dotenv-dotenv || exit 81; exit 0
conf_source	0	printf 'PROBE_K=v\n' > conf_source-dotenv; conf_source conf_source-dotenv || exit 81; exit 0
conf_set	0	conf_init conf_set-conf; conf_set PROBE_K v || exit 81; [ "$(conf_get PROBE_K)" = "v" ] || exit 82; exit 0
conf_unset	0	conf_init conf_unset-conf; conf_set PROBE_K v; conf_unset PROBE_K || exit 81; exit 0
conf_disable	0	conf_init conf_disable-conf; conf_set PROBE_K v; conf_disable PROBE_K || exit 81; exit 0
conf_keys	0	conf_init conf_keys-conf; conf_set PROBE_K v; [ "$(conf_keys)" = "PROBE_K" ] || exit 81; exit 0
fs_ensure_dir	0	fs_ensure_dir fs_ensure_dir-d || exit 81; [ -d fs_ensure_dir-d ] || exit 82; exit 0
fs_atomic_write	0	fs_atomic_write fs_atomic_write-f hello || exit 81; [ "$(cat fs_atomic_write-f)" = "hello" ] || exit 82; exit 0
fs_atomic_copy	0	printf 'x\n' > fs_atomic_copy-src; fs_atomic_copy fs_atomic_copy-src fs_atomic_copy-dst || exit 81; cmp -s fs_atomic_copy-src fs_atomic_copy-dst || exit 82; exit 0
fs_backup	0	printf 'x\n' > fs_backup-f; fs_backup fs_backup-f || exit 81; ls fs_backup-f.bak.* >/dev/null 2>&1 || exit 82; exit 0
fs_ensure_line	0	fs_ensure_line fs_ensure_line-f "abc" || exit 81; [ "$(cat fs_ensure_line-f)" = "abc" ] || exit 82; exit 0
fs_ensure_block	0	fs_ensure_block fs_ensure_block-f BEGIN END content || exit 81; grep -q content fs_ensure_block-f || exit 82; exit 0
fs_ensure_symlink	0	fs_ensure_symlink fs_ensure_symlink-target fs_ensure_symlink-link || exit 81; [ -L fs_ensure_symlink-link ] || exit 82; exit 0
fs_tmpdir	0	pd=$(fs_tmpdir) || exit 81; [ -d "$pd" ] || exit 82; exit 0
fs_tmp_init	0	fs_tmp_init || exit 81; exit 0
trap_push	0	trap_push "true" || exit 81; exit 0
trap_pop	0	trap_push "true"; trap_pop || exit 81; exit 0
trap_list	0	trap_push "true"; trap_list >/dev/null || exit 81; exit 0
trap_cleanup	0	trap_push "true"; trap_cleanup || exit 81; exit 0
trap_install	0	trap_install || exit 81; exit 0
cli_group	0	cli_group "Probe" || exit 81; exit 0
cli_cmd	0	cli_cmd cli_cmd_probe "desc" || exit 81; exit 0
cli_has	0,1	cli_cmd cli_has_probe "desc"; cli_has cli_has_probe || exit 81; cli_has cli_has_none; prc=$?; [ "$prc" = 1 ] || exit 82; exit 0
cli_usage_cmd	0	cli_cmd cli_usage_cmd_probe "desc"; cli_usage_cmd cli_usage_cmd_probe >/dev/null || exit 81; exit 0
cli_usage_global	0	cli_usage_global >/dev/null || exit 81; exit 0
cli_completion_script	0	cli_completion_script bash >/dev/null || exit 81; exit 0
cli_run	0	cli_run --version >/dev/null || exit 81; exit 0
cli_opt_init	0	cli_opt_init || exit 81; exit 0
cli_opt	0	cli_opt cli_opt_probe_var --cli-opt-probe -p || exit 81; exit 0
cli_opts	0	cli_opt cli_opts_probe_var --cli-opt-probe -p 1; cli_opts --cli-opt-probe val || exit 81; [ "$cli_opts_probe_var" = "val" ] || exit 82; exit 0
retry	0,2	retry 1 true || exit 81; retry 0 true; prc=$?; [ "$prc" = 2 ] || exit 82; exit 0
lock_acquire	0	mkdir -p "$PWD/lock_acquire-locks"; SHELLKIT_LOCK_DIR="$PWD/lock_acquire-locks"; lock_acquire lock_acquire-probe || exit 81; exit 0
lock_release	0	mkdir -p "$PWD/lock_release-locks"; SHELLKIT_LOCK_DIR="$PWD/lock_release-locks"; lock_acquire lock_release-probe; lock_release lock_release-probe || exit 81; exit 0
lock_held	0,1	mkdir -p "$PWD/lock_held-locks"; SHELLKIT_LOCK_DIR="$PWD/lock_held-locks"; lock_acquire lock_held-probe; lock_held lock_held-probe || exit 81; lock_held lock_held-none; prc=$?; [ "$prc" = 1 ] || exit 82; exit 0
scaffold_vars_set	0	scaffold_vars_set SCAFFOLD_PROBE_VAR v || exit 81; exit 0
scaffold_vars_get	0	scaffold_vars_set SCAFFOLD_PROBE_VAR v; [ "$(scaffold_vars_get SCAFFOLD_PROBE_VAR)" = "v" ] || exit 81; exit 0
scaffold_vars_list	0	scaffold_vars_set SCAFFOLD_PROBE_VAR v; scaffold_vars_list >/dev/null || exit 81; exit 0
scaffold_config_load	0	printf 'SCAFFOLD_PROBE_VAR=v\n' > scaffold_config_load-config; scaffold_config_load scaffold_config_load-config || exit 81; exit 0
scaffold_render	0	scaffold_vars_set SCAFFOLD_PROBE_VAR world; printf 'hello {{SCAFFOLD_PROBE_VAR}}\n' > scaffold_render-tpl; scaffold_render scaffold_render-tpl scaffold_render-out || exit 81; grep -q world scaffold_render-out || exit 82; exit 0
scaffold_manifest_write	0	mkdir -p scaffold_manifest_write-dir; scaffold_manifest_write scaffold_manifest_write-dir probe-proj "probe-cmd" 1.0 "" || exit 81; exit 0
scaffold_manifest_write_baselines	0	mkdir -p scaffold_manifest_write_baselines-dir; scaffold_manifest_write_baselines scaffold_manifest_write_baselines-dir probe-proj "probe-cmd" 1.0 "" "" || exit 81; exit 0
scaffold_manifest_read	0	mkdir -p scaffold_manifest_read-dir; scaffold_manifest_write scaffold_manifest_read-dir probe-proj "probe-cmd" 1.0 ""; scaffold_manifest_read scaffold_manifest_read-dir || exit 81; exit 0
scaffold_manifest_get	0	mkdir -p scaffold_manifest_get-dir; scaffold_manifest_write scaffold_manifest_get-dir probe-proj "probe-cmd" 1.0 ""; scaffold_manifest_read scaffold_manifest_get-dir; scaffold_manifest_get version >/dev/null || exit 81; exit 0
scaffold_manifest_list_files	0	mkdir -p scaffold_manifest_list_files-dir; scaffold_manifest_write scaffold_manifest_list_files-dir probe-proj "probe-cmd" 1.0 ""; scaffold_manifest_list_files scaffold_manifest_list_files-dir >/dev/null || exit 81; exit 0
scaffold_manifest_file_sum	0,1	mkdir -p scaffold_manifest_file_sum-dir; scaffold_manifest_write scaffold_manifest_file_sum-dir probe-proj "probe-cmd" 1.0 ""; scaffold_manifest_file_sum scaffold_manifest_file_sum-dir no-such-file >/dev/null; prc=$?; [ "$prc" = 1 ] || exit 82; exit 0
scaffold_run_hook	0	scaffold_run_hook scaffold_run_hook-missing . || exit 81; exit 0
man_modules	0	man_modules >/dev/null || exit 81; exit 0
man_page	0	man_page >/dev/null || exit 81; exit 0
man_module_page	0	man_module_page str >/dev/null || exit 81; exit 0
man_count_functions	0	man_count_functions >/dev/null || exit 81; exit 0
run	0	run true >/dev/null 2>&1 || exit 81; exit 0
run_concurrent	0	run_concurrent 2 -- true >/dev/null 2>&1 || exit 81; exit 0
parallel_map	0	printf 'a\nb\n' | parallel_map 2 -- true >/dev/null 2>&1 || exit 81; exit 0
run_timeout	0	run_timeout 5 true >/dev/null 2>&1 || exit 81; exit 0
run_func_timeout	0	run_func_timeout 5 true >/dev/null 2>&1 || exit 81; exit 0
run_install_sudo_shim	0	run_install_sudo_shim || exit 81; exit 0
ask	0,3	pv=""; ask pv "probe" "dflt" || exit 81; [ "$pv" = "dflt" ] || exit 82; exit 0
ask_yn	0,3	pv=""; ask_yn pv "probe" "y" || exit 81; [ "$pv" = "y" ] || exit 82; exit 0
ask_choice	0,3	pv=""; ask_choice pv "probe" "a|b" "a" || exit 81; [ "$pv" = "a" ] || exit 82; exit 0
confirm	0,1	confirm "probe" "y" || exit 81; confirm "probe" "n"; prc=$?; [ "$prc" = 1 ] || exit 82; exit 0
svc_platform	0	svc_platform >/dev/null || exit 81; exit 0
SK_AB_PROBES

  while IFS=$'\t' read -r name reason; do
    [ -n "$name" ] || continue
    _SK_AB_S_NAME[${#_SK_AB_S_NAME[@]}]=$name
    _SK_AB_S_REASON[${#_SK_AB_S_REASON[@]}]=$reason
  done <<'SK_AB_SKIPS'
die	会 exit 进程（退出码由参数决定，不在 @exitcode 承诺集合里）
net_request	需要网络
net_json	需要网络
http_github_latest_tag	需要网络
http_github_release_asset	需要网络
net_download	需要网络（会真的下载文件）
net_wait_port	需要网络（还会逐秒 sleep 等端口）
net_wait_http	需要网络（还会逐秒 sleep 等 HTTP）
os_pkg_update	会改动系统包索引
os_pkg_install	会安装系统软件包
os_pkg_install_root	会提权安装系统软件包
os_pkg_remove_root	会提权卸载系统软件包
os_pkg_update_root	会提权刷新系统包索引
os_pkg_installed	查询结果取决于本机已装的包，跨机器不稳定
os_sudo_ready	可能要交互输入 sudo 口令
man_write_all	一次要渲染 24 页 man（本机实测 86 秒），太慢
svc_start	需要 systemd/launchd，会改动服务状态
svc_stop	需要 systemd/launchd，会改动服务状态
svc_restart	需要 systemd/launchd，会改动服务状态
svc_reload	需要 systemd/launchd，会改动服务状态
svc_enable	需要 systemd/launchd，会改动服务状态
svc_disable	需要 systemd/launchd，会改动服务状态
svc_enable_now	需要 systemd/launchd，会改动服务状态
svc_disable_now	需要 systemd/launchd，会改动服务状态
svc_is_active	依赖 systemd/launchd 的运行状态，跨机器不稳定
svc_is_enabled	依赖 systemd/launchd 的运行状态，跨机器不稳定
svc_daemon_reload	需要 systemd/launchd，会改动服务状态
svc_install_unit	会往系统目录写 unit 文件（需要 root）
SK_AB_SKIPS
}

_sk_ab_probe_index() {
  local want=$1 i=0
  while [ "$i" -lt "${#_SK_AB_P_NAME[@]}" ]; do
    if [ "${_SK_AB_P_NAME[$i]}" = "$want" ]; then
      printf '%s' "$i"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

_sk_ab_skip_index() {
  local want=$1 i=0
  while [ "$i" -lt "${#_SK_AB_S_NAME[@]}" ]; do
    if [ "${_SK_AB_S_NAME[$i]}" = "$want" ]; then
      printf '%s' "$i"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# ---------------------------------------------------------------------------
# 探针执行：一次起一个 worker，库只加载一次
# ---------------------------------------------------------------------------

_SK_AB_PR_NAME=()
_SK_AB_PR_RC=()

# _sk_ab_probe_worker FILE DIR —— worker 模式：库只加载一次，逐条跑探针
# 每条探针跑在**子 shell** 里 ⇒ 探针之间不串味（注册表、配置层、清理栈互不影响）。
# 输出「名字<TAB>退出码」。
_sk_ab_probe_worker() {
  local probe_file=${1:-} workdir=${2:-} name expect snippet
  cd "$workdir" || exit 98
  # shellcheck disable=SC1090
  . "$ROOT/lib/bootstrap.sh" || exit 97
  while IFS=$'\t' read -r name expect snippet; do
    [ -n "$name" ] || continue
    (eval "$snippet") </dev/null >/dev/null 2>&1
    printf '%s\t%s\n' "$name" "$?"
  done <"$probe_file"
}

# _sk_ab_run_probes —— 起一个 worker，把每个探针的实际退出码收进数组
_sk_ab_run_probes() {
  local probe_file workdir out_file name rc i
  probe_file=$(mktemp "${TMPDIR:-/tmp}/sk-api-probes.XXXXXX") || return 1
  workdir=$(mktemp -d "${TMPDIR:-/tmp}/sk-api-work.XXXXXX") || return 1
  out_file=$(mktemp "${TMPDIR:-/tmp}/sk-api-results.XXXXXX") || return 1
  i=0
  while [ "$i" -lt "${#_SK_AB_P_NAME[@]}" ]; do
    if _sk_ab_probe_selected "${_SK_AB_P_NAME[$i]}"; then
      printf '%s\t%s\t%s\n' "${_SK_AB_P_NAME[$i]}" "${_SK_AB_P_EXPECT[$i]}" "${_SK_AB_P_SNIPPET[$i]}" >>"$probe_file"
    fi
    i=$((i + 1))
  done
  if [ -n "$PROBE_FILTER" ]; then
    _sk_ab_log "只跑这些探针: $PROBE_FILTER"
  fi
  SHELLKIT_LANG=en SHELLKIT_NONINTERACTIVE=1 SHELLKIT_COLOR=never \
    "$BASH" "$SCRIPT_PATH" --root "$ROOT" --probe-worker "$probe_file" "$workdir" >"$out_file" 2>/dev/null
  rm -f "$probe_file"
  rm -rf "$workdir"
  while IFS=$'\t' read -r name rc; do
    [ -n "$name" ] || continue
    _SK_AB_PR_NAME[${#_SK_AB_PR_NAME[@]}]=$name
    _SK_AB_PR_RC[${#_SK_AB_PR_RC[@]}]=$rc
  done <"$out_file"
  rm -f "$out_file"
  return 0
}

# _sk_ab_probe_rc NAME —— 某个探针的实际退出码；没跑起来返回 99
_sk_ab_probe_rc() {
  local want=$1 i=0
  while [ "$i" -lt "${#_SK_AB_PR_NAME[@]}" ]; do
    if [ "${_SK_AB_PR_NAME[$i]}" = "$want" ]; then
      printf '%s' "${_SK_AB_PR_RC[$i]}"
      return 0
    fi
    i=$((i + 1))
  done
  printf '99'
}

# _sk_ab_probe_selected NAME —— 这个探针这次要不要跑
# （--probes 过滤时，没被点名的探针不跑，也不算失败 —— 过滤会在 stderr 上写明）
_sk_ab_probe_selected() {
  local want=$1
  if [ -z "$PROBE_FILTER" ]; then
    return 0
  fi
  case ",$PROBE_FILTER," in
    *",$want,"*) return 0 ;;
  esac
  return 1
}

# _sk_ab_covered CODES WANT —— 承诺集合里是否覆盖了这个返回码
_sk_ab_covered() {
  local codes=$1 want=$2 c
  case ",$codes," in
    *",其他,"*) return 0 ;;
  esac
  local old_ifs=$IFS
  IFS=,
  for c in $codes; do
    if [ "$c" = "$want" ]; then
      IFS=$old_ifs
      return 0
    fi
  done
  IFS=$old_ifs
  return 1
}

# _sk_ab_expect_list EXPECT —— 断言过的返回码逐个吐出来
_sk_ab_expect_list() {
  local codes="${1:-}" c
  local old_ifs=$IFS
  IFS=,
  for c in $codes; do
    [ -n "$c" ] || continue
    printf '%s\n' "$c"
  done
  IFS=$old_ifs
}

# ---------------------------------------------------------------------------
# 门禁检查
# ---------------------------------------------------------------------------

_sk_ab_check() {
  local bad=0 i bidx sidx pidx jdx
  local name codes base_codes src_codes status declared probe expect reason
  local probe_count=0 skip_count=0 rc c

  # --- 探针表必须与公开函数集合一一对应（漏一个就没有判据能力，多一个就是错的）---
  i=0
  while [ "$i" -lt "${#_SK_AB_P_NAME[@]}" ]; do
    if ! _sk_ab_src_index "${_SK_AB_P_NAME[$i]}" >/dev/null; then
      _sk_ab_log "探针表里有一个不是公开函数的条目: ${_SK_AB_P_NAME[$i]}"
      bad=1
    fi
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "${#_SK_AB_S_NAME[@]}" ]; do
    if ! _sk_ab_src_index "${_SK_AB_S_NAME[$i]}" >/dev/null; then
      _sk_ab_log "不入探针的名单里有一个不是公开函数的条目: ${_SK_AB_S_NAME[$i]}"
      bad=1
    fi
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "${#_SK_AB_SRC_NAMES[@]}" ]; do
    name=${_SK_AB_SRC_NAMES[$i]}
    if ! _sk_ab_probe_index "$name" >/dev/null && ! _sk_ab_skip_index "$name" >/dev/null; then
      _sk_ab_log "公开函数既没有探针、也没写明不入探针的原因: $name"
      bad=1
    fi
    i=$((i + 1))
  done

  # --- 基线与源码对账 ---
  i=0
  while [ "$i" -lt "${#_SK_AB_SRC_NAMES[@]}" ]; do
    name=${_SK_AB_SRC_NAMES[$i]}
    codes=$(_sk_ab_codes_norm "${_SK_AB_SRC_CODES[$i]}")
    if bidx=$(_sk_ab_base_index "$name"); then
      status=${_SK_AB_BASE_STATUS[$bidx]}
      base_codes=$(_sk_ab_codes_norm "${_SK_AB_BASE_CODES[$bidx]}")
      if [ "$status" = "removed" ]; then
        _sk_ab_log "基线说 $name 已删除，但源码里它还在"
        bad=1
      elif [ "$base_codes" != "$codes" ]; then
        _sk_ab_log "基线与源码对不上: ${name}（基线 $base_codes / 源码 ${codes}）"
        bad=1
      fi
    else
      _sk_ab_log "新公开函数没进基线: ${name}（承诺 ${codes}）—— 跑 bash tools/api_baseline.sh --write-baseline"
      bad=1
    fi
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "${#_SK_AB_BASE_NAMES[@]}" ]; do
    name=${_SK_AB_BASE_NAMES[$i]}
    if ! _sk_ab_src_index "$name" >/dev/null; then
      status=${_SK_AB_BASE_STATUS[$i]}
      if [ "$status" != "removed" ]; then
        _sk_ab_log "基线里有 ${name}，源码里已经没有了 —— 删公开函数是破坏性变更，必须在 docs/MIGRATING.md 声明并重生成基线"
        bad=1
      fi
    fi
    i=$((i + 1))
  done

  # --- 声明必须在 MIGRATING 里查得到（基线记了版本，这里回查）---
  i=0
  while [ "$i" -lt "${#_SK_AB_BASE_NAMES[@]}" ]; do
    name=${_SK_AB_BASE_NAMES[$i]}
    declared=${_SK_AB_BASE_DECLARED[$i]}
    if [ "$declared" != "-" ] && [ -n "$declared" ]; then
      if ! _sk_ab_declared_at "$name" "$declared"; then
        _sk_ab_log "基线说 $name 的行为变化声明在 ${declared}，但 docs/MIGRATING.md 里查不到（版本 $declared 的「会改变结果的行为变化」表格里没有反引号包着的 ${name}）"
        bad=1
      fi
    fi
    i=$((i + 1))
  done

  # --- 基线里的探针列必须与脚本的探针表一致 ---
  i=0
  while [ "$i" -lt "${#_SK_AB_BASE_NAMES[@]}" ]; do
    name=${_SK_AB_BASE_NAMES[$i]}
    probe=${_SK_AB_BASE_PROBE[$i]}
    expect=${_SK_AB_BASE_EXPECT[$i]}
    reason=${_SK_AB_BASE_REASON[$i]}
    if pidx=$(_sk_ab_probe_index "$name"); then
      if [ "$probe" != "probe" ]; then
        _sk_ab_log "基线与探针表对不上: ${name}（基线 $probe / 脚本 probe）"
        bad=1
      elif [ "$expect" != "${_SK_AB_P_EXPECT[$pidx]}" ]; then
        _sk_ab_log "基线与探针表对不上: ${name}（基线断言 $expect / 脚本断言 ${_SK_AB_P_EXPECT[$pidx]}）"
        bad=1
      fi
    elif jdx=$(_sk_ab_skip_index "$name"); then
      if [ "$probe" != "skip" ]; then
        _sk_ab_log "基线与探针表对不上: ${name}（基线 $probe / 脚本 skip）"
        bad=1
      elif [ "$reason" != "${_SK_AB_S_REASON[$jdx]}" ]; then
        _sk_ab_log "基线与探针表对不上: ${name}（不入探针的原因对不上）"
        bad=1
      fi
    fi
    i=$((i + 1))
  done

  # --- 分级（issue #79）：注解、基线列、豁免名单三者一致 ---
  # 规则一（棘轮）：没有 @stability 的公开函数必须在豁免名单里 ——
  # 新函数第一天就要求显式声明，老函数逐个审过才摘出去。
  i=0
  while [ "$i" -lt "${#_SK_AB_SRC_NAMES[@]}" ]; do
    name=${_SK_AB_SRC_NAMES[$i]}
    stab=${_SK_AB_SRC_STAB[$i]}
    case "$stab" in
      '')
        if ! _sk_ab_exempt_index "$name" >/dev/null; then
          _sk_ab_log "公开函数没有声明 @stability，也不在豁免名单里: ${name}（新函数要显式写 @stability stable|experimental）"
          bad=1
        fi
        ;;
      stable | experimental) ;;
      *)
        _sk_ab_log "@stability 的取值只能是 stable 或 experimental: ${name}（写的是 ${stab}）"
        bad=1
        ;;
    esac
    i=$((i + 1))
  done
  # 规则二（双向棘轮，坑 15）：豁免名单里**已经加了注解**的必须移出 ——
  # 否则将来注解被删，棘轮也看不见（白名单只许记「当前确实没做」的那件事）。
  i=0
  while [ "$i" -lt "${#_SK_AB_EXEMPT[@]}" ]; do
    name=${_SK_AB_EXEMPT[$i]}
    if sidx=$(_sk_ab_src_index "$name"); then
      if [ -n "${_SK_AB_SRC_STAB[$sidx]}" ]; then
        _sk_ab_log "豁免名单里的函数已经声明了 @stability，必须移出名单: $name"
        bad=1
      fi
    else
      _sk_ab_log "豁免名单里有源码里不存在的函数: $name"
      bad=1
    fi
    i=$((i + 1))
  done
  # 规则三（一致性）：基线的分级列必须与源码注解一致；没有这一列就提示重生成。
  i=0
  while [ "$i" -lt "${#_SK_AB_BASE_NAMES[@]}" ]; do
    name=${_SK_AB_BASE_NAMES[$i]}
    if sidx=$(_sk_ab_src_index "$name"); then
      want=${_SK_AB_SRC_STAB[$sidx]:-experimental}
      have=${_SK_AB_BASE_STAB[$i]}
      if [ "$have" != "$want" ]; then
        _sk_ab_log "基线的分级与源码注解对不上: ${name}（基线 ${have:-<无分级列>} / 源码 ${want}）—— 跑 bash tools/api_baseline.sh --write-baseline"
        bad=1
      fi
    fi
    i=$((i + 1))
  done

  # --- 真跑探针（一次起一个 worker，库只加载一次）---
  if [ "$bad" -ne 0 ]; then
    _sk_ab_log "前面的检查已经没过，探针这次不跑（结论不会变）"
  else
    _sk_ab_run_probes
    i=0
    while [ "$i" -lt "${#_SK_AB_P_NAME[@]}" ]; do
      name=${_SK_AB_P_NAME[$i]}
      expect=${_SK_AB_P_EXPECT[$i]}
      if ! _sk_ab_probe_selected "$name"; then
        i=$((i + 1))
        continue
      fi
      if sidx=$(_sk_ab_src_index "$name"); then
        src_codes=$(_sk_ab_codes_norm "${_SK_AB_SRC_CODES[$sidx]}")
        local e_ifs=$IFS
        IFS=,
        for c in $expect; do
          [ -n "$c" ] || continue
          if ! _sk_ab_covered "$src_codes" "$c"; then
            _sk_ab_log "探针断言的返回码 $c 不在 $name 的 @exitcode 承诺集合（${src_codes}）里"
            bad=1
          fi
        done
        IFS=$e_ifs
      fi
      rc=$(_sk_ab_probe_rc "$name")
      if [ "$rc" -ne 0 ]; then
        _sk_ab_log "探针失败: ${name}（沙箱里的断言没成立，退出码 ${rc}）"
        bad=1
      fi
      probe_count=$((probe_count + 1))
      i=$((i + 1))
    done
  fi
  skip_count=${#_SK_AB_S_NAME[@]}

  if [ "$bad" -ne 0 ]; then
    _sk_ab_log "门禁没过：行为基线与源码 / 迁移说明对不上"
    exit 5
  fi
  printf 'api_baseline: ok（%s 个公开函数，%s 个探针，%s 个不入探针）\n' \
    "${#_SK_AB_SRC_NAMES[@]}" "$probe_count" "$skip_count"
  exit 0
}

# ---------------------------------------------------------------------------
# 重生成基线
# ---------------------------------------------------------------------------

_sk_ab_write() {
  local i bidx name codes old_codes status declared ref newver
  local cur_version tmp sorted line probe expect reason pidx jdx
  local -a out_names=() out_codes=() out_status=() out_declared=()

  cur_version=$(tr -d '[:space:]' <"$VERSION_FILE" 2>/dev/null)
  [ -n "$cur_version" ] || cur_version="dev"

  # 1. 以源码为准，逐个函数算出基线条目
  i=0
  while [ "$i" -lt "${#_SK_AB_SRC_NAMES[@]}" ]; do
    name=${_SK_AB_SRC_NAMES[$i]}
    codes=$(_sk_ab_codes_norm "${_SK_AB_SRC_CODES[$i]}")
    status=active
    declared="-"
    if bidx=$(_sk_ab_base_index "$name"); then
      old_codes=$(_sk_ab_codes_norm "${_SK_AB_BASE_CODES[$bidx]}")
      status=${_SK_AB_BASE_STATUS[$bidx]}
      declared=${_SK_AB_BASE_DECLARED[$bidx]}
      ref=$declared
      if [ "$ref" = "-" ] || [ -z "$ref" ]; then
        ref=${_SK_AB_BASE_VERSION:-$cur_version}
      fi
      if [ "$status" = "removed" ]; then
        if ! newver=$(_sk_ab_declared "$name" "$ref"); then
          _sk_ab_die "公开函数 $name 又回来了（基线说它已删除）—— 这是行为变更，必须在 docs/MIGRATING.md 的「会改变结果的行为变化」表格里声明（版本要新于 ${ref}）" 5
        fi
        status=active
        declared=$newver
        _sk_ab_log "${name}：删除后复活，声明在 $newver"
      elif [ "$old_codes" != "$codes" ]; then
        if ! newver=$(_sk_ab_declared "$name" "$ref"); then
          _sk_ab_die "公开函数 $name 的承诺返回码变了（$old_codes → ${codes}）—— 必须在 docs/MIGRATING.md 的「会改变结果的行为变化」表格里声明（版本要新于 ${ref}）" 5
        fi
        declared=$newver
        _sk_ab_log "${name}：承诺返回码 $old_codes → ${codes}，声明在 $newver"
      fi
    fi
    out_names[${#out_names[@]}]=$name
    out_codes[${#out_codes[@]}]=$codes
    out_status[${#out_status[@]}]=$status
    out_declared[${#out_declared[@]}]=$declared
    i=$((i + 1))
  done

  # 2. 基线里有、源码里没有的：删除也是破坏性变更，要声明
  i=0
  while [ "$i" -lt "${#_SK_AB_BASE_NAMES[@]}" ]; do
    name=${_SK_AB_BASE_NAMES[$i]}
    if ! _sk_ab_src_index "$name" >/dev/null; then
      status=${_SK_AB_BASE_STATUS[$i]}
      declared=${_SK_AB_BASE_DECLARED[$i]}
      if [ "$status" != "removed" ]; then
        ref=$declared
        if [ "$ref" = "-" ] || [ -z "$ref" ]; then
          ref=${_SK_AB_BASE_VERSION:-$cur_version}
        fi
        if ! newver=$(_sk_ab_declared "$name" "$ref"); then
          _sk_ab_die "公开函数 $name 被删了 —— 删除公开函数是破坏性变更，必须在 docs/MIGRATING.md 的「会改变结果的行为变化」表格里声明（版本要新于 ${ref}）" 5
        fi
        declared=$newver
        status=removed
        _sk_ab_log "${name}：已删除，声明在 $newver"
      fi
      out_names[${#out_names[@]}]=$name
      out_codes[${#out_codes[@]}]=$(_sk_ab_codes_norm "${_SK_AB_BASE_CODES[$i]}")
      out_status[${#out_status[@]}]=$status
      out_declared[${#out_declared[@]}]=$declared
    fi
    i=$((i + 1))
  done

  # 3. 排序后落盘（临时文件 + rename，不留半截文件）
  tmp=$(mktemp "${TMPDIR:-/tmp}/sk-api-baseline.XXXXXX") || exit 1
  sorted=$(mktemp "${TMPDIR:-/tmp}/sk-api-baseline.XXXXXX") || exit 1
  i=0
  while [ "$i" -lt "${#out_names[@]}" ]; do
    printf '%s\t%s\t%s\t%s\n' "${out_names[$i]}" "${out_codes[$i]}" \
      "${out_status[$i]}" "${out_declared[$i]}" >>"$tmp"
    i=$((i + 1))
  done
  sort -t"$(printf '\t')" -k1,1 "$tmp" >"$sorted"
  rm -f "$tmp"

  tmp=$(mktemp "${BASELINE}.tmp.XXXXXX") || exit 1
  {
    cat <<'SK_AB_HEADER'
# shellkit 公开 API 行为基线
#
# 由 `bash tools/api_baseline.sh --write-baseline` 生成 —— **不要手工维护**。
# 手工改这里没有意义：门禁会拿它跟源码重算的结果逐项比对，对不上就红；
# 手改「声明版本」也躲不过 —— 门禁会回查 docs/MIGRATING.md。
#
# 格式（制表符分隔，每行一个公开函数）：
#   名字            公开函数名（lib/core/*.sh 里不以 _ 开头的函数）
#   承诺返回码      逗号分隔，来自源码注释里的 @exitcode 行（唯一真相源）
#   状态            active=还在 / removed=已删除（删除公开函数也是行为变更）
#   声明版本        这一版承诺是在哪个版本里写进 MIGRATING 的；- = 沿用基线，没有单独声明
#   探针            probe=沙箱里真调过 / skip=没调
#   探针断言        探针断言过的返回码（逗号分隔）；skip 时为 -
#   不入探针的原因  probe 时为 -
#   分级            stable=承诺稳定 / experimental=暂不承诺（源码注释 @stability 的投影）
#                   没写注解的按 experimental 落盘；是否已声明看 tools/stability_exempt.txt
#
SK_AB_HEADER
    printf 'baseline-version: %s\n' "$cur_version"
    while IFS= read -r line; do
      IFS=$'\t' read -r name codes status declared <<EOF
$line
EOF
      if pidx=$(_sk_ab_probe_index "$name"); then
        probe=probe
        expect=${_SK_AB_P_EXPECT[$pidx]}
        reason=-
      else
        probe=skip
        expect=-
        if jdx=$(_sk_ab_skip_index "$name"); then
          reason=${_SK_AB_S_REASON[$jdx]}
        else
          reason=-
        fi
      fi
      # 分级取自源码注解；没写 @stability 的按 experimental 落盘（= 暂不承诺）
      stab=experimental
      if sidx=$(_sk_ab_src_index "$name"); then
        [ -n "${_SK_AB_SRC_STAB[$sidx]}" ] && stab=${_SK_AB_SRC_STAB[$sidx]}
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$name" "$codes" "$status" "$declared" "$probe" "$expect" "$reason" "$stab"
    done <"$sorted"
  } >"$tmp"
  rm -f "$sorted"
  # mktemp 落盘是 600，仓库里的基线文件是 644 —— 显式对齐，别让生成物带着私权限进 git
  chmod 644 "$tmp" 2>/dev/null || true
  if ! mv -f "$tmp" "$BASELINE"; then
    rm -f "$tmp"
    _sk_ab_die "写基线失败: $BASELINE" 1
  fi
  printf 'api_baseline: 已重生成基线（%s 个条目，版本 %s）\n' "${#out_names[@]}" "$cur_version"
  exit 0
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

if [ "$PROBE_WORKER" = "1" ]; then
  _sk_ab_probe_worker "$PROBE_FILE" "$PROBE_DIR"
  exit 0
fi

if [ ! -d "$LIB_DIR" ]; then
  _sk_ab_die "找不到库目录: $LIB_DIR" 3
fi
if [ ! -f "$MIGRATING" ]; then
  _sk_ab_die "找不到迁移说明: $MIGRATING" 3
fi

while IFS=$'\t' read -r name codes stab; do
  [ -n "$name" ] || continue
  _SK_AB_SRC_NAMES[${#_SK_AB_SRC_NAMES[@]}]=$name
  _SK_AB_SRC_CODES[${#_SK_AB_SRC_CODES[@]}]=$codes
  # 原样保留：空 = 源码里没有 @stability（棘轮规则要靠它区分「声明过」与「没声明」）
  # 默认值 experimental 只在落盘与展示时给，不回填这里
  _SK_AB_SRC_STAB[${#_SK_AB_SRC_STAB[@]}]=${stab}
done <<EOF
$(_sk_ab_scan_source)
EOF

_sk_ab_load_probe_tables
_sk_ab_load_exempt
_sk_ab_load_declarations

if [ "$MODE" = "write" ]; then
  if [ -f "$BASELINE" ]; then
    _sk_ab_load_baseline
  fi
  _sk_ab_write
else
  if [ ! -f "$BASELINE" ]; then
    _sk_ab_die "基线文件不存在: ${BASELINE}（先跑 bash tools/api_baseline.sh --write-baseline）" 3
  fi
  _sk_ab_load_baseline
  _sk_ab_check
fi
