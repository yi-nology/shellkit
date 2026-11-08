#!/usr/bin/env bash
#
# 清理栈：让「失败也要收尾」不必每次都重新想一遍。
#
#   trap_push 'rm -rf "$workdir"'
#   trap_push 'lock_release deploy'
#   trap_install
#
# 注册不等于安装 —— 只有 trap_install 才真正改变调用方的信号行为。
# 这是刻意的：库被 source 时不该悄悄接管别人的 trap。

_SK_TRAP_CMDS=()
_SK_TRAP_N=0
_SK_TRAP_RUNNING=0
_SK_TRAP_INSTALLED=0
_SK_TRAP_HAD_EXIT=0
_SK_TRAP_SAVED_EXIT=""
_SK_TRAP_SAVED_INT=""
_SK_TRAP_SAVED_TERM=""
_SK_TRAP_SAVED_HUP=""

# trap_push CMD... —— 注册一个清理动作；后注册的先执行
trap_push() {
  if [ "$#" -eq 0 ]; then
    log_error "$(_t 'trap_push requires a command')"
    return "$SK_USAGE"
  fi
  _SK_TRAP_CMDS[$_SK_TRAP_N]="$*"
  _SK_TRAP_N=$((_SK_TRAP_N + 1))
  return 0
}

# trap_pop —— 丢弃最近注册的一个动作（不执行）
trap_pop() {
  if [ "$_SK_TRAP_N" -gt 0 ]; then
    _SK_TRAP_N=$((_SK_TRAP_N - 1))
    _SK_TRAP_CMDS[$_SK_TRAP_N]=""
  fi
  return 0
}

# trap_list —— 逐行输出已注册的动作（调试用）
trap_list() {
  local __i=0
  while [ "$__i" -lt "$_SK_TRAP_N" ]; do
    printf '%d %s\n' "$__i" "${_SK_TRAP_CMDS[$__i]}"
    __i=$((__i + 1))
  done
  return 0
}

# trap_cleanup —— 逆序执行全部清理动作；幂等；单个失败不中断其余
trap_cleanup() {
  local __i __cmd
  if [ "${_SK_TRAP_RUNNING:-0}" = "1" ]; then
    return 0
  fi
  _SK_TRAP_RUNNING=1

  __i=$_SK_TRAP_N
  while [ "$__i" -gt 0 ]; do
    __i=$((__i - 1))
    __cmd=${_SK_TRAP_CMDS[$__i]}
    _SK_TRAP_CMDS[$__i]=""
    if [ -n "$__cmd" ]; then
      if ! eval "$__cmd"; then
        log_warn "$(_t 'cleanup step failed'): $__cmd"
      fi
    fi
  done
  _SK_TRAP_N=0

  # 调用方原有的 EXIT trap 放在最后跑，保证它看到的是已收尾的状态
  if [ "${_SK_TRAP_HAD_EXIT:-0}" = "1" ] && [ -n "${_SK_TRAP_SAVED_EXIT:-}" ]; then
    __cmd=$_SK_TRAP_SAVED_EXIT
    _SK_TRAP_SAVED_EXIT=""
    _SK_TRAP_HAD_EXIT=0
    if ! eval "$__cmd"; then
      log_warn "$(_t 'cleanup step failed'): $__cmd"
    fi
  fi

  _SK_TRAP_RUNNING=0
  return 0
}

# _sk_trap_has CMD —— 栈里是否已有这个动作（用于避免子 shell 里重复入栈）
_sk_trap_has() {
  local __want=$1 __i=0
  while [ "$__i" -lt "$_SK_TRAP_N" ]; do
    if [ "${_SK_TRAP_CMDS[$__i]}" = "$__want" ]; then
      return 0
    fi
    __i=$((__i + 1))
  done
  return 1
}

# _sk_trap_read SIG —— 把当前 shell 里该信号的 trap 定义读进 _SK_TRAP_CUR。
# 关键：不能用 $(trap -p ...) —— 命令替换在子 shell 里执行，而子 shell 会把已捕获的
# trap 重置为默认，于是永远读到空。这里用重定向（在当前 shell 执行）绕开。
_SK_TRAP_CUR=""
_sk_trap_read() {
  local __sig=$1 __f
  _SK_TRAP_CUR=""
  __f=$(mktemp "${TMPDIR:-/tmp}/.shellkit-trap.XXXXXX") || return 1
  if ! trap -p "$__sig" >"$__f" 2>/dev/null; then
    rm -f "$__f"
    return 1
  fi
  _SK_TRAP_CUR=$(cat "$__f" 2>/dev/null || true)
  rm -f "$__f"
  return 0
}

# _sk_trap_slot SIG —— 该信号的保存位变量名
_sk_trap_slot() {
  case "${1:-}" in
    EXIT) printf '_SK_TRAP_SAVED_EXIT' ;;
    INT) printf '_SK_TRAP_SAVED_INT' ;;
    TERM) printf '_SK_TRAP_SAVED_TERM' ;;
    HUP) printf '_SK_TRAP_SAVED_HUP' ;;
    *) return 1 ;;
  esac
}

# _sk_trap_capture SIG —— 把调用方已有的同名 trap 存下来，稍后链式执行
_sk_trap_capture() {
  local __sig=$1 __slot __line __cmd
  __slot=$(_sk_trap_slot "$__sig") || return 0
  _sk_trap_read "$__sig" || return 0
  __line=$_SK_TRAP_CUR
  case "$__line" in
    "trap -- "*) ;;
    *) return 0 ;;
  esac
  __cmd=${__line#trap -- }
  # trap -p 的尾部是信号名：EXIT 写 EXIT，其余写 SIGINT / SIGTERM / SIGHUP
  case "$__cmd" in
    *" SIG$__sig") __cmd=${__cmd%" SIG$__sig"} ;;
    *" $__sig") __cmd=${__cmd%" $__sig"} ;;
    *) return 0 ;;
  esac
  case "$__cmd" in
    \'*\') ;;
    *) return 0 ;;
  esac
  __cmd=${__cmd#\'}
  __cmd=${__cmd%\'}
  if [ -z "$__cmd" ]; then
    return 0
  fi
  printf -v "$__slot" '%s' "$__cmd"
  if [ "$__sig" = "EXIT" ]; then
    _SK_TRAP_HAD_EXIT=1
  fi
  log_debug "chaining existing trap for $__sig"
  return 0
}

# _sk_trap_run_sig SIG —— 执行该信号保存的调用方 handler（跑过即清空，避免重复）
_sk_trap_run_sig() {
  local __slot __cmd
  __slot=$(_sk_trap_slot "${1:-}") || return 0
  eval "__cmd=\${$__slot:-}"
  if [ -z "$__cmd" ]; then
    return 0
  fi
  printf -v "$__slot" '%s' ""
  if ! eval "$__cmd"; then
    log_warn "$(_t 'cleanup step failed'): $__cmd"
  fi
  return 0
}

_sk_trap_on_exit() {
  local __st=$?
  trap - EXIT INT TERM HUP
  trap_cleanup
  exit "$__st"
}

_sk_trap_on_int() {
  trap - EXIT INT TERM HUP
  trap_cleanup
  _sk_trap_run_sig INT
  exit 130
}

_sk_trap_on_term() {
  trap - EXIT INT TERM HUP
  trap_cleanup
  _sk_trap_run_sig TERM
  exit 143
}

_sk_trap_on_hup() {
  trap - EXIT INT TERM HUP
  trap_cleanup
  _sk_trap_run_sig HUP
  exit 129
}

# trap_install —— 安装 EXIT / INT / TERM / HUP 处理器；可重复调用
#
# 幂等性不能用标志位：子 shell 会继承变量，却不会继承「会执行」的 trap，
# 于是「以为装过了、其实没装」，退出时清理不执行。
#
# 也不能只靠「当前 shell 里有没有这个 trap」判断 —— bash 5 起，子 shell 里
# `trap -p EXIT` 仍会显示父 shell 设的 trap（实测 5.3：看得见、但子 shell 退出时
# 不执行），而 bash 3.2 显示为空。只查 trap -p 会在 bash 5 的子 shell 里静默漏装，
# 表现为「( ... ) 里的 lock_acquire 拿到锁却没在退出时释放」。
# 所以：我们自己装的 trap（含子 shell 里的残影）一律重装一遍（重装同处理器无害），
# 并且绝不把它当成「调用方原有的 handler」捕获下来，否则清理时会自噬。
trap_install() {
  local __sig
  for __sig in EXIT INT TERM HUP; do
    _sk_trap_read "$__sig" || continue
    case "${_SK_TRAP_CUR:-}" in
      # 自己的处理器（含子 shell 残影）不算调用方的 handler，否则清理会自噬
      *_sk_trap_on_*) ;;
      *) _sk_trap_capture "$__sig" ;;
    esac
  done
  trap '_sk_trap_on_exit' EXIT
  trap '_sk_trap_on_int' INT
  trap '_sk_trap_on_term' TERM
  trap '_sk_trap_on_hup' HUP
  return 0
}
