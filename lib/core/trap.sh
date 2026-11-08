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

# _sk_trap_capture SIG —— 把调用方已有的同名 trap 存下来，稍后链式执行
_sk_trap_capture() {
  local __sig=$1 __line __cmd
  _sk_trap_read "$__sig" || return 0
  __line=$_SK_TRAP_CUR
  case "$__line" in
    "trap -- "*) ;;
    *) return 0 ;;
  esac
  __cmd=${__line#trap -- }
  __cmd=${__cmd%" $__sig"}
  case "$__cmd" in
    \'*\') ;;
    *) return 0 ;;
  esac
  __cmd=${__cmd#\'}
  __cmd=${__cmd%\'}
  if [ -z "$__cmd" ]; then
    return 0
  fi
  _SK_TRAP_SAVED_EXIT=$__cmd
  _SK_TRAP_HAD_EXIT=1
  log_debug "chaining existing trap for $__sig"
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
  exit 130
}

_sk_trap_on_term() {
  trap - EXIT INT TERM HUP
  trap_cleanup
  exit 143
}

_sk_trap_on_hup() {
  trap - EXIT INT TERM HUP
  trap_cleanup
  exit 129
}

# trap_install —— 安装 EXIT / INT / TERM / HUP 处理器；可重复调用
#
# 幂等性靠「查当前 shell 里真的有这个 trap」判断，不用标志位：
# 子 shell 会继承变量，却不会继承已捕获的 trap（POSIX 规定重置为默认），
# 所以标志位会导致「以为装过了、其实没装」，退出时清理不执行。
trap_install() {
  _sk_trap_read EXIT || true
  case "${_SK_TRAP_CUR:-}" in
    *"_sk_trap_on_exit"*) return 0 ;;
  esac
  _sk_trap_capture EXIT
  trap '_sk_trap_on_exit' EXIT
  trap '_sk_trap_on_int' INT
  trap '_sk_trap_on_term' TERM
  trap '_sk_trap_on_hup' HUP
  return 0
}
