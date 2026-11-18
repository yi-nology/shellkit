#!/usr/bin/env bash
#
# 进程组 / 看门狗原语：后台引导、整组停止、带退避的自愈。
#
# 为什么单独一层：svc_* 是 systemd/launchd 的**服务单元**管理（写 unit 文件、
# 交给服务管理器拉起）；这一层是**裸进程** —— 设备侧启动脚本手写
# 「nohup ... & + pid 文件 + 探活循环」的那一层。两层语义不同，名字不能混：
# svc_start 已经被 systemd 语义占用了（改了它等于改掉既有调用方的行为）。
#
# 这一层要解决的三件事，每一件手写都踩过坑：
#   1. 后台引导：脱离终端（关掉终端不能把它带死）、记 pid 文件；
#   2. 整组停止：只 kill 主进程 ⇒ 子进程残留、端口还占着；
#   3. 看门狗自愈：探活失败与探活超时不分、重启风暴没有退避、僵尸 pid 文件没清。
#
# 进程组怎么来的：bash 的作业控制（set -m）让后台任务**自带进程组**，
# 组 id 就是它的 pid ⇒ 整组停止就是 kill -- -PGID。
# 不用 setsid：macOS 没有这个命令（util-linux 才有），而作业控制两个平台都有。
#
# 落点：pid 文件与日志放在 $SHELLKIT_PROC_DIR
# （默认 ${TMPDIR:-/tmp}/shellkit-proc-<uid>，权限 700）。/tmp 是共享目录 ⇒
# 名字必须先过校验，目录也不能是软链（软链会把 pid 文件写到别处去）。

# _sk_proc_dir —— 运行时目录（pid 文件与日志都在这儿）
# @exitcode 0 成功（stdout 是目录）
# @exitcode 3 建不出来 / 是软链
_sk_proc_dir() {
  local __d="${SHELLKIT_PROC_DIR:-}"
  if [ -z "$__d" ]; then
    __d="${TMPDIR:-/tmp}/shellkit-proc-$(id -u 2>/dev/null || printf '0')"
  fi
  if [ -L "$__d" ]; then
    log_error "$(_t 'refusing to use a symlinked runtime directory'): $__d"
    return "$SK_PRECOND"
  fi
  if [ ! -d "$__d" ]; then
    mkdir -p "$__d" 2>/dev/null || {
      log_error "$(_t 'cannot create the runtime directory'): $__d"
      return "$SK_PRECOND"
    }
    chmod 700 "$__d" 2>/dev/null || true
  fi
  printf '%s' "$__d"
}

# _sk_proc_valid_name NAME —— 名字能不能当文件名的组成部分
#   名字会变成路径（<name>.pid）⇒ 带 / 或 .. 的名字能写到目录之外。
# @exitcode 0 合法；1 非法
_sk_proc_valid_name() {
  case "${1:-}" in
    '' | . | ..) return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# _sk_proc_alive PID —— 这个 pid 上还有活进程吗
#   僵尸不算活着：kill -0 对僵尸也成功（它还在进程表里），
#   而「僵尸 pid 文件没清」正是手写看门狗最常见的坑。
# @exitcode 0 活着；1 没了 / 是僵尸
_sk_proc_alive() {
  local __pid="${1:-}" __st
  [ -n "$__pid" ] || return 1
  kill -0 "$__pid" 2>/dev/null || return 1
  __st=$(ps -o stat= -p "$__pid" 2>/dev/null | tr -d '[:space:]')
  case "$__st" in
    '' | Z*) return 1 ;;
  esac
  return 0
}

# _sk_proc_pid_file DIR NAME —— pid 文件路径
# @exitcode 0 总是成功（stdout 是路径）
_sk_proc_pid_file() {
  printf '%s/%s.pid' "${1:-}" "${2:-}"
}

# proc_start NAME COMMAND... —— 后台拉起一个进程组
#
# 脱离终端：nohup 忽略 SIGHUP + 标准输入接 /dev/null + 作业控制让它自带进程组。
# pid 文件：$DIR/NAME.pid（原子写）。日志：$DIR/NAME.log（**追加**，不截断 ——
# 截断会把上次的现场抹掉，出事时没得查）。
#
# @exitcode 0 成功（进程已拉起）
# @exitcode 2 用法错（名字非法 / 没有命令）
# @exitcode 3 前置条件不满足（已经在跑 / 运行目录不可用 / 命令不存在）
# @exitcode 1 拉起失败（命令自己起不来）
# @stability experimental
proc_start() {
  local __name="${1:-}" __dir __pidfile __logfile __pid __pgid __had_m=0
  _sk_need_args "$#" 2 "proc_start NAME COMMAND..." || return $?
  __name=$1
  shift
  if ! _sk_proc_valid_name "$__name"; then
    log_error "$(_t 'invalid process name'): $__name"
    return "$SK_USAGE"
  fi
  if ! require_cmd "${1:-}"; then
    return "$SK_PRECOND"
  fi
  __dir=$(_sk_proc_dir) || return $?
  __pidfile=$(_sk_proc_pid_file "$__dir" "$__name")
  __logfile="$__dir/$__name.log"
  # 路径边界守卫：pid 文件是 <name>.pid，名字已校验过（不含 / 与 ..）
  if ! _sk_fs_rel_safe "$__name.pid"; then
    log_error "$(_t 'invalid process name'): $__name"
    return "$SK_USAGE"
  fi
  if [ -L "$__pidfile" ]; then
    log_error "$(_t 'refusing to write through a symlink'): $__pidfile"
    return "$SK_PRECOND"
  fi
  # 已经在跑 ⇒ 不再拉第二份（两份进程抢同一个端口）
  if [ -f "$__pidfile" ]; then
    __pid=$(cat "$__pidfile" 2>/dev/null || true)
    if _sk_proc_alive "$__pid"; then
      log_error "$(_t 'the process is already running'): $__name ($__pid)"
      return "$SK_PRECOND"
    fi
    # 僵尸 pid 文件：清掉，否则下次 start 会误判「已经在跑」
    rm -f "$__pidfile" 2>/dev/null || true
  fi
  # 作业控制：后台任务自带进程组（组 id = 它的 pid）⇒ 整组停止才做得到
  case "$-" in
    *m*) __had_m=1 ;;
  esac
  set -m
  nohup "$@" >>"$__logfile" 2>&1 </dev/null &
  __pid=$!
  if [ "$__had_m" = "0" ]; then
    set +m
  fi
  # 组 id 必须是它自己 —— 不是的话整组停止会退化成只停主进程（子进程残留）
  __pgid=$(ps -o pgid= -p "$__pid" 2>/dev/null | tr -d '[:space:]')
  if [ -z "$__pgid" ] || [ "$__pgid" != "$__pid" ]; then
    log_warn "$(_t 'the process group is unavailable; only the main process can be stopped'): $__name"
  fi
  if ! fs_atomic_write "$__pidfile" "$__pid
" 600; then
    kill "$__pid" 2>/dev/null || true
    return 1
  fi
  # 拉起来就退出（命令本身有问题：不存在、参数错、立刻崩）⇒ 明确报错
  sleep 0.3
  if ! _sk_proc_alive "$__pid"; then
    rm -f "$__pidfile" 2>/dev/null || true
    log_error "$(_t 'the process exited immediately'): $__name (see $__logfile)"
    return 1
  fi
  return 0
}

# proc_stop NAME —— 停掉整个进程组
#
# 只 kill 主进程 ⇒ 子进程残留、端口还占着 —— 这是手写最常见的坑。
# 这里先给整组 TERM，留收尾的时间；还在就 KILL 整组。
#
# @exitcode 0 已停（或本来就没在跑）
# @exitcode 2 用法错
# @exitcode 3 停不掉
# @stability experimental
proc_stop() {
  local __name="${1:-}" __dir __pidfile __pid __pgid __i=0
  _sk_need_args "$#" 1 "proc_stop NAME" || return $?
  __name=$1
  if ! _sk_proc_valid_name "$__name"; then
    log_error "$(_t 'invalid process name'): $__name"
    return "$SK_USAGE"
  fi
  __dir=$(_sk_proc_dir) || return $?
  __pidfile=$(_sk_proc_pid_file "$__dir" "$__name")
  # 没有 pid 文件 ⇒ 没在跑（停一个没跑的东西是成功，不是错误）
  [ -f "$__pidfile" ] || return 0
  __pid=$(cat "$__pidfile" 2>/dev/null || true)
  if ! _sk_proc_alive "$__pid"; then
    rm -f "$__pidfile" 2>/dev/null || true
    return 0
  fi
  __pgid=$(ps -o pgid= -p "$__pid" 2>/dev/null | tr -d '[:space:]')
  # 只有当它**自己就是组长**（pgid == pid）时才整组停。
  # 否则那个组是调用方的组 —— kill -- -PGID 会把调用方自己一起杀掉（静默自杀）。
  if [ -n "$__pgid" ] && [ "$__pgid" = "$__pid" ]; then
    kill -TERM -- "-$__pgid" 2>/dev/null || kill -TERM "$__pid" 2>/dev/null || true
  else
    kill -TERM "$__pid" 2>/dev/null || true
  fi
  # 等它收尾（最多 10 秒）
  while [ "$__i" -lt 100 ]; do
    _sk_proc_alive "$__pid" || break
    sleep 0.1
    __i=$((__i + 1))
  done
  if _sk_proc_alive "$__pid"; then
    if [ -n "$__pgid" ] && [ "$__pgid" = "$__pid" ]; then
      kill -KILL -- "-$__pgid" 2>/dev/null || kill -KILL "$__pid" 2>/dev/null || true
    else
      kill -KILL "$__pid" 2>/dev/null || true
    fi
  fi
  rm -f "$__pidfile" 2>/dev/null || true
  return 0
}

# proc_is_running NAME —— 探活
#
# 僵尸 pid 文件会被清掉：文件还在、进程早没了 —— 手写看门狗最常见的另一种坑
# （探活永远失败，但没人清理，重启就一直起不来）。
#
# @exitcode 0 在跑
# @exitcode 1 没在跑（僵尸 pid 文件会被清掉）
# @exitcode 2 用法错
# @exitcode 3 运行目录不可用
# @stability experimental
proc_is_running() {
  local __name="${1:-}" __dir __pidfile __pid
  _sk_need_args "$#" 1 "proc_is_running NAME" || return $?
  __name=$1
  if ! _sk_proc_valid_name "$__name"; then
    log_error "$(_t 'invalid process name'): $__name"
    return "$SK_USAGE"
  fi
  __dir=$(_sk_proc_dir) || return $?
  __pidfile=$(_sk_proc_pid_file "$__dir" "$__name")
  [ -f "$__pidfile" ] || return 1
  __pid=$(cat "$__pidfile" 2>/dev/null || true)
  if _sk_proc_alive "$__pid"; then
    return 0
  fi
  rm -f "$__pidfile" 2>/dev/null || true
  return 1
}

# proc_watchdog [--interval SEC] [--max-backoff SEC] [--max-restarts N] NAME COMMAND...
#
# 看门狗：进程挂了拉起来，带退避。
#
# 退避：连续失败时按 1→2→4… 翻倍（上限 --max-backoff）——
# 没有退避的重启是**风暴**：进程起来就崩 ⇒ 无限循环重启，把机器打满。
# 进程连续活过几个周期 ⇒ 退避归零（不是一直用最大退避）。
#
# --max-restarts N：连续 N 次拉起失败就放弃并返回非 0（0 = 不限）。
# 无人值守设备上「放弃了」必须有人看得见，所以放弃时是**非 0 退出**。
#
# @exitcode 0 被信号停掉（正常退出）
# @exitcode 2 用法错
# @exitcode 1 放弃（连续拉起失败超过上限）
# @stability experimental
proc_watchdog() {
  local __interval=5 __maxbackoff=60 __maxrestarts=0 __name __dir __pid
  local __backoff=1 __consec=0 __up=0 __rc=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --interval)
        shift
        __interval="${1:-}"
        ;;
      --max-backoff)
        shift
        __maxbackoff="${1:-}"
        ;;
      --max-restarts)
        shift
        __maxrestarts="${1:-}"
        ;;
      -h | --help)
        printf '%s\n' "usage: proc_watchdog [--interval SEC] [--max-backoff SEC] [--max-restarts N] NAME COMMAND..."
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
  _sk_need_args "$#" 2 "proc_watchdog [options] NAME COMMAND..." || return $?
  __name=$1
  shift
  if ! _sk_proc_valid_name "$__name"; then
    log_error "$(_t 'invalid process name'): $__name"
    return "$SK_USAGE"
  fi
  case "$__interval" in
    '' | *[!0-9]*)
      log_error "$(_t 'invalid interval'): $__interval"
      return "$SK_USAGE"
      ;;
  esac
  case "$__maxbackoff" in
    '' | *[!0-9]*)
      log_error "$(_t 'invalid backoff'): $__maxbackoff"
      return "$SK_USAGE"
      ;;
  esac
  case "$__maxrestarts" in
    '' | *[!0-9]*)
      log_error "$(_t 'invalid restart limit'): $__maxrestarts"
      return "$SK_USAGE"
      ;;
  esac
  # 被停时把子进程也带走 —— 留下一个孤儿占着端口，比不停更糟
  trap_push "proc_stop '$__name'" || true
  trap_install || true
  while :; do
    if ! proc_is_running "$__name"; then
      if [ "$__consec" -gt 0 ]; then
        # 退避要看得见：没有退避的重启是风暴，运维要能看出「在等」
        log_info "$(_t 'waiting before the next restart'): $__backoff s"
        sleep "$__backoff"
      fi
      if proc_start "$__name" "$@"; then
        __up=0
      else
        __consec=$((__consec + 1))
        log_error "$(_t 'the watchdog could not start the process'): $__name"
      fi
    fi
    sleep "$__interval"
    if proc_is_running "$__name"; then
      __up=$((__up + 1))
      if [ "$__up" -ge 3 ]; then
        # 连续活过三个周期 ⇒ 之前那次挂掉是偶发，退避归零
        __backoff=1
        __consec=0
      fi
    else
      __backoff=$((__backoff * 2))
      if [ "$__backoff" -gt "$__maxbackoff" ]; then
        __backoff=$__maxbackoff
      fi
      __consec=$((__consec + 1))
    fi
    if [ "$__maxrestarts" -gt 0 ] && [ "$__consec" -ge "$__maxrestarts" ]; then
      log_error "$(_t 'the watchdog gave up after too many failed restarts'): $__name"
      __rc=1
      break
    fi
  done
  proc_stop "$__name" || true
  return "$__rc"
}
