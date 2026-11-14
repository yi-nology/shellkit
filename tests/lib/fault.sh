#!/usr/bin/env bash
# 故障注入辅助层（测试用）：可复用的注入点 + 统一的观察契约。
#
# 为什么要这一层：故障注入原先是「各用例各写各的」—— 每个测试自己造替身、
# 自己判断磁盘状态。同一个坑有的用例验了、有的没验，判据口径也各不相同。
# 抽成共享层之后：
#   * 注入点只有一处实现（替身怎么造、什么时候动手）；
#   * 每个注入点的**观察契约**统一由 fault_snapshot 表达；
#   * 用例只负责「注入什么 + 断言什么」，不再各写各的。
#
# 四类注入点：
#   磁盘满   fault_disk_full_limit（内核 RLIMIT_FSIZE）/ fault_enospc_scope（ENOSPC 替身）
#   权限拒绝 fault_perm_deny（write / rename / manifest 三个时机）
#   并发     fault_gate_arm / fault_gate_wait / fault_gate_open / fault_concurrent_start
#   信号     fault_signal_kill（rename / manifest / recover 三个时机 x before/after）
#
# 观察契约（fault_snapshot 的输出，stdout 只给数据、日志一律 stderr）：
#   target.exists    目标文件在不在
#   target.state     missing | old | new | partial | changed（partial = 新内容的前半截）
#   target.size      目标文件字节数
#   target.sum       目标文件的 sha256
#   target.leftovers 目标所在目录里遗留的临时文件个数（半成品）
#   manifest.exists  清单在不在
#   manifest.state   missing | complete | partial（按结构判，不按字数猜）
#   manifest.leftovers / manifest.lines
#   user.exists / user.state（missing | intact | changed）/ user.size / user.sum
#
# 纪律：Bash 3.2 基线（没有 declare -A / ${v^^} / local -n / mapfile）；
# stdout 只给数据；出参用 printf -v；不改变调用方的 shell 选项。

# ---------------------------------------------------------------------------
# 注入配置（全局）。全部先给空值：调用方多半开着 set -u。
# ---------------------------------------------------------------------------
FAULT_DIR=""
FAULT_SHIM=""
FAULT_SCOPE=""
FAULT_ENOSPC=""
FAULT_PERM_PATH=""
FAULT_PERM_STAGE=""
FAULT_PERM_STICKY=""
FAULT_SIG_STAGE=""
FAULT_SIG_WHEN=""
FAULT_SIG_AT=1
FAULT_GATE_STAGE=""
FAULT_ULIMIT_F=""
FAULT_TRACE=""
FAULT_GATE_FILE=""
FAULT_GATE_MARK=""
FAULT_BG_PID=""
FAULT_REAL_MV="/bin/mv"
FAULT_REAL_CP="/bin/cp"
FAULT_REAL_MKTEMP="/bin/mktemp"

# fault_setup —— 建好注入工件目录与 PATH 替身（幂等）
#
# 替身放在独立目录里，只在 fault_run 的子 shell 里挂进 PATH ——
# 测试脚本自己用的 mv / cp / mktemp 一概不受影响。
fault_setup() {
  local __base=${FAULT_DIR:-}
  if [ -z "$__base" ]; then
    __base="${TEST_TMP_ROOT:-${TMPDIR:-/tmp}}/fault.$$"
  fi
  FAULT_DIR=$__base
  FAULT_SHIM="$FAULT_DIR/shim"
  FAULT_TRACE="$FAULT_DIR/trace"
  FAULT_GATE_FILE="$FAULT_DIR/gate"
  FAULT_GATE_MARK="$FAULT_DIR/gate.mark"
  if [ ! -d "$FAULT_SHIM" ]; then
    mkdir -p "$FAULT_SHIM" || return 1
    _fault_write_shims || return 1
  fi
  return 0
}

# fault_reset —— 清掉所有已配置的注入（保留替身目录）
fault_reset() {
  FAULT_SCOPE=""
  FAULT_ENOSPC=""
  FAULT_PERM_PATH=""
  FAULT_PERM_STAGE=""
  FAULT_PERM_STICKY=""
  FAULT_SIG_STAGE=""
  FAULT_SIG_WHEN=""
  FAULT_SIG_AT=1
  FAULT_GATE_STAGE=""
  FAULT_ULIMIT_F=""
  FAULT_BG_PID=""
  if [ -n "$FAULT_DIR" ] && [ -d "$FAULT_DIR" ]; then
    : >"$FAULT_TRACE"
    rm -f "$FAULT_GATE_FILE" "$FAULT_GATE_MARK"
  fi
  return 0
}

# fault_scope DIR —— 「工程目录」：rename 阶段判「这是工程自己的文件」的依据
fault_scope() {
  FAULT_SCOPE=${1:-}
  return 0
}

# fault_disk_full_limit BYTES —— 磁盘满（内核层）：RLIMIT_FSIZE 上限，字节
#
# 0 = 关闭。单位换算在 fault_run 里做（ulimit -f 的单位是 512 字节块）。
# 这是**进程级**的：必须靠 fault_run 把它限制在被测命令的子 shell 里，
# 否则会连测试脚本自己一起限死。
fault_disk_full_limit() {
  FAULT_ULIMIT_F=${1:-0}
  return 0
}

# fault_enospc_scope DIR —— 磁盘满（ENOSPC 替身）：只对这个目录下的写入生效
#
# macOS 没有 cgroup 配额，真造不出「磁盘满」。这里用 copy 替身模拟：
# 写到一半就报 No space left on device 并失败 —— 与内核 ENOSPC 的可观测
# 效果一致（临时文件只写了一半，rename 没发生，目标仍是旧内容）。
# 替身只认「目标是普通文件、源也是普通文件」的 copy，且排除 vendor 暂存目录。
fault_enospc_scope() {
  FAULT_ENOSPC=${1:-}
  return 0
}

# fault_perm_usable —— 权限注入在当前用户下是否真的有效（0=有效）
#
# root 不受权限位约束：chmod 500 拦不住 uid 0 的写入。compat 容器里跑的就是
# root，那种环境下这条注入永远不触发 —— 断言会把「注入没生效」误报成产品缺陷
# （CI run 43273232074 的 compat job 就是这么红的，issue #76）。
# 用法：权限类用例整块包在 `if fault_perm_usable; then ... else <NA> fi` 里。
fault_perm_usable() {
  [ "$(id -u)" != "0" ]
}

# fault_perm_deny PATH STAGE —— 权限拒绝：把 PATH 所在目录改成不可写
#
# STAGE 决定什么时候动手：
#   write    目标文件的临时文件刚要创建时（写前）
#   rename   临时文件已经写好、正要 rename 落到目标时
#   manifest 清单的临时文件已经写好、正要 rename 提交时
# 目录不可写 => 里面建不了新文件、也换不了名（macOS 与 Linux 语义一致）。
fault_perm_deny() {
  FAULT_PERM_PATH=${1:-}
  FAULT_PERM_STAGE=${2:-}
  FAULT_PERM_STICKY=""
  return 0
}

# fault_perm_deny_sticky PATH STAGE —— 权限拒绝，且**不恢复**
#
# 默认的 fault_perm_deny 是一次性的：拒绝那一次操作之后立刻把权限恢复。
# 理由：目录不可写的时候连「删掉临时文件」都做不到 —— 磁盘上会留下删不掉的
# 残骸，测到的就不是「写失败」，而是「目录整个坏了」。想看持续不可写会怎样，
# 用这个（它对应真实的「磁盘只读 / 权限被改错」那种现场）。
fault_perm_deny_sticky() {
  FAULT_PERM_PATH=${1:-}
  FAULT_PERM_STAGE=${2:-}
  FAULT_PERM_STICKY="1"
  return 0
}

# fault_signal_kill STAGE [WHEN] [AT] —— 信号注入：在指定时机 SIGKILL 被测进程
#
# STAGE 决定哪一次 rename 算数：
#   rename   换工程文件的那次（工程目录里的普通文件）
#   manifest 提交清单的那次
#   recover  整体换名的第一次（旧副本挪开、新的还没换上）
# WHEN 决定动手的先后：
#   after    先让 rename 落地，再杀（= 「文件已换新、清单还没提交」那个窗口）
#   before   rename 还没落地就杀
# AT 是第几次匹配时动手（默认 1）。
fault_signal_kill() {
  FAULT_SIG_STAGE=${1:-}
  FAULT_SIG_WHEN=${2:-after}
  FAULT_SIG_AT=${3:-1}
  return 0
}

# fault_gate_arm STAGE —— 并发编排：在指定时机把被测进程拦住
#
# 拦住之后进程一直等 fault_gate_open —— 于是它**持着工程锁**停在那里，
# 第二个实例此时上来必须明确失败，而不是两份清单互相覆盖。
fault_gate_arm() {
  FAULT_GATE_STAGE=${1:-rename}
  return 0
}

# fault_gate_wait [SEC] —— 等到被测进程真的被拦住（默认最多 30 秒）
fault_gate_wait() {
  local __max=${1:-30} __i=0
  if [ -z "$FAULT_GATE_MARK" ]; then
    return 1
  fi
  while [ ! -f "$FAULT_GATE_MARK" ]; do
    __i=$((__i + 1))
    if [ "$__i" -ge "$__max" ]; then
      return 1
    fi
    sleep 1
  done
  return 0
}

# fault_gate_open —— 放行被拦住的进程
fault_gate_open() {
  if [ -z "$FAULT_GATE_FILE" ]; then
    return 1
  fi
  : >"$FAULT_GATE_FILE"
  return 0
}

# fault_run CMD... —— 带上当前配置的所有注入，在子 shell 里跑 CMD
#
# 子 shell 是必须的：ulimit -f 是进程级的，写文件权限也是进程级的 ——
# 放在这里就不会波及测试脚本自身。退出码就是被测命令的退出码。
fault_run() {
  local __cmd=${1:-} __seq=0
  if [ -z "$__cmd" ]; then
    return 2
  fi
  shift
  fault_setup || return 1
  # 每次运行用独立的计数文件：信号注入「第 N 次」不能跨运行累加。
  # 序号写文件而不是写变量：后台调用时变量改动会丢。
  printf 'x\n' >>"$FAULT_DIR/seq"
  __seq=$(wc -l <"$FAULT_DIR/seq" | tr -d ' ')
  (
    PATH="$FAULT_SHIM:$PATH"
    export PATH
    export FAULT_DIR FAULT_SHIM FAULT_SCOPE FAULT_ENOSPC FAULT_PERM_PATH
    export FAULT_PERM_STAGE FAULT_PERM_STICKY FAULT_SIG_STAGE FAULT_SIG_WHEN FAULT_SIG_AT
    export FAULT_GATE_STAGE FAULT_ULIMIT_F FAULT_TRACE FAULT_GATE_FILE
    export FAULT_GATE_MARK FAULT_REAL_MV FAULT_REAL_CP FAULT_REAL_MKTEMP
    FAULT_COUNT_FILE="$FAULT_DIR/count.$__seq"
    export FAULT_COUNT_FILE
    if [ -n "$FAULT_ULIMIT_F" ] && [ "$FAULT_ULIMIT_F" -gt 0 ] 2>/dev/null; then
      # 忽略 SIGXFSZ：超限就变成「写失败」（EFBIG），而不是把进程打死。
      # 不忽略的话，被测命令是被信号杀掉的 —— 那是另一类注入（信号注入）。
      trap '' XFSZ
      ulimit -f "$(((FAULT_ULIMIT_F + 511) / 512))" 2>/dev/null || true
    fi
    exec "$__cmd" "$@"
  )
}

# fault_concurrent_start CMD... —— 后台跑一个命令（带注入），pid 放进 FAULT_BG_PID
#
# 输出落在 $FAULT_DIR/bg.out 与 $FAULT_DIR/bg.err。
fault_concurrent_start() {
  local __cmd=${1:-}
  if [ -z "$__cmd" ]; then
    return 2
  fi
  shift
  fault_setup || return 1
  (
    fault_run "$__cmd" "$@" >"$FAULT_DIR/bg.out" 2>"$FAULT_DIR/bg.err"
  ) &
  FAULT_BG_PID=$!
  return 0
}

# fault_concurrent_wait —— 等后台那个实例收工，返回它的退出码
fault_concurrent_wait() {
  local __rc=0
  if [ -z "$FAULT_BG_PID" ]; then
    return 1
  fi
  wait "$FAULT_BG_PID" || __rc=$?
  FAULT_BG_PID=""
  return "$__rc"
}

# ---------------------------------------------------------------------------
# 观察契约
# ---------------------------------------------------------------------------

# fault_sum FILE —— 文件的 sha256（文件不在就返回 1）
fault_sum() {
  local __f=${1:-} __out=""
  if [ -z "$__f" ] || [ ! -f "$__f" ]; then
    return 1
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    __out=$(sha256sum "$__f" | awk '{print $1}')
  elif command -v shasum >/dev/null 2>&1; then
    __out=$(shasum -a 256 "$__f" | awk '{print $1}')
  else
    __out=$(openssl dgst -sha256 "$__f" | awk '{print $NF}')
  fi
  printf '%s' "$__out"
  return 0
}

# fault_size FILE —— 文件字节数（取不到就返回 1）
fault_size() {
  local __f=${1:-} __out=""
  if [ -z "$__f" ] || [ ! -f "$__f" ]; then
    return 1
  fi
  __out=$(wc -c <"$__f" | tr -d ' ')
  case "$__out" in
    '' | *[!0-9]*) return 1 ;;
  esac
  printf '%s' "$__out"
  return 0
}

# fault_file_state FILE OLD_FILE NEW_FILE —— missing | old | new | partial | changed
#
# partial = 文件存在、内容既不是旧的也不是新的、而且是「新内容的一个真前缀」
# —— 这正是「写到一半」的形态。原子写做对了的话，target 永远不会是 partial。
fault_file_state() {
  local __f=${1:-} __old=${2:-} __new=${3:-} __n=0 __m=0
  if [ -z "$__f" ] || [ ! -f "$__f" ]; then
    printf 'missing'
    return 0
  fi
  if [ -n "$__old" ] && [ -f "$__old" ]; then
    if [ "$(fault_sum "$__f")" = "$(fault_sum "$__old")" ]; then
      printf 'old'
      return 0
    fi
  fi
  if [ -n "$__new" ] && [ -f "$__new" ]; then
    if [ "$(fault_sum "$__f")" = "$(fault_sum "$__new")" ]; then
      printf 'new'
      return 0
    fi
    __n=$(fault_size "$__f") || __n=0
    __m=$(fault_size "$__new") || __m=0
    if [ "$__n" -lt "$__m" ] && _fault_is_prefix "$__new" "$__f" "$__n"; then
      printf 'partial'
      return 0
    fi
  fi
  printf 'changed'
  return 0
}

# _fault_is_prefix NEW FILE N —— FILE 是不是 NEW 的前 N 个字节
_fault_is_prefix() {
  local __new=${1:-} __f=${2:-} __n=${3:-0} __tmp
  __tmp=$(mktemp "${TMPDIR:-/tmp}/faultpfx.XXXXXX") || return 1
  if head -c "$__n" "$__new" >"$__tmp" 2>/dev/null; then
    if cmp -s "$__tmp" "$__f"; then
      rm -f "$__tmp"
      return 0
    fi
  fi
  rm -f "$__tmp"
  return 1
}

# fault_manifest_state FILE —— missing | complete | partial
#
# 判「完整」看结构，不看字数：首行对不对、关键字段在不在、结尾是不是换行。
# 半截清单通常是「首行有了、后面没了」或者「结尾没有换行」。
fault_manifest_state() {
  local __f=${1:-} __first="" __body="" __nl=0
  if [ -z "$__f" ] || [ ! -f "$__f" ]; then
    printf 'missing'
    return 0
  fi
  __first=$(head -1 "$__f" 2>/dev/null || true)
  if [ "$__first" != "# shellkit manifest v1" ]; then
    printf 'partial'
    return 0
  fi
  __body=$(cat "$__f" 2>/dev/null || true)
  case "$__body" in
    *"manifest_version="*) ;;
    *)
      printf 'partial'
      return 0
      ;;
  esac
  case "$__body" in
    *"name="*) ;;
    *)
      printf 'partial'
      return 0
      ;;
  esac
  # 结尾必须是换行：被截断的文件通常没有
  __nl=$(tail -c 1 "$__f" | wc -l | tr -d ' ')
  case "$__nl" in
    1) ;;
    *)
      printf 'partial'
      return 0
      ;;
  esac
  printf 'complete'
  return 0
}

# fault_count_tmp DIR PATTERN —— 目录里匹配 PATTERN 的临时文件个数（半成品）
fault_count_tmp() {
  local __dir=${1:-} __pat=${2:-*.tmp.*} __f __n=0
  if [ -z "$__dir" ] || [ ! -d "$__dir" ]; then
    printf '0'
    return 0
  fi
  for __f in "$__dir"/$__pat; do
    [ -e "$__f" ] || continue
    __n=$((__n + 1))
  done
  printf '%s' "$__n"
  return 0
}

# fault_snapshot TARGET OLD NEW MANIFEST [USER] [USER_SUM]
#
# 打印磁盘最终状态（key=value，一行一个）。这是四类注入点共用的观察契约：
#   TARGET   被写的目标文件
#   OLD      目标文件的「旧版本」副本（用来判 old）
#   NEW      目标文件的「新版本」副本（用来判 new / partial）
#   MANIFEST 清单文件
#   USER     用户自己加的数据文件（可选）
#   USER_SUM 这个数据文件在注入前的 sha256（可选，用来判 intact）
fault_snapshot() {
  local __target=${1:-} __old=${2:-} __new=${3:-} __manifest=${4:-}
  local __user=${5:-} __usersum=${6:-}
  local __dir __exists=0 __state __sum __size __lines
  local __mexists=0 __mstate __mleft
  local __uexists=0 __ustate

  __dir=$(dirname "$__target")

  if [ -n "$__target" ] && [ -f "$__target" ]; then
    __exists=1
  fi
  __state=$(fault_file_state "$__target" "$__old" "$__new")
  __sum=$(fault_sum "$__target" 2>/dev/null || true)
  __size=$(fault_size "$__target" 2>/dev/null || true)
  __left=$(fault_count_tmp "$__dir" "*.tmp.*")

  printf 'target.exists=%s\n' "$__exists"
  printf 'target.state=%s\n' "$__state"
  printf 'target.size=%s\n' "${__size:-0}"
  printf 'target.sum=%s\n' "$__sum"
  printf 'target.leftovers=%s\n' "$__left"

  if [ -n "$__manifest" ] && [ -f "$__manifest" ]; then
    __mexists=1
  fi
  __mstate=$(fault_manifest_state "$__manifest")
  __mleft=$(fault_count_tmp "$(dirname "$__manifest")" ".shellkit-manifest.tmp.*")
  __lines=$(wc -l <"$__manifest" 2>/dev/null | tr -d ' ')
  printf 'manifest.exists=%s\n' "$__mexists"
  printf 'manifest.state=%s\n' "$__mstate"
  printf 'manifest.leftovers=%s\n' "$__mleft"
  printf 'manifest.lines=%s\n' "${__lines:-0}"

  if [ -n "$__user" ]; then
    if [ -f "$__user" ]; then
      __uexists=1
    fi
    __sum=$(fault_sum "$__user" 2>/dev/null || true)
    __size=$(fault_size "$__user" 2>/dev/null || true)
    if [ "$__uexists" = "0" ]; then
      __ustate="missing"
    elif [ -n "$__usersum" ] && [ "$__sum" = "$__usersum" ]; then
      __ustate="intact"
    else
      __ustate="changed"
    fi
    printf 'user.exists=%s\n' "$__uexists"
    printf 'user.state=%s\n' "$__ustate"
    printf 'user.size=%s\n' "${__size:-0}"
    printf 'user.sum=%s\n' "$__sum"
  fi
  return 0
}

# fault_trace_has PATTERN —— 注入痕迹里有没有这一条（纯 bash 匹配，不用管道）
fault_trace_has() {
  local __pat=${1:-} __line
  if [ -z "$__pat" ] || [ -z "$FAULT_TRACE" ] || [ ! -f "$FAULT_TRACE" ]; then
    return 1
  fi
  while IFS= read -r __line; do
    case "$__line" in
      *"$__pat"*) return 0 ;;
    esac
  done <"$FAULT_TRACE"
  return 1
}

# fault_trace_line PATTERN —— 打印第一条匹配的痕迹（没有就返回 1）
fault_trace_line() {
  local __pat=${1:-} __line
  if [ -z "$__pat" ] || [ -z "$FAULT_TRACE" ] || [ ! -f "$FAULT_TRACE" ]; then
    return 1
  fi
  while IFS= read -r __line; do
    case "$__line" in
      *"$__pat"*)
        printf '%s\n' "$__line"
        return 0
        ;;
    esac
  done <"$FAULT_TRACE"
  return 1
}

# ---------------------------------------------------------------------------
# PATH 替身：mv / cp / mktemp
#
# 替身按环境变量里的配置行事，没配就原样放行 —— 装了替身不改变行为，
# 只在被明确指定的那一次动手。
#
# 替身脚本里的美元符号全部原样保留（heredoc 加引号，不做任何展开），
# 真正的 mv / cp / mktemp 由环境变量 FAULT_REAL_* 指路，避免替身调到自己。
# ---------------------------------------------------------------------------
_fault_write_shims() {
  local __which __real
  for __which in mv cp mktemp; do
    __real=$(command -v "$__which" 2>/dev/null || true)
    if [ -z "$__real" ]; then
      __real="/bin/$__which"
    fi
    case "$__which" in
      mv) FAULT_REAL_MV=$__real ;;
      cp) FAULT_REAL_CP=$__real ;;
      mktemp) FAULT_REAL_MKTEMP=$__real ;;
    esac
  done

  cat >"$FAULT_SHIM/mv" <<'FAULT_MV_EOF'
#!/bin/sh
# fault.sh 的 rename 替身
# fault_phys PATH —— 该路径的物理写法（与库内部 pwd -P 的口径对齐）
#
# 同一个目录可能被写成 /var/... 或 /private/var/...（macOS 的符号链接）：
# 产品内部按 pwd -P 落盘，测试按创建时的写法给 scope —— 只认一种写法，
# 注入会静默落空（断言拿到 rc=0，看起来像「注入没生效」）。
fault_phys() {
  fp=$1
  if [ -z "$fp" ]; then
    return 0
  fi
  if [ -d "$fp" ]; then
    (cd "$fp" 2>/dev/null && pwd -P) || printf "%s" "$fp"
  else
    fd=$(dirname "$fp")
    fb=$(basename "$fp")
    if [ -d "$fd" ]; then
      printf "%s/%s" "$(cd "$fd" 2>/dev/null && pwd -P)" "$fb"
    else
      printf "%s" "$fp"
    fi
  fi
}
：按注入配置决定放行 / 改权限 / 拦住 / 杀父进程。
# 配置全在环境变量里（fault_run 负责导出）。
dest=""
for a in "$@"; do dest="$a"; done

# fault_mode DIR —— 目录现在的权限位（八进制）；取不到就返回空
fault_mode() {
  m=""
  if ! m=$(stat -f '%Lp' "$1" 2>/dev/null); then
    m=$(stat -c '%a' "$1" 2>/dev/null) || m=""
  fi
  case "$m" in
  '' | *[!0-7]*) m="" ;;
  esac
  printf '%s' "$m"
}

stage=""
skip=0
case "${dest##*/}" in
.shellkit-manifest) stage=manifest ;;
.shellkit-upgrade-journal) skip=1 ;;
esac
if [ "$skip" = "0" ]; then
  case "$dest" in
  *.old | */.shellkit-old) stage=recover ;;
  esac
fi
if [ "$skip" = "0" ] && [ -z "$stage" ] && [ -n "${FAULT_SCOPE:-}" ]; then
  case "$dest" in
  "$FAULT_SCOPE"/* | "$(fault_phys "$FAULT_SCOPE")"/*) stage=rename ;;
  esac
  # vendor 的暂存目录与库目录不算「工程自己的文件」
  case "$dest" in
  */vendor/* | */.shellkit-new/*) stage="" ;;
  esac
fi

# 1) 拦住（并发编排用）：等放行闸门出现
if [ -n "${FAULT_GATE_STAGE:-}" ] && [ "$stage" = "$FAULT_GATE_STAGE" ]; then
  : >"$FAULT_GATE_MARK"
  echo "gate stage=$stage dest=$dest" >>"$FAULT_TRACE"
  i=0
  while [ ! -f "$FAULT_GATE_FILE" ]; do
    i=$((i + 1))
    if [ "$i" -gt 600 ]; then break; fi
    sleep 0.1 2>/dev/null || sleep 1
  done
fi

# 2) 权限拒绝：把目标所在目录改成不可写（之后 rename 必然失败）
perm_dir=""
perm_mode=""
if [ -n "${FAULT_PERM_PATH:-}" ] && { [ "$dest" = "$FAULT_PERM_PATH" ] || [ "$dest" = "$(fault_phys "$FAULT_PERM_PATH")" ]; }; then
  case "${FAULT_PERM_STAGE:-}" in
  rename)
    perm_dir=$(dirname "$dest")
    perm_mode=$(fault_mode "$perm_dir")
    chmod 500 "$perm_dir" 2>/dev/null
    echo "perm stage=rename path=$dest" >>"$FAULT_TRACE"
    ;;
  manifest)
    perm_dir=$(dirname "$dest")
    perm_mode=$(fault_mode "$perm_dir")
    chmod 500 "$perm_dir" 2>/dev/null
    echo "perm stage=manifest path=$dest" >>"$FAULT_TRACE"
    ;;
  esac
fi

# 3) 信号注入：数到第 N 次就杀掉父进程
if [ -n "${FAULT_SIG_STAGE:-}" ] && [ "$stage" = "$FAULT_SIG_STAGE" ]; then
  n=0
  if [ -f "${FAULT_COUNT_FILE:-/dev/null}" ]; then
    n=$(cat "$FAULT_COUNT_FILE" 2>/dev/null || printf '0')
  fi
  case "$n" in
  '' | *[!0-9]*) n=0 ;;
  esac
  n=$((n + 1))
  printf '%s' "$n" >"$FAULT_COUNT_FILE"
  if [ "$n" -ge "${FAULT_SIG_AT:-1}" ]; then
    if [ "${FAULT_SIG_WHEN:-after}" = "before" ]; then
      echo "sig when=before stage=$stage n=$n dest=$dest" >>"$FAULT_TRACE"
      kill -9 "$PPID"
      exit 1
    fi
    "$FAULT_REAL_MV" "$@" || exit $?
    echo "sig when=after stage=$stage n=$n dest=$dest" >>"$FAULT_TRACE"
    kill -9 "$PPID"
    exit 1
  fi
fi

if [ -n "$perm_dir" ]; then
  "$FAULT_REAL_MV" "$@"
  rc=$?
  # 一次性注入：拒绝完这一次就把权限还回去（否则连临时文件都删不掉）
  if [ -z "${FAULT_PERM_STICKY:-}" ] && [ -n "$perm_mode" ]; then
    chmod "$perm_mode" "$perm_dir" 2>/dev/null
  fi
  exit $rc
fi

exec "$FAULT_REAL_MV" "$@"
FAULT_MV_EOF

  cat >"$FAULT_SHIM/cp" <<'FAULT_CP_EOF'
#!/bin/sh
# fault.sh 的 copy 替身
# fault_phys PATH —— 该路径的物理写法（与库内部 pwd -P 的口径对齐）
#
# 同一个目录可能被写成 /var/... 或 /private/var/...（macOS 的符号链接）：
# 产品内部按 pwd -P 落盘，测试按创建时的写法给 scope —— 只认一种写法，
# 注入会静默落空（断言拿到 rc=0，看起来像「注入没生效」）。
fault_phys() {
  fp=$1
  if [ -z "$fp" ]; then
    return 0
  fi
  if [ -d "$fp" ]; then
    (cd "$fp" 2>/dev/null && pwd -P) || printf "%s" "$fp"
  else
    fd=$(dirname "$fp")
    fb=$(basename "$fp")
    if [ -d "$fd" ]; then
      printf "%s/%s" "$(cd "$fd" 2>/dev/null && pwd -P)" "$fb"
    else
      printf "%s" "$fp"
    fi
  fi
}
：磁盘满（ENOSPC）替身。
# macOS 没有 cgroup 配额，真造不出「磁盘满」；这里写到一半就报
# No space left on device 并失败 —— 可观测效果与内核 ENOSPC 一致：
# 临时文件只写了一半，rename 没发生，目标仍是旧内容。
src=""
prev=""
for a in "$@"; do
  case "$a" in
  -*) continue ;;
  esac
  src="$prev"
  prev="$a"
done
dest="$prev"

if [ -n "${FAULT_ENOSPC:-}" ] && [ -n "$src" ] && [ -n "$dest" ] && [ -f "$src" ]; then
  case "$dest" in
  "$FAULT_ENOSPC"/* | "$(fault_phys "$FAULT_ENOSPC")"/*)
    case "$dest" in
    */vendor/* | */.shellkit-new/*) : ;;
    *)
      total=$(wc -c <"$src" | tr -d ' ')
      case "$total" in
      '' | *[!0-9]*) total=0 ;;
      esac
      half=$((total / 2))
      head -c "$half" "$src" >"$dest" 2>/dev/null
      wrote=$(wc -c <"$dest" 2>/dev/null | tr -d ' ')
      case "$wrote" in
      '' | *[!0-9]*) wrote=0 ;;
      esac
      echo "enospc wrote=$wrote of=$total src=$src dst=$dest" >>"$FAULT_TRACE"
      echo "cp: $dest: No space left on device" >&2
      exit 1
      ;;
    esac
  esac
fi

exec "$FAULT_REAL_CP" "$@"
FAULT_CP_EOF

  cat >"$FAULT_SHIM/mktemp" <<'FAULT_MKTEMP_EOF'
#!/bin/sh
# fault.sh 的临时文件替身
# fault_phys PATH —— 该路径的物理写法（与库内部 pwd -P 的口径对齐）
#
# 同一个目录可能被写成 /var/... 或 /private/var/...（macOS 的符号链接）：
# 产品内部按 pwd -P 落盘，测试按创建时的写法给 scope —— 只认一种写法，
# 注入会静默落空（断言拿到 rc=0，看起来像「注入没生效」）。
fault_phys() {
  fp=$1
  if [ -z "$fp" ]; then
    return 0
  fi
  if [ -d "$fp" ]; then
    (cd "$fp" 2>/dev/null && pwd -P) || printf "%s" "$fp"
  else
    fd=$(dirname "$fp")
    fb=$(basename "$fp")
    if [ -d "$fd" ]; then
      printf "%s/%s" "$(cd "$fd" 2>/dev/null && pwd -P)" "$fb"
    else
      printf "%s" "$fp"
    fi
  fi
}
：权限注入的「写前」时机靠它触发
# （写文件靠的是「目录可写」：目录不可写时连临时文件都建不出来）。
tmpl=""
for a in "$@"; do tmpl="$a"; done

# fault_mode DIR —— 目录现在的权限位（八进制）；取不到就返回空
fault_mode() {
  m=""
  if ! m=$(stat -f '%Lp' "$1" 2>/dev/null); then
    m=$(stat -c '%a' "$1" 2>/dev/null) || m=""
  fi
  case "$m" in
  '' | *[!0-7]*) m="" ;;
  esac
  printf '%s' "$m"
}

if [ "${FAULT_PERM_STAGE:-}" = "write" ] && [ -n "${FAULT_PERM_PATH:-}" ]; then
  # FAULT_PERM_PATH 支持 glob：写目标在阶段目录里、目录名带 pid 的场景
  # （skill 安装的整组事务提交，issue #86）没法预先点名，用
  # .shellkit-skill-new.*/FILE 这样的模式点。没有 glob 元字符时，case 的
  # 模式按字面解释，与旧的逐字匹配完全等价。
  case "$tmpl" in
  $FAULT_PERM_PATH.tmp.* | "$(fault_phys "$FAULT_PERM_PATH")".tmp.*)
    # 目录取自真实模板：glob 模式下 dirname 模式串取不到真目录
    dir=$(dirname "$tmpl")
    mode=$(fault_mode "$dir")
    chmod 500 "$dir" 2>/dev/null
    echo "perm stage=write path=$FAULT_PERM_PATH" >>"$FAULT_TRACE"
    "$FAULT_REAL_MKTEMP" "$@"
    rc=$?
    # 一次性注入：拒绝完这一次就把权限还回去（否则连临时文件都删不掉）
    if [ -z "${FAULT_PERM_STICKY:-}" ] && [ -n "$mode" ]; then
      chmod "$mode" "$dir" 2>/dev/null
    fi
    exit $rc
    ;;
  esac
fi

exec "$FAULT_REAL_MKTEMP" "$@"
FAULT_MKTEMP_EOF

  chmod +x "$FAULT_SHIM/mv" "$FAULT_SHIM/cp" "$FAULT_SHIM/mktemp"
  return 0
}
