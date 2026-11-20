#!/usr/bin/env bash
#
# 门禁：POSIX 子集必须真的能在 POSIX sh 上跑，能力清单不能漂。
#
# 为什么需要这道门：设备侧脚本（NAS 的 start/stop、OpenWrt 的 init）是
# 「装机即执行」的 —— 装上就挂，而现场装不了 shellkit 补救。
# POSIX 子集一旦混进一个 bash 专有语法（数组 / [[ ]] / local / printf -v），
# busybox ash 上**不是报错，是整个脚本起不来**。
#
# 查五件事：
#   1. lib/posix/*.sh 用 dash -n 解析得过（dash 是最接近 POSIX 的实现）
#   2. lib/posix/*.sh 过 shellcheck -s sh（bashism 一律挑出来）
#   3. 本地再扫一遍常见 bashism（不只靠 shellcheck：它没覆盖到的写法也要挑出来）
#   4. 能力清单 capabilities.tsv 与源码一致：
#      - 清单里 yes 的函数必须真的在 POSIX 库里；
#      - 清单里 no 的函数必须真的在主库里（不能写一个不存在的名字）；
#      - 主库的每个公开函数都要在清单里 —— 漏了就是漂；
#      - 只在 POSIX 库里有的函数（posix_capable 之类）也要在清单里；
#      - 每个 no 都要写明原因（设备侧脚本据此判断「这条能不能用」）。
#   5. 清单与源码不一致时给出重生成命令（--write）
#
#   bash tools/check_posix.sh            # 检查
#   bash tools/check_posix.sh --write    # 按源码重生成能力清单
#
# 退出码：0 通过；5 不合格；2 用法错
set -u

ROOT="${SHELLKIT_CHECK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)}"
POSIX_DIR="$ROOT/lib/posix"
POSIX_LIB="$POSIX_DIR/shellkit-posix.sh"
CAP_FILE="$POSIX_DIR/capabilities.tsv"
WRITE=0
_bad=0

case "${1:-}" in
  --write) WRITE=1 ;;
  "") ;;
  -h | --help)
    printf 'usage: bash %s [--write]\n' "${0##*/}"
    exit 0
    ;;
  *)
    printf 'check_posix: unknown option: %s\n' "$1" >&2
    exit 2
    ;;
esac

_fail() {
  printf 'check_posix: %s\n' "$1" >&2
  _bad=1
}

# ---------------------------------------------------------------------------
# 索引：一次建好，后面全是查表
#
# 这道门要对账两百来个函数名。**每个条目重跑一次 awk** ⇒ 一万多次进程派生，
# 门禁自己跑好几分钟 —— 比它要查的问题还慢。所以先把名单落成文件，
# 后面一律 grep 查表。
#
# 索引是一次性产物，不是缓存：进程退出就没了，也不会与源码脱节。
# ---------------------------------------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/shellkit-posix.XXXXXX")" || {
  printf 'check_posix: cannot create a work directory\n' >&2
  exit 3
}
# 退出时清掉自己的工作目录，以及 --write 模式留下的临时文件。
# 临时文件不能留在 lib/posix/ 里：那棵目录会被 vendor 整树复制进工程，
# 于是「一次被杀的门禁运行」会变成「工程里多了一个 *.tmp.* 的垃圾文件」。
trap 'rm -rf "$WORK"; rm -f "$CAP_FILE.tmp.$$" 2>/dev/null || true' EXIT
MAIN_TSV="$WORK/main.tsv"     # 函数名<TAB>模块名
MAIN_LIST="$WORK/main.list"   # 主库的公开函数名（已排序）
POSIX_LIST="$WORK/posix.list" # POSIX 子集的公开函数名（已排序）

# _build_index —— 扫源码建索引
_build_index() {
  local __f
  : >"$MAIN_TSV"
  for __f in "$ROOT"/lib/core/*.sh; do
    [ -f "$__f" ] || continue
    awk '
      /^[A-Za-z_][A-Za-z0-9_]*\(\)[ \t]*\{/ {
        name = $0
        sub(/\(.*/, "", name)
        if (name !~ /^_/) {
          mod = FILENAME
          sub(/^.*\//, "", mod)
          print name "\t" mod
        }
      }
    ' "$__f" >>"$MAIN_TSV" || return 1
  done
  LC_ALL=C sort -u -o "$MAIN_TSV" "$MAIN_TSV" || return 1
  cut -f1 "$MAIN_TSV" >"$MAIN_LIST" || return 1
  awk '
    /^[A-Za-z_][A-Za-z0-9_]*\(\)[ \t]*\{/ {
      name = $0
      sub(/\(.*/, "", name)
      if (name !~ /^_/) print name
    }
  ' "$POSIX_LIB" | LC_ALL=C sort -u >"$POSIX_LIST" || return 1
  return 0
}

# ---- 主库的公开函数（名字不以 _ 开头）----
#
# 只认真正的函数定义行：^name() { —— 变量赋值（NAME=()）不算。
_main_functions() {
  cat "$MAIN_LIST"
}

# ---- POSIX 子集的公开函数 ----
_posix_functions() {
  cat "$POSIX_LIST"
}

# ---- 这个函数在不在主库里 / 在不在 POSIX 库里 ----
#
# 名单一次性读进 bash 变量，用 case 判断成员：函数名里只有字母、数字、下划线，
# 拼成空格分隔的一串就够了。
#
# 为什么不用 grep 查文件：每问一次就派生一次进程，两百多个函数就是两百多次
# —— 门禁自己跑半分钟，比它要查的问题还慢。
# 为什么不用关联数组：bash 3.2 没有 declare -A（基线是 3.2，不是 4.x）。
__MAIN_SET=""
__POSIX_SET=""
_load_sets() {
  __MAIN_SET=" $(tr '\n' ' ' <"$MAIN_LIST") "
  __POSIX_SET=" $(tr '\n' ' ' <"$POSIX_LIST") "
  return 0
}

# _has SET NAME —— NAME 在不在这个空格分隔的名单里
_has() {
  case "$1" in
    *" $2 "*) return 0 ;;
  esac
  return 1
}

_in_main() {
  _has "$__MAIN_SET" "$1"
}

_in_posix() {
  _has "$__POSIX_SET" "$1"
}

# ---- 主库与 POSIX 子集的重叠数 / 差集数 ----
#
# 清单头部要写准：POSIX 子集「提供」的是主库里的哪几个，不是它自己有几个函数。
_posix_overlap_count() {
  LC_ALL=C comm -12 "$MAIN_LIST" "$POSIX_LIST" | wc -l | tr -d ' '
}

_posix_only_count() {
  LC_ALL=C comm -13 "$MAIN_LIST" "$POSIX_LIST" | wc -l | tr -d ' '
}

# ---- 不可用时的原因（按函数给特例，按模块给默认）----
_reason_for() {
  local __fn=$1 __mod=$2
  case "$__fn" in
    _t | _tn)
      printf '%s' "设备侧不引入 gettext 依赖（文案固定在脚本里）"
      return 0
      ;;
    require_root | require_file | require_bash)
      printf '%s' "POSIX 子集不做 root / 文件存在性这类前置条件检查"
      return 0
      ;;
    str_repeat | str_upper | str_lower)
      printf '%s' "POSIX 子集用 printf / tr 就够，不单独移植"
      return 0
      ;;
    trap_pop | trap_list | trap_cleanup)
      printf '%s' "POSIX 子集只做「退出时执行」，没有清理栈管理接口"
      return 0
      ;;
    fs_atomic_write | fs_atomic_copy | fs_backup | fs_ensure_symlink)
      printf '%s' "原子写 / 备份 / 符号链接在设备侧用不上"
      return 0
      ;;
    net_request | net_json | net_wait_port | net_wait_http)
      printf '%s' "POSIX 子集只给下载与校验，不给 HTTP 客户端与就绪探测"
      return 0
      ;;
    conf_get | conf_set | conf_has | conf_keys)
      printf '%s' "POSIX 子集只给 conf_init 与 conf_get_any（无「配置层」这一层）"
      return 0
      ;;
    ask | ask_yn | ask_choice | confirm)
      printf '%s' "交互在无人值守的设备侧用不上"
      return 0
      ;;
    lock_held)
      printf '%s' "POSIX 子集只提供拿锁与放锁"
      return 0
      ;;
    svc_*)
      printf '%s' "systemd / launchd 的服务单元在设备侧不存在"
      return 0
      ;;
    os_pkg_* | os_sudo_ready)
      printf '%s' "设备侧没有包管理器，也不该动系统包"
      return 0
      ;;
    run | run_concurrent | parallel_map)
      printf '%s' "命令执行层依赖 bash 的上下文栈与脱敏规则"
      return 0
      ;;
    cli_* | man_*)
      printf '%s' "CLI 框架与 man 页是开发期的事，设备侧不生成"
      return 0
      ;;
    scaffold_*)
      printf '%s' "模板生成是开发期的事，设备侧不生成工程"
      return 0
      ;;
    registry_*)
      printf '%s' "注册表机制依赖 bash 的关联数组"
      return 0
      ;;
    profile_*)
      printf '%s' "profile 文件格式在设备侧用不上"
      return 0
      ;;
    vendor_*)
      printf '%s' "库副本落点是工程期的事，设备侧不 vendor 库"
      return 0
      ;;
    proc_*)
      printf '%s' "进程组与看门狗的 bash 版本不进 POSIX 子集（POSIX 子集只给同名 ash 版）"
      return 0
      ;;
    git_*)
      printf '%s' "git 领域抽象在设备侧用不上"
      return 0
      ;;
    status_version | status_extra)
      printf '%s' "POSIX 子集只给 status_emit / status_is_machine / status_state_valid"
      return 0
      ;;
  esac
  case "$__mod" in
    i18n.sh)
      printf '%s' "设备侧不引入 gettext 依赖（文案固定在脚本里）"
      ;;
    log.sh)
      printf '%s' "POSIX 子集提供日志六件套"
      ;;
    error.sh)
      printf '%s' "POSIX 子集只给 die / fail"
      ;;
    str.sh)
      printf '%s' "POSIX 子集用 printf / tr 就够，不单独移植"
      ;;
    validate.sh)
      printf '%s' "输入校验在 POSIX 子集里用 case 就够"
      ;;
    trap.sh)
      printf '%s' "POSIX 子集只做「退出时执行」，没有清理栈管理接口"
      ;;
    fs.sh)
      printf '%s' "POSIX 子集只给 fs_ensure_dir / fs_ensure_file"
      ;;
    run.sh)
      printf '%s' "命令执行层依赖 bash 的上下文栈与脱敏规则"
      ;;
    os.sh)
      printf '%s' "设备侧没有包管理器，也不该动系统包"
      ;;
    svc.sh)
      printf '%s' "systemd / launchd 的服务单元在设备侧不存在"
      ;;
    ver.sh)
      printf '%s' "POSIX 子集提供 ver_cmp / ver_gt / ver_lt / ver_eq"
      ;;
    status.sh)
      printf '%s' "POSIX 子集提供 status_emit / status_is_machine / status_state_valid"
      ;;
    registry.sh)
      printf '%s' "注册表机制依赖 bash 的关联数组"
      ;;
    profile.sh)
      printf '%s' "profile 文件格式在设备侧用不上"
      ;;
    scaffold.sh)
      printf '%s' "模板生成是开发期的事，设备侧不生成工程"
      ;;
    retry.sh)
      printf '%s' "POSIX 子集提供 retry"
      ;;
    lock.sh)
      printf '%s' "POSIX 子集只提供拿锁与放锁"
      ;;
    net.sh)
      printf '%s' "POSIX 子集只给下载与校验"
      ;;
    http.sh)
      printf '%s' "POSIX 子集不给 HTTP 客户端"
      ;;
    config.sh)
      printf '%s' "POSIX 子集只给 conf_init 与 conf_get_any"
      ;;
    prompt.sh)
      printf '%s' "交互在无人值守的设备侧用不上"
      ;;
    cli.sh)
      printf '%s' "CLI 框架是开发期的事，设备侧不生成"
      ;;
    man.sh)
      printf '%s' "man 页是开发期的事，设备侧不生成"
      ;;
    vendor.sh)
      printf '%s' "库副本落点是工程期的事，设备侧不 vendor 库"
      ;;
    proc.sh)
      printf '%s' "进程组与看门狗的 bash 版本不进 POSIX 子集（POSIX 子集只给同名 ash 版）"
      ;;
    git.sh)
      printf '%s' "git 领域抽象在设备侧用不上"
      ;;
    *)
      printf '%s' "POSIX 子集未实现（模块 ${__mod:-未知}）"
      ;;
  esac
}

# ---- 有的话有什么限制（yes 行也要写清楚）----
#
# 清单里 yes 的行过去一律写 "-" ⇒ 设备侧脚本只知道「有这条」，
# 不知道**这条在设备侧是什么样**（能不能整组停？查不查得到状态？）。
# 「同一套语义在 ash 上有降级」这件事必须写进清单，否则用的人
# 会按主库的行为去假设它。
_yes_note_for() {
  case "${1:-}" in
    proc_start | proc_stop | proc_is_running | proc_watchdog)
      printf '%s' "POSIX 子集提供同名版本（语义与返回码一致）：没有作业控制 ⇒ 靠 setsid 拿进程组，拿不到时只停主进程；状态从 /proc/<pid>/stat 读，查不到时退化成 kill -0；与主库同名，两份不要同时加载"
      ;;
    lock_acquire | lock_release)
      printf '%s' "POSIX 子集提供同名版本：只删**自己持有**的锁（持有者 pid 不是自己就拒绝）；lock_acquire 建不出锁目录时立刻报错返回 3（不重试）；释放后从退出清理栈里摘掉自己那条 —— 否则退出清理会删掉别人后来拿到的锁"
      ;;
    retry)
      printf '%s' "POSIX 子集提供同名版本：带退避（SHELLKIT_RETRY_DELAY / _BACKOFF / _MAX_DELAY），退出码 2 与 3 不重试；SHELLKIT_RETRY_ON 非空时只重试名单里的退出码"
      ;;
    ver_cmp | ver_eq | ver_gt | ver_lt)
      printf '%s' "POSIX 子集提供同名版本：与主库同一口径（认 v 前缀、认预发布后缀、正式版 > 同核心的预发布）；非法版本号返回 2"
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# 生成能力清单
#
# 用法：_write_capabilities <输出文件>
#
# 清单的条目 = 主库公开函数 ∪ POSIX 子集公开函数：
#   - 主库的函数：POSIX 里有 ⇒ yes；没有 ⇒ no + 为什么没有；
#   - 只在 POSIX 子集里有的（posix_capable 之类）⇒ yes + 「仅 POSIX 子集提供」。
#     漏掉它们，设备侧脚本就查不到「设备侧有、主库没有」的能力。
# ---------------------------------------------------------------------------
_write_capabilities() {
  local __out=$1
  local __tmp="$__out.tmp.$$"
  local __fn __mod
  {
    printf '# shellkit POSIX 子集的能力清单\n'
    printf '#\n'
    printf '# 由 bash tools/check_posix.sh --write 生成，不要手工维护。\n'
    printf '#\n'
    printf '# 格式：函数名<TAB>POSIX 子集里有没有<TAB>没有的话为什么 / 有的话有什么限制\n'
    printf '#\n'
    printf '# 设备侧脚本据此判断「这条能不能用」，而不是靠试 —— 试出来的失败往往是\n'
    printf '# 「装上就挂」，而现场装不了 shellkit 补救。\n'
    printf '# 运行时也能问：posix_capable 函数名\n'
    printf '#\n'
    printf '# 主库的公开函数一共 %s 个，POSIX 子集提供其中 %s 个。\n' \
      "$(_main_functions | wc -l | tr -d ' ')" "$(_posix_overlap_count)"
    printf '# 另有 %s 个是仅 POSIX 子集专有的（主库没有这个函数）。\n' "$(_posix_only_count)"
    printf '#\n'
    printf '# 函数名\tPOSIX 子集\t原因\n'
    while IFS='	' read -r __fn __mod; do
      [ -n "$__fn" ] || continue
      if _in_posix "$__fn"; then
        __note=$(_yes_note_for "$__fn")
        [ -n "$__note" ] || __note="-"
        printf '%s\tyes\t%s\n' "$__fn" "$__note"
      else
        [ -n "$__mod" ] || __mod=unknown.sh
        printf '%s\tno\t%s\n' "$__fn" "$(_reason_for "$__fn" "$__mod")"
      fi
    done <"$MAIN_TSV"
    while IFS= read -r __fn; do
      [ -n "$__fn" ] || continue
      if _in_main "$__fn"; then
        continue
      fi
      printf '%s\tyes\t仅 POSIX 子集提供（主库没有这个函数）\n' "$__fn"
    done <"$POSIX_ONLY"
  } >"$__tmp" || {
    _fail "cannot write the capability list"
    return 1
  }
  mv -f "$__tmp" "$__out" || {
    _fail "cannot replace the capability list"
    return 1
  }
  return 0
}

# ---------------------------------------------------------------------------
# 1) POSIX 库存在
# ---------------------------------------------------------------------------
if [ ! -f "$POSIX_LIB" ]; then
  _fail "the POSIX subset is missing: lib/posix/shellkit-posix.sh"
  printf 'check_posix: FAILED\n' >&2
  exit 5
fi

if ! _build_index; then
  _fail "cannot build the function index"
  printf 'check_posix: FAILED\n' >&2
  exit 5
fi

# 只有 POSIX 子集有、主库没有的公开函数：清单里也要有一条（yes）
LC_ALL=C comm -13 "$MAIN_LIST" "$POSIX_LIST" >"$WORK/posix_only.list" || true
POSIX_ONLY="$WORK/posix_only.list"
_load_sets

# ---------------------------------------------------------------------------
# 2) dash 解析
# ---------------------------------------------------------------------------
if command -v dash >/dev/null 2>&1; then
  for __f in "$POSIX_DIR"/*.sh; do
    [ -f "$__f" ] || continue
    if ! dash -n "$__f" >/dev/null 2>&1; then
      __err="$(dash -n "$__f" 2>&1 || true)"
      _fail "$__f: does not parse under dash: $(printf '%s' "$__err" | sed -n '1,3p')"
    fi
  done
else
  printf 'check_posix: dash is not installed, skipping the parse check\n' >&2
fi

# ---------------------------------------------------------------------------
# 3) shellcheck -s sh
# ---------------------------------------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
  for __f in "$POSIX_DIR"/*.sh; do
    [ -f "$__f" ] || continue
    if ! shellcheck -s sh "$__f" >/dev/null 2>&1; then
      _fail "$__f: has shellcheck findings in the sh dialect (run: shellcheck -s sh $__f)"
    fi
  done
else
  printf 'check_posix: shellcheck is not installed, skipping the dialect check\n' >&2
fi

# ---------------------------------------------------------------------------
# 4) 本地 bashism 扫描（shellcheck 没覆盖到的写法也挑出来）
#
# 注释行先滤掉 —— 头部注释里就写着「没有 local、没有 [[ ]]」，
# 那几行自己就含有这些词。
# ---------------------------------------------------------------------------
BASHISM_RE='(^|[^_[:alnum:]])local[[:space:]]|[[:space:]]\[\[|printf[[:space:]]+-v|(^|[^_[:alnum:]])source[[:space:]]|mapfile|readarray|(^|[^_[:alnum:]])declare[[:space:]]|(^|[^_[:alnum:]])typeset[[:space:]]|=~|\$\{[^}]*\^\^|\$\{[^}]*,,|\$\{!|<<<|[^$]\(\(|&>>|&>|\+=|<\(|>\(|\|&|(^|[^_[:alnum:]])function[[:space:]]|(^|[^_[:alnum:]])select[[:space:]]'

for __f in "$POSIX_DIR"/*.sh; do
  [ -f "$__f" ] || continue
  __hits="$(grep -nE "$BASHISM_RE" "$__f" 2>/dev/null | grep -v ':[[:space:]]*#' || true)"
  if [ -n "$__hits" ]; then
    while IFS= read -r __hit; do
      [ -n "$__hit" ] || continue
      _fail "$__f: bash-only syntax in the POSIX subset: $__hit"
    done <<EOF
$__hits
EOF
  fi
done

# ---------------------------------------------------------------------------
# 5) 能力清单
# ---------------------------------------------------------------------------
if [ "$WRITE" = "1" ]; then
  _write_capabilities "$CAP_FILE" || true
  printf 'check_posix: capability list rewritten: %s\n' "$CAP_FILE"
fi

if [ ! -f "$CAP_FILE" ]; then
  _fail "the capability list is missing: lib/posix/capabilities.tsv (run: bash tools/check_posix.sh --write)"
  printf 'check_posix: FAILED\n' >&2
  exit 5
fi

# 对账用的副本放在工作目录里，不放在 lib/posix/ 旁边 ——
# 它永远不会被 mv 回正式位置，没必要在源码目录里留临时文件。
__tmp_cap="$WORK/cap.tsv"
_write_capabilities "$__tmp_cap" >/dev/null 2>&1 || true
if ! cmp -s "$CAP_FILE" "$__tmp_cap"; then
  _fail "the capability list is out of date (run: bash tools/check_posix.sh --write)"
  # diff 的输出用 sed 截断，不用 head —— head 命中即退会把 diff 打死（141），
  # 调用方一开 pipefail 整条管道就误判失败。
  diff -u "$CAP_FILE" "$__tmp_cap" >"$WORK/cap.diff" 2>/dev/null || true
  sed -n '1,20p' "$WORK/cap.diff" >&2 || true
fi
rm -f "$__tmp_cap"

# 清单里第一列（函数名）单独落一份：后面查「清单里有没有这个函数」
# 用查表，不要拿函数名去整行匹配（清单行是「名字<TAB>yes<TAB>原因」，
# 整行匹配当然匹配不上 —— 这个错会伪装成「清单漏了所有函数」）。
CAP_LIST="$WORK/cap.list"
cut -f1 "$CAP_FILE" >"$CAP_LIST" 2>/dev/null || true

# 清单里 yes 的函数必须真的在 POSIX 库里；no 的必须在主库里
while IFS='	' read -r __fn __has __reason; do
  case "$__fn" in
    '' | '#'*) continue ;;
  esac
  [ -n "$__has" ] || continue
  if [ "$__has" = "yes" ]; then
    if ! _in_posix "$__fn"; then
      _fail "the capability list says $__fn is available, but the POSIX subset does not define it"
    fi
  else
    if ! _in_main "$__fn"; then
      _fail "the capability list mentions $__fn, but no such public function exists"
    fi
    if [ -z "$__reason" ] || [ "$__reason" = "-" ]; then
      _fail "the capability list must say why $__fn is unavailable"
    fi
  fi
done <"$CAP_FILE"

# POSIX 库里每个公开函数都要在清单里（漏了 = 漂）
while IFS= read -r __fn; do
  [ -n "$__fn" ] || continue
  if ! grep -qxF -- "$__fn" "$CAP_LIST"; then
    _fail "the POSIX subset defines $__fn, but the capability list does not mention it"
  fi
done <"$POSIX_LIST"

if [ "$_bad" -ne 0 ]; then
  printf 'check_posix: FAILED\n' >&2
  exit 5
fi
printf 'check_posix: ok\n'
exit 0
