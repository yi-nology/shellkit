#!/bin/sh
#
# shellkit 的 POSIX 子集：设备侧（busybox ash / dash / POSIX sh）能用的一小撮。
#
# 为什么单独一份：主库的基线是 Bash 3.2+，内部用了数组等 bash 专有语法
# （mapfile / printf -v / 大写展开 / local -n ...），在 busybox ash 上**根本解析不了**
# —— 不是「运行报错」，是「脚本起不来」。
#
# 设备侧脚本（NAS 的 start/stop、OpenWrt 的 init 脚本）是「装机即执行」的：
# 改坏的现场装不了 shellkit 补救 ⇒ 那边的脚本必须是**最保守**的那一份。
# 这一份就是那份保守实现：宁可少给能力，也不给一个在 ash 上会炸的函数。
#
# 这一份的规矩（tools/check_posix.sh 逐条查）：
#   - 只用 POSIX sh 语法：没有数组、没有 [[ ]]、没有 local、没有 printf -v、
#     没有大写展开、没有 mapfile、没有 += ；
#   - 没有 source（POSIX 用 .）；
#   - 函数里的自变量用**专属变量名**（没有 local，名字会串到别的函数里）。
#
# 入口统一：设备侧脚本是 #!/bin/sh，用 . 引这份库：
#
#     . /opt/pioneer/lib/shellkit-posix.sh
#     log_info "starting"
#     retry 3 my_command --flag
#
# 能用哪些函数：看同目录的 capabilities.tsv；运行时也能问：
#
#     if posix_capable net_download; then ... fi

# ---- 日志（stdout 只给数据，日志一律 stderr）----

# _sk_posix_log_rank LEVEL —— 级别序号（数字大 = 更严重）
_sk_posix_log_rank() {
  case "${1:-info}" in
    debug) printf '10' ;;
    info) printf '20' ;;
    ok) printf '20' ;;
    warn) printf '30' ;;
    error) printf '40' ;;
    *) printf '20' ;;
  esac
}

# _sk_posix_should_log LEVEL —— 这个级别要不要打印
_sk_posix_should_log() {
  _sp_want=$(_sk_posix_log_rank "${1:-info}")
  _sp_have=$(_sk_posix_log_rank "${SHELLKIT_LOG_LEVEL:-info}")
  [ "$_sp_want" -ge "$_sp_have" ]
}

# _sk_posix_log LEVEL MESSAGE —— 打一行日志
_sk_posix_log() {
  printf '[%s] %s\n' "${1:-INFO}" "${2:-}" >&2
}

# log_info MESSAGE —— 普通信息
log_info() {
  _sk_posix_should_log info || return 0
  _sk_posix_log INFO "${1:-}"
}

# log_ok MESSAGE —— 成功
log_ok() {
  _sk_posix_should_log info || return 0
  _sk_posix_log OK "${1:-}"
}

# log_warn MESSAGE —— 警告
log_warn() {
  _sk_posix_should_log warn || return 0
  _sk_posix_log WARN "${1:-}"
}

# log_error MESSAGE —— 错误
log_error() {
  _sk_posix_should_log error || return 0
  _sk_posix_log ERROR "${1:-}"
}

# log_debug MESSAGE —— 调试信息（默认级别 info ⇒ 不打印）
log_debug() {
  _sk_posix_should_log debug || return 0
  _sk_posix_log DEBUG "${1:-}"
}

# log_section TITLE —— 小节标题
log_section() {
  printf '\n== %s ==\n' "${1:-}" >&2
}

# ---- 失败与前置条件 ----

# fail MESSAGE [CODE] —— 报错并返回（不退出）
fail() {
  _sp_fail_code=1
  if [ "$#" -ge 2 ]; then
    _sp_fail_code=$2
  fi
  log_error "${1:-}"
  return "$_sp_fail_code"
}

# die MESSAGE [CODE] —— 报错并退出
die() {
  _sp_die_code=1
  if [ "$#" -ge 2 ]; then
    _sp_die_code=$2
  fi
  log_error "${1:-}"
  exit "$_sp_die_code"
}

# ---- 清理栈 ----

_SK_POSIX_TRAP_CMDS=""

# trap_push COMMAND —— 登记一条退出时要执行的命令（后进先出）
trap_push() {
  if [ "$#" -lt 1 ] || [ -z "$1" ]; then
    return 2
  fi
  _SK_POSIX_TRAP_CMDS="$1
$_SK_POSIX_TRAP_CMDS"
  return 0
}

# _sk_posix_trap_run —— 退出时的清理（保留原退出码）
_sk_posix_trap_run() {
  _sp_trap_status=$?
  trap - 0 1 2 15
  if [ -n "$_SK_POSIX_TRAP_CMDS" ]; then
    eval "$_SK_POSIX_TRAP_CMDS"
  fi
  exit "$_sp_trap_status"
}

# trap_install —— 装上退出/信号清理
trap_install() {
  trap '_sk_posix_trap_run' 0 1 2 15
  return 0
}

# ---- 重试 ----

# retry ATTEMPTS COMMAND... —— 失败重试
#
# 用法错（退出码 2）不重试 —— 重试一个用法错只是把同一个错误重复几遍。
retry() {
  if [ "$#" -lt 2 ]; then
    log_error "usage: retry ATTEMPTS COMMAND..."
    return 2
  fi
  _sp_retry_n=$1
  shift
  case "$_sp_retry_n" in
    '' | *[!0-9]*)
      log_error "invalid retry count: $_sp_retry_n"
      return 2
      ;;
  esac
  if [ "$_sp_retry_n" -lt 1 ]; then
    log_error "invalid retry count: $_sp_retry_n"
    return 2
  fi
  _sp_retry_i=0
  while [ "$_sp_retry_i" -lt "$_sp_retry_n" ]; do
    "$@"
    _sp_retry_rc=$?
    if [ "$_sp_retry_rc" -eq 0 ]; then
      return 0
    fi
    if [ "$_sp_retry_rc" -eq 2 ]; then
      return "$_sp_retry_rc"
    fi
    _sp_retry_i=$((_sp_retry_i + 1))
    if [ "$_sp_retry_i" -ge "$_sp_retry_n" ]; then
      log_error "giving up after retries: $_sp_retry_n (exit $_sp_retry_rc)"
      return "$_sp_retry_rc"
    fi
    log_warn "attempt failed, retrying: $_sp_retry_i/$_sp_retry_n (exit $_sp_retry_rc)"
    sleep "${SHELLKIT_RETRY_DELAY:-1}"
  done
  return 1
}

# ---- 文件与目录 ----

# fs_ensure_dir DIR [MODE] —— 建目录（已存在就算成功）
fs_ensure_dir() {
  if [ "$#" -lt 1 ] || [ -z "$1" ]; then
    return 2
  fi
  if [ -d "$1" ]; then
    return 0
  fi
  mkdir -p "$1" || return 1
  if [ "$#" -ge 2 ] && [ -n "$2" ]; then
    chmod "$2" "$1" || return 1
  fi
  return 0
}

# fs_ensure_file FILE [CONTENT] —— 写文件（不存在才写）
fs_ensure_file() {
  if [ "$#" -lt 1 ] || [ -z "$1" ]; then
    return 2
  fi
  if [ -f "$1" ]; then
    return 0
  fi
  if [ "$#" -ge 2 ]; then
    printf '%s\n' "$2" >"$1" || return 1
  else
    : >"$1" || return 1
  fi
  return 0
}

# ---- 下载与校验 ----

# net_sha256 FILE —— 算 sha256（stdout 是摘要）
net_sha256() {
  if [ "$#" -lt 1 ]; then
    return 2
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d ' ' -f1
  else
    return 1
  fi
}

# net_verify FILE SHA256 —— 校验（5 = 不一致）
net_verify() {
  if [ "$#" -lt 2 ]; then
    return 2
  fi
  _sp_v_sum=$(net_sha256 "$1") || {
    log_error "cannot compute checksum for: $1"
    return 5
  }
  if [ "$_sp_v_sum" = "$2" ]; then
    return 0
  fi
  log_error "checksum mismatch for: $1"
  return 5
}

# net_download URL DEST [SHA256] —— 下载（可选校验）
net_download() {
  if [ "$#" -lt 2 ]; then
    log_error "usage: net_download URL DEST [SHA256]"
    return 2
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1" -o "$2" || return 1
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$2" "$1" || return 1
  else
    log_error "curl or wget is required to download"
    return 3
  fi
  if [ "$#" -ge 3 ] && [ -n "$3" ]; then
    net_verify "$2" "$3" || return $?
  fi
  return 0
}

# ---- 配置（环境变量 > 配置文件 > 默认值）----

_SK_POSIX_CONF=""

# conf_init FILE —— 指定配置文件
conf_init() {
  if [ "$#" -lt 1 ] || [ -z "$1" ]; then
    return 2
  fi
  _SK_POSIX_CONF=$1
  return 0
}

# _sk_posix_valid_name NAME —— 合法的变量名吗（eval 之前必须查）
_sk_posix_valid_name() {
  case "${1:-}" in
    '' | *[!A-Za-z0-9_]*) return 1 ;;
  esac
  return 0
}

# conf_get_any KEY DEFAULT —— 取配置值
conf_get_any() {
  if [ "$#" -lt 2 ]; then
    return 2
  fi
  if ! _sk_posix_valid_name "$1"; then
    printf '%s\n' "$2"
    return 2
  fi
  # 环境变量优先。用 printenv 而不是 eval 间接引用：POSIX 没有 ${!var}，
  # eval 那一套既能注入又过不了 shellcheck 的 sh 方言；printenv 是标准命令，
  # 键名查过了，取不到就是取不到（不报错，落到配置文件与默认值）。
  _sp_c_env=$(printenv "$1" 2>/dev/null || true)
  if [ -n "$_sp_c_env" ]; then
    printf '%s\n' "$_sp_c_env"
    return 0
  fi
  if [ -n "$_SK_POSIX_CONF" ] && [ -r "$_SK_POSIX_CONF" ]; then
    while IFS= read -r _sp_c_line || [ -n "$_sp_c_line" ]; do
      case "$_sp_c_line" in
        "$1="*)
          printf '%s\n' "${_sp_c_line#*=}"
          return 0
          ;;
      esac
    done <"$_SK_POSIX_CONF"
  fi
  printf '%s\n' "$2"
  return 0
}

# ---- 版本比较（纯 POSIX 分段比较）----

# ver_cmp A B —— -1 / 0 / 1
ver_cmp() {
  if [ "$#" -lt 2 ]; then
    return 2
  fi
  _sp_vc_a=$(printf '%s\n' "$1" | tr '.' ' ')
  _sp_vc_b=$(printf '%s\n' "$2" | tr '.' ' ')
  _sp_vc_i=1
  while [ "$_sp_vc_i" -le 20 ]; do
    _sp_vc_x=$(printf '%s\n' "$_sp_vc_a" | cut -d ' ' -f"$_sp_vc_i")
    _sp_vc_y=$(printf '%s\n' "$_sp_vc_b" | cut -d ' ' -f"$_sp_vc_i")
    [ -n "$_sp_vc_x" ] || _sp_vc_x=0
    [ -n "$_sp_vc_y" ] || _sp_vc_y=0
    case "$_sp_vc_x" in
      *[!0-9]*)
        return 2
        ;;
    esac
    case "$_sp_vc_y" in
      *[!0-9]*)
        return 2
        ;;
    esac
    if [ "$_sp_vc_x" -gt "$_sp_vc_y" ]; then
      printf '%s\n' 1
      return 0
    fi
    if [ "$_sp_vc_x" -lt "$_sp_vc_y" ]; then
      printf '%s\n' -1
      return 0
    fi
    _sp_vc_i=$((_sp_vc_i + 1))
  done
  printf '%s\n' 0
  return 0
}

# ver_gt A B —— A > B 吗
ver_gt() {
  _sp_vg=$(ver_cmp "$1" "$2") || return $?
  [ "$_sp_vg" = "1" ]
}

# ver_lt A B —— A < B 吗
ver_lt() {
  _sp_vl=$(ver_cmp "$1" "$2") || return $?
  [ "$_sp_vl" = "-1" ]
}

# ver_eq A B —— A == B 吗
ver_eq() {
  _sp_ve=$(ver_cmp "$1" "$2") || return $?
  [ "$_sp_ve" = "0" ]
}

# ---- 单实例锁 ----

# _sk_posix_lock_path NAME —— 锁的路径
_sk_posix_lock_path() {
  printf '%s/shellkit-%s.lock\n' "${SHELLKIT_LOCK_DIR:-${TMPDIR:-/tmp}}" "${1:-}"
}

# lock_acquire NAME [TIMEOUT] —— 拿锁（拿到即进清理栈）
lock_acquire() {
  if [ "$#" -lt 1 ] || [ -z "$1" ]; then
    log_error "invalid lock name"
    return 2
  fi
  case "$1" in
    . | .. | *[!A-Za-z0-9_.-]*)
      log_error "invalid lock name: $1"
      return 2
      ;;
  esac
  _sp_lk_path=$(_sk_posix_lock_path "$1")
  _sp_lk_wait=0
  if [ "$#" -ge 2 ]; then
    _sp_lk_wait=$2
  fi
  _sp_lk_tries=0
  while :; do
    if mkdir "$_sp_lk_path" 2>/dev/null; then
      printf '%s\n' "$$" >"$_sp_lk_path/pid" 2>/dev/null || true
      trap_push "lock_release $1"
      trap_install
      return 0
    fi
    _sp_lk_pid=$(cat "$_sp_lk_path/pid" 2>/dev/null || true)
    if [ -n "$_sp_lk_pid" ] && kill -0 "$_sp_lk_pid" 2>/dev/null; then
      log_error "another instance is running: $1 ($_sp_lk_pid)"
      return 1
    fi
    # 僵尸锁：持有者已经没了 ⇒ 回收
    rm -rf "$_sp_lk_path" 2>/dev/null || true
    _sp_lk_tries=$((_sp_lk_tries + 1))
    if [ "$_sp_lk_wait" -gt 0 ] && [ "$_sp_lk_tries" -ge "$_sp_lk_wait" ]; then
      log_error "another instance is running: $1"
      return 1
    fi
    sleep 1
  done
}

# lock_release NAME —— 放锁
lock_release() {
  if [ "$#" -lt 1 ] || [ -z "$1" ]; then
    return 2
  fi
  _sp_lr_path=$(_sk_posix_lock_path "$1")
  rm -rf "$_sp_lr_path" 2>/dev/null || true
  return 0
}

# ---- 机器可读状态 ----

# status_is_machine —— 现在是机器模式吗
status_is_machine() {
  [ "${SHELLKIT_STATUS_MODE:-human}" = "machine" ]
}

# status_state_valid STATE —— 状态码合法吗
status_state_valid() {
  case "${1:-}" in
    not_installed | installed | installed:running | installed:stopped | configured | not_configured | n/a)
      return 0
      ;;
  esac
  return 1
}

# status_emit STATE HUMAN_MSG —— 输出状态
status_emit() {
  if [ "$#" -lt 1 ]; then
    return 2
  fi
  if status_is_machine; then
    printf 'STATE=%s\n' "$1"
  else
    printf '%s\n' "${2:-$1}"
  fi
  return 0
}

# status_version VERSION —— 机器模式下输出 VERSION 行
status_version() {
  if status_is_machine; then
    printf 'VERSION=%s\n' "${1:-}"
  fi
  return 0
}

# status_extra KEY=VALUE —— 机器模式下输出 EXTRA 行
status_extra() {
  if status_is_machine; then
    printf 'EXTRA=%s\n' "${1:-}"
  fi
  return 0
}

# ---- 进程与看门狗（设备侧那一层）----
#
# 这一层与主库的 proc_* **同名同语义**（返回码一致）：
# 主库那一份靠 bash 的作业控制（set -m）让后台任务自带进程组，
# 设备侧的 busybox ash 上没有作业控制 ⇒ 进程组得靠 setsid 拿。
#
# 三条**实测**出来的约束（busybox 1.36 容器里逐条验过，不是推测）：
#
#   1. 整组杀不能带 --：
#      busybox 与 dash 都把 -- 当成 pid（busybox 报 "invalid number '--'"，
#      dash 报 "Illegal number: -"）⇒ 必须用 kill -TERM -PGID（负号紧跟数字）。
#      而 bash 只认带 -- 的写法（把 -PGID 当成信号名）⇒ 两种都试。
#   2. busybox 的 ps 不认 -p（"ps: invalid option -- 'p'"），也不认 stat=
#      的表头抑制 ⇒ 状态与进程组都从 /proc/<pid>/stat 取，ps 只当兜底。
#   3. busybox 的 setsid 在非交互 shell 里**不 fork**（父进程拿到的 $! 就是
#      最终那条命令的 pid）；但「已经是组长」时它会 fork ⇒
#      pid 让**子进程自己写**（exec 不改 pid ⇒ 写的必然是真正那条命令）。
#
# 与主库同名 ⇒ 两份**不要同时加载**：bash 后定义覆盖先定义，
# 同时加载时后加载的那份会顶掉先加载的那份（语义一致，差别只在能不能拿到
# 进程组）。按需只加载一份。

# _sk_posix_proc_dir —— 运行时目录（pid 文件与日志都在这儿）
_sk_posix_proc_dir() {
  _sp_pd_dir="${SHELLKIT_PROC_DIR:-}"
  if [ -z "$_sp_pd_dir" ]; then
    _sp_pd_dir="${TMPDIR:-/tmp}/shellkit-proc-$(id -u 2>/dev/null || printf '0')"
  fi
  if [ -L "$_sp_pd_dir" ]; then
    log_error "refusing to use a symlinked runtime directory: $_sp_pd_dir"
    return 3
  fi
  if [ ! -d "$_sp_pd_dir" ]; then
    mkdir -p "$_sp_pd_dir" 2>/dev/null || {
      log_error "cannot create the runtime directory: $_sp_pd_dir"
      return 3
    }
    chmod 700 "$_sp_pd_dir" 2>/dev/null || true
  fi
  printf '%s' "$_sp_pd_dir"
}

# _sk_posix_proc_valid_name NAME —— 名字能不能当文件名的组成部分
#   名字会变成路径（<name>.pid）⇒ 带 / 或 .. 的名字能写到目录之外。
_sk_posix_proc_valid_name() {
  case "${1:-}" in
    '' | . | ..) return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# _sk_posix_sleep_frac SECONDS —— 小数秒的 sleep
#   精简系统的 sleep 可能只认整数秒 ⇒ 先探一次，不行就退化成 1 秒。
_SK_POSIX_FRACT_SLEEP=unknown
_sk_posix_sleep_frac() {
  if [ "$_SK_POSIX_FRACT_SLEEP" = "unknown" ]; then
    if sleep 0.05 2>/dev/null; then
      _SK_POSIX_FRACT_SLEEP=yes
    else
      _SK_POSIX_FRACT_SLEEP=no
    fi
  fi
  if [ "$_SK_POSIX_FRACT_SLEEP" = "yes" ]; then
    sleep "${1:-1}"
  else
    sleep 1
  fi
}

# _sk_posix_proc_stat_fields PID —— /proc/<pid>/stat 里我们要的那几段
#
# 格式：pid (comm) state ppid pgrp session …
# comm 里可能有空格与括号 ⇒ 只能从**最后一个右括号**之后开始切。
# shellcheck disable=SC2086
_sk_posix_proc_stat_fields() {
  _sp_sf_pid="${1:-}"
  [ -n "$_sp_sf_pid" ] || return 1
  [ -r "/proc/$_sp_sf_pid/stat" ] || return 1
  _sp_sf_rest=$(sed 's/^.*) //' "/proc/$_sp_sf_pid/stat" 2>/dev/null || true)
  # shellcheck disable=SC2086
  set -- $_sp_sf_rest
  # $1=state $2=ppid $3=pgrp $4=session
  [ "$#" -ge 3 ] || return 1
  printf '%s %s %s' "${1:-}" "${2:-}" "${3:-}"
  return 0
}

# _sk_posix_proc_state PID —— 这个进程的状态字符（S / R / Z …）
#
# 查不到就返回 1（调用方按「查不到状态」处理：判据变粗，但绝不误杀）。
_sk_posix_proc_state() {
  _sp_st_pid="${1:-}"
  [ -n "$_sp_st_pid" ] || return 1
  _sp_st_fields=$(_sk_posix_proc_stat_fields "$_sp_st_pid") || _sp_st_fields=""
  if [ -n "$_sp_st_fields" ]; then
    # shellcheck disable=SC2086
    set -- $_sp_st_fields
    printf '%s' "${1:-}"
    return 0
  fi
  # 兜底：ps 的最后一行（busybox 会先打一行表头，表头不是状态）
  _sp_st_stat=$(ps -o stat= -p "$_sp_st_pid" 2>/dev/null | tail -n 1 | tr -d '[:space:]' || true)
  [ -n "$_sp_st_stat" ] || return 1
  printf '%s' "$_sp_st_stat"
  return 0
}

# _sk_posix_proc_state_is_dead STATE —— 这个状态算不算「已经没了」
#
# 僵尸（Z）与正在消亡（X）都算没了：它们还在进程表里，但 kill -0 对它们
# **仍然成功** ⇒ 只用 kill -0 判活会把僵尸当成活进程 ⇒ pid 文件永远清不掉、
# 看门狗永远以为进程还在（手写看门狗最常见的坑）。
_sk_posix_proc_state_is_dead() {
  case "${1:-}" in
    Z* | X*) return 0 ;;
  esac
  return 1
}

# _sk_posix_proc_alive PID —— 这个 pid 上还有活进程吗
#   查不到状态时退化成 kill -0（判据变粗：僵尸会被当成活着，pid 文件不会自动清）。
_sk_posix_proc_alive() {
  _sp_pa_pid="${1:-}"
  [ -n "$_sp_pa_pid" ] || return 1
  kill -0 "$_sp_pa_pid" 2>/dev/null || return 1
  _sp_pa_state=$(_sk_posix_proc_state "$_sp_pa_pid") || _sp_pa_state=""
  if [ -n "$_sp_pa_state" ] && _sk_posix_proc_state_is_dead "$_sp_pa_state"; then
    return 1
  fi
  return 0
}

# _sk_posix_proc_pgid PID —— 这个进程的进程组 id
_sk_posix_proc_pgid() {
  _sp_pg_pid="${1:-}"
  [ -n "$_sp_pg_pid" ] || return 1
  _sp_pg_fields=$(_sk_posix_proc_stat_fields "$_sp_pg_pid") || _sp_pg_fields=""
  if [ -n "$_sp_pg_fields" ]; then
    # shellcheck disable=SC2086
    set -- $_sp_pg_fields
    printf '%s' "${3:-}"
    return 0
  fi
  _sp_pg_out=$(ps -o pgid= -p "$_sp_pg_pid" 2>/dev/null | tr -d '[:space:]' || true)
  [ -n "$_sp_pg_out" ] || return 1
  printf '%s' "$_sp_pg_out"
  return 0
}

# _sk_posix_proc_self_pgid —— 调用方自己所在的进程组
_sk_posix_proc_self_pgid() {
  _sk_posix_proc_pgid "$$"
}

# _sk_posix_proc_group_of PID —— 这个进程能不能「整组停」
#
# 判据只有这一处（别在别处再写一遍）：
#   目标自己就是组长（pgid == pid）**且**那个组不是调用方自己的组。
# 少一条的后果：
#   - 不查 pgid == pid ⇒ 可能打到别人的组；
#   - 不查 pgid != 自己的组 ⇒ **自杀**：脚本被自己组的信号打死，
#     退出码 143，看着像「被信号停掉」，其实是我们自己动的手。
_sk_posix_proc_group_of() {
  _sp_go_pid="${1:-}"
  [ -n "$_sp_go_pid" ] || return 1
  _sp_go_pgid=$(_sk_posix_proc_pgid "$_sp_go_pid") || return 1
  [ "$_sp_go_pgid" = "$_sp_go_pid" ] || return 1
  _sp_go_self=$(_sk_posix_proc_self_pgid) || return 1
  [ -n "$_sp_go_self" ] || return 1
  [ "$_sp_go_pgid" != "$_sp_go_self" ] || return 1
  printf '%s' "$_sp_go_pgid"
  return 0
}

# _sk_posix_proc_group_pids PGID —— 这个组里还有哪些 pid
#
# 扫 /proc 而不是问 ps：busybox 的 ps 不认 -p，输出格式也不可控。
_sk_posix_proc_group_pids() {
  _sp_gp_pgid="${1:-}"
  [ -n "$_sp_gp_pgid" ] || return 0
  awk -v g="$_sp_gp_pgid" '
    {
      line = $0
      last = 0
      while (match(line, /\)[ \t]/)) {
        last = RSTART
        line = substr(line, RSTART + 1)
      }
      if (last == 0) next
      rest = substr($0, last + 2)
      n = split(rest, f, /[ \t]+/)
      if (n < 3) next
      if (f[3] != g) next
      pid = $1
      sub(/^[ \t]+/, "", pid)
      print pid
    }
  ' /proc/[0-9]*/stat 2>/dev/null || true
  return 0
}

# _sk_posix_proc_group_busy PGID —— 这个组里还有活着的进程吗（僵尸不算）
_sk_posix_proc_group_busy() {
  _sp_gb_pgid="${1:-}"
  [ -n "$_sp_gb_pgid" ] || return 1
  _sp_gb_pids=$(_sk_posix_proc_group_pids "$_sp_gb_pgid")
  for _sp_gb_pid in $_sp_gb_pids; do
    if _sk_posix_proc_alive "$_sp_gb_pid"; then
      return 0
    fi
  done
  return 1
}

# _sk_posix_kill_group SIGNAL PGID —— 整组停
#
# ⚠ 信号名**必须带前导 -**（kill -TERM，不是 kill TERM）：
#   busybox 的 kill 认不带横杠的信号名（把 "TERM" 当信号），
#   而 dash 与 bash 会把它当成**一个 pid** ⇒ "TERM: Illegal number"
#   ⇒ 整组杀根本没发生 ⇒ 进程停不掉（退出码 3）。
#   同一份代码在三种 shell 上三种结果，而且**只在有 setsid 的机器上**
#   才走到这条路（macOS 没有 setsid ⇒ 走「只停主进程」的降级 ⇒ 看不出来）。
#
# 两种 pid 写法都试（实测）：
#   kill -TERM -- -1234  —— bash 认；busybox 报 "invalid number '--'"，
#                           dash 报 "Illegal number: -"
#   kill -TERM -1234     —— busybox / dash / bash 都认（负 pid = 进程组）
_sk_posix_kill_group() {
  _sp_kg_sig="${1:-TERM}"
  _sp_kg_pgid="${2:-}"
  [ -n "$_sp_kg_pgid" ] || return 1
  kill "-$_sp_kg_sig" -- "-$_sp_kg_pgid" 2>/dev/null && return 0
  kill "-$_sp_kg_sig" "-$_sp_kg_pgid" 2>/dev/null && return 0
  return 1
}

# _sk_posix_proc_spawn PIDFILE LOGFILE COMMAND... —— 引导一个后台进程
#
# pid 由**子进程自己写**（而不是父进程拿 $!）：setsid 在「已经是组长」时会
# fork ⇒ 那时 $! 是 setsid 的 pid，不是真正那条命令的 pid ⇒ 父进程记下来的
# pid 指向一个马上就退出的进程 ⇒ 探活永远失败、pid 文件永远清不掉。
# 子进程写的是 exec 之后那条命令的 pid（exec 不改 pid）⇒ 一定是它。
#
# 脱离终端三级退化（按可用性）：
#   setsid —— 有就优先：顺便给一个新会话与新进程组 ⇒ 整组停止才做得到；
#   nohup  —— 只解决 SIGHUP，没有新进程组 ⇒ 整组停止退化成只停主进程；
#   子 shell 里 trap '' HUP 再 exec —— 都没有时的兜底
#            （被忽略的信号跨 exec 继承 ⇒ 子进程不会因终端关闭而收到 SIGHUP）。
_sk_posix_proc_spawn() {
  _sp_sp_pidfile="${1:-}"
  _sp_sp_logfile="${2:-}"
  shift 2
  # shellcheck disable=SC2016
  _sp_sp_boot='printf "%s\n" "$$" > "$1.tmp" && mv -f "$1.tmp" "$1"; shift; exec "$@"'
  if command -v setsid >/dev/null 2>&1; then
    setsid sh -c "$_sp_sp_boot" sk "$_sp_sp_pidfile" "$@" >>"$_sp_sp_logfile" 2>&1 </dev/null &
  elif command -v nohup >/dev/null 2>&1; then
    nohup sh -c "$_sp_sp_boot" sk "$_sp_sp_pidfile" "$@" >>"$_sp_sp_logfile" 2>&1 </dev/null &
  else
    (trap '' HUP; exec sh -c "$_sp_sp_boot" sk "$_sp_sp_pidfile" "$@") >>"$_sp_sp_logfile" 2>&1 </dev/null &
  fi
  return 0
}

# proc_start NAME COMMAND... —— 后台拉起一个进程
#
# 脱离终端、记 pid 文件（子进程自己写）、日志**追加**（不截断 ——
# 截断会把上次的现场抹掉，出事时没得查）。
#
# 退出码：0 成功 / 1 拉起失败 / 2 用法错 / 3 前置条件不满足
proc_start() {
  if [ "$#" -lt 2 ]; then
    log_error "usage: proc_start NAME COMMAND..."
    return 2
  fi
  _sp_s_name="$1"
  shift
  if ! _sk_posix_proc_valid_name "$_sp_s_name"; then
    log_error "invalid process name: $_sp_s_name"
    return 2
  fi
  if ! command -v "${1:-}" >/dev/null 2>&1; then
    log_error "the command does not exist: ${1:-}"
    return 3
  fi
  _sp_s_dir=$(_sk_posix_proc_dir) || return 3
  _sp_s_pidfile="$_sp_s_dir/$_sp_s_name.pid"
  _sp_s_logfile="$_sp_s_dir/$_sp_s_name.log"
  if [ -L "$_sp_s_pidfile" ]; then
    log_error "refusing to write through a symlink: $_sp_s_pidfile"
    return 3
  fi
  # 已经在跑 ⇒ 不再拉第二份（两份进程抢同一个端口）
  if [ -f "$_sp_s_pidfile" ]; then
    _sp_s_old=$(cat "$_sp_s_pidfile" 2>/dev/null || true)
    if _sk_posix_proc_alive "$_sp_s_old"; then
      log_error "the process is already running: $_sp_s_name ($_sp_s_old)"
      return 3
    fi
    # 僵尸 pid 文件：清掉，否则下次 start 会误判「已经在跑」
    rm -f "$_sp_s_pidfile" 2>/dev/null || true
  fi
  _sk_posix_proc_spawn "$_sp_s_pidfile" "$_sp_s_logfile" "$@" || return 1
  # 等 pid 文件落地（子进程写的）：最多 5 秒
  _sp_s_wait=0
  while [ "$_sp_s_wait" -lt 50 ]; do
    if [ -s "$_sp_s_pidfile" ]; then
      break
    fi
    _sk_posix_sleep_frac 0.1
    _sp_s_wait=$((_sp_s_wait + 1))
  done
  _sp_s_pid=$(cat "$_sp_s_pidfile" 2>/dev/null || true)
  case "$_sp_s_pid" in
    '' | *[!0-9]*)
      rm -f "$_sp_s_pidfile" 2>/dev/null || true
      log_error "the process did not report its pid: $_sp_s_name"
      return 1
      ;;
  esac
  # 拉起来就退出（命令本身有问题：不存在、参数错、立刻崩）⇒ 明确报错
  _sk_posix_sleep_frac 0.3
  if ! _sk_posix_proc_alive "$_sp_s_pid"; then
    # 整组清掉：命令自己起来就崩，但它可能已经派生了子进程 ——
    # 只杀主进程会留下孤儿（端口还占着，正是这一层要根治的坑）
    _sp_s_pgid=$(_sk_posix_proc_group_of "$_sp_s_pid") || _sp_s_pgid=""
    if [ -n "$_sp_s_pgid" ]; then
      _sk_posix_kill_group TERM "$_sp_s_pgid" || kill -TERM "$_sp_s_pid" 2>/dev/null || true
    else
      kill -TERM "$_sp_s_pid" 2>/dev/null || true
    fi
    rm -f "$_sp_s_pidfile" 2>/dev/null || true
    log_error "the process exited immediately: $_sp_s_name (see $_sp_s_logfile)"
    return 1
  fi
  return 0
}

# proc_stop NAME —— 停掉那个进程（能整组停就整组停）
#
# 只 kill 主进程 ⇒ 子进程残留、端口还占着 —— 这是手写最常见的坑。
# 这里先给整组 TERM，留收尾的时间；还在就 KILL 整组。
#
# 拿不到进程组时**明确退化成只杀主进程**（宁可留子进程，也不能自杀 ——
# kill 打到自己的组上会静默自杀，退出码 143）。
#
# 退出码：0 已停 / 2 用法错 / 3 停不掉
proc_stop() {
  if [ "$#" -lt 1 ]; then
    log_error "usage: proc_stop NAME"
    return 2
  fi
  _sp_st_name="$1"
  if ! _sk_posix_proc_valid_name "$_sp_st_name"; then
    log_error "invalid process name: $_sp_st_name"
    return 2
  fi
  _sp_st_dir=$(_sk_posix_proc_dir) || return 3
  _sp_st_pidfile="$_sp_st_dir/$_sp_st_name.pid"
  # 没有 pid 文件 ⇒ 没在跑（停一个没跑的东西是成功，不是错误）
  [ -f "$_sp_st_pidfile" ] || return 0
  _sp_st_pid=$(cat "$_sp_st_pidfile" 2>/dev/null || true)
  if ! _sk_posix_proc_alive "$_sp_st_pid"; then
    rm -f "$_sp_st_pidfile" 2>/dev/null || true
    return 0
  fi
  _sp_st_pgid=$(_sk_posix_proc_group_of "$_sp_st_pid") || _sp_st_pgid=""
  if [ -n "$_sp_st_pgid" ]; then
    _sk_posix_kill_group TERM "$_sp_st_pgid" || kill -TERM "$_sp_st_pid" 2>/dev/null || true
  else
    kill -TERM "$_sp_st_pid" 2>/dev/null || true
  fi
  # 等它收尾（最多 10 秒）：主进程没了还不够 —— 组里可能还有子进程在跑
  _sp_st_i=0
  while [ "$_sp_st_i" -lt 100 ]; do
    _sp_st_alive=0
    _sk_posix_proc_alive "$_sp_st_pid" && _sp_st_alive=1
    if [ "$_sp_st_alive" = "0" ] && [ -n "$_sp_st_pgid" ] && _sk_posix_proc_group_busy "$_sp_st_pgid"; then
      _sp_st_alive=1
    fi
    [ "$_sp_st_alive" = "0" ] && break
    _sk_posix_sleep_frac 0.1
    _sp_st_i=$((_sp_st_i + 1))
  done
  _sp_st_alive=0
  _sk_posix_proc_alive "$_sp_st_pid" && _sp_st_alive=1
  if [ "$_sp_st_alive" = "0" ] && [ -n "$_sp_st_pgid" ] && _sk_posix_proc_group_busy "$_sp_st_pgid"; then
    _sp_st_alive=1
  fi
  if [ "$_sp_st_alive" = "1" ]; then
    if [ -n "$_sp_st_pgid" ]; then
      _sk_posix_kill_group KILL "$_sp_st_pgid" || kill -KILL "$_sp_st_pid" 2>/dev/null || true
    else
      kill -KILL "$_sp_st_pid" 2>/dev/null || true
    fi
    # KILL 之后再看一眼：还在就如实报停不掉（退出码 3），别假装成功
    _sp_st_i=0
    while [ "$_sp_st_i" -lt 20 ]; do
      _sp_st_alive=0
      _sk_posix_proc_alive "$_sp_st_pid" && _sp_st_alive=1
      if [ "$_sp_st_alive" = "0" ] && [ -n "$_sp_st_pgid" ] && _sk_posix_proc_group_busy "$_sp_st_pgid"; then
        _sp_st_alive=1
      fi
      [ "$_sp_st_alive" = "0" ] && break
      _sk_posix_sleep_frac 0.1
      _sp_st_i=$((_sp_st_i + 1))
    done
    if [ "$_sp_st_alive" = "1" ]; then
      log_error "cannot stop the process: $_sp_st_name ($_sp_st_pid)"
      return 3
    fi
  fi
  rm -f "$_sp_st_pidfile" 2>/dev/null || true
  return 0
}

# proc_is_running NAME —— 探活
#
# 僵尸 pid 文件会被清掉：文件还在、进程早没了 —— 手写看门狗最常见的另一种坑
#（探活永远失败，但没人清理，重启就一直起不来）。
#
# 退出码：0 在跑 / 1 没在跑（僵尸 pid 文件会被清掉）/ 2 用法错 / 3 目录不可用
proc_is_running() {
  if [ "$#" -lt 1 ]; then
    log_error "usage: proc_is_running NAME"
    return 2
  fi
  _sp_ir_name="$1"
  if ! _sk_posix_proc_valid_name "$_sp_ir_name"; then
    log_error "invalid process name: $_sp_ir_name"
    return 2
  fi
  _sp_ir_dir=$(_sk_posix_proc_dir) || return 3
  _sp_ir_pidfile="$_sp_ir_dir/$_sp_ir_name.pid"
  [ -f "$_sp_ir_pidfile" ] || return 1
  _sp_ir_pid=$(cat "$_sp_ir_pidfile" 2>/dev/null || true)
  if _sk_posix_proc_alive "$_sp_ir_pid"; then
    return 0
  fi
  rm -f "$_sp_ir_pidfile" 2>/dev/null || true
  return 1
}

# proc_watchdog [--interval SEC] [--max-backoff SEC] [--max-restarts N] NAME COMMAND...
#
# 看门狗：进程挂了拉起来，带退避。
# 退避：连续失败时按 1→2→4… 翻倍（上限 --max-backoff）——
# 没有退避的重启是**风暴**：进程起来就崩 ⇒ 无限循环重启，把机器打满。
# 进程连续活过几个周期 ⇒ 退避归零。
# --max-restarts N：连续 N 次拉起失败就放弃并返回非 0（0 = 不限）。
#
# 退出码：0 被信号停掉 / 1 放弃 / 2 用法错
proc_watchdog() {
  _sp_w_interval=5
  _sp_w_backoff_max=60
  _sp_w_restarts=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --interval)
        shift
        _sp_w_interval="${1:-}"
        ;;
      --max-backoff)
        shift
        _sp_w_backoff_max="${1:-}"
        ;;
      --max-restarts)
        shift
        _sp_w_restarts="${1:-}"
        ;;
      -h | --help)
        printf '%s\n' "Usage: proc_watchdog [--interval SEC] [--max-backoff SEC] [--max-restarts N] NAME COMMAND..."
        return 0
        ;;
      --)
        shift
        break
        ;;
      *)
        break
        ;;
    esac
    shift
  done
  if [ "$#" -lt 2 ]; then
    log_error "usage: proc_watchdog [options] NAME COMMAND..."
    return 2
  fi
  _sp_w_name="$1"
  shift
  if ! _sk_posix_proc_valid_name "$_sp_w_name"; then
    log_error "invalid process name: $_sp_w_name"
    return 2
  fi
  case "$_sp_w_interval" in
    '' | *[!0-9]*)
      log_error "invalid interval: $_sp_w_interval"
      return 2
      ;;
  esac
  case "$_sp_w_backoff_max" in
    '' | *[!0-9]*)
      log_error "invalid backoff: $_sp_w_backoff_max"
      return 2
      ;;
  esac
  case "$_sp_w_restarts" in
    '' | *[!0-9]*)
      log_error "invalid restart limit: $_sp_w_restarts"
      return 2
      ;;
  esac
  # 0 秒间隔是热循环（100% CPU），0 秒退避是重启风暴 —— 两个都不接受
  if [ "$_sp_w_interval" -lt 1 ]; then
    log_error "invalid interval: $_sp_w_interval"
    return 2
  fi
  if [ "$_sp_w_backoff_max" -lt 1 ]; then
    log_error "invalid backoff: $_sp_w_backoff_max"
    return 2
  fi
  _sp_w_backoff=1
  _sp_w_consec=0
  _sp_w_up=0
  _sp_w_rc=0
  # 被停时把子进程也带走 —— 留下一个孤儿占着端口，比不停更糟
  trap_push "proc_stop '$_sp_w_name'" || true
  trap_install || true
  while :; do
    if ! proc_is_running "$_sp_w_name"; then
      if [ "$_sp_w_consec" -gt 0 ]; then
        # 退避要看得见：没有退避的重启是风暴，运维要能看出「在等」
        log_info "waiting before the next restart: $_sp_w_backoff s"
        sleep "$_sp_w_backoff"
      fi
      if proc_start "$_sp_w_name" "$@"; then
        _sp_w_up=0
      else
        # 失败计数只加一次（下面那个「没在跑」的分支统一加）——
        # 两处都加会把一次失败算成两次，--max-restarts 的上限就少了一半
        log_error "the watchdog could not start the process: $_sp_w_name"
      fi
    fi
    sleep "$_sp_w_interval"
    if proc_is_running "$_sp_w_name"; then
      _sp_w_up=$((_sp_w_up + 1))
      if [ "$_sp_w_up" -ge 3 ]; then
        # 连续活过三个周期 ⇒ 之前那次挂掉是偶发，退避归零
        _sp_w_backoff=1
        _sp_w_consec=0
      fi
    else
      _sp_w_backoff=$((_sp_w_backoff * 2))
      if [ "$_sp_w_backoff" -gt "$_sp_w_backoff_max" ]; then
        _sp_w_backoff=$_sp_w_backoff_max
      fi
      _sp_w_consec=$((_sp_w_consec + 1))
    fi
    if [ "$_sp_w_restarts" -gt 0 ] && [ "$_sp_w_consec" -ge "$_sp_w_restarts" ]; then
      log_error "the watchdog gave up after too many failed restarts: $_sp_w_name"
      _sp_w_rc=1
      break
    fi
  done
  proc_stop "$_sp_w_name" || true
  return "$_sp_w_rc"
}

# ---- 能力查询 ----

# posix_capable NAME —— 这个函数在 POSIX 子集里能用吗
#
# 设备侧脚本据此判断「这条能不能用」，而不是靠试 —— 试出来的失败往往是
# 「装上就挂」，而现场装不了 shellkit 补救。
posix_capable() {
  if [ "$#" -lt 1 ] || [ -z "$1" ]; then
    return 2
  fi
  if command -v "$1" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}
