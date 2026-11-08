#!/usr/bin/env bash
#
# 交互式问答。
#   - 非交互（SHELLKIT_NONINTERACTIVE=1 或 stdin 不是 tty）：取默认值；没有默认值则失败，不静默返回空。
#   - 超时：read -t；Bash 3 与 Bash 4 的退出码差异在 _sk_read_line 内消化。
#   - 只有真正超时才回退默认值，EOF 视为错误。

# _sk_read_line VAR [TIMEOUT]
#   0 = 读到内容；1 = EOF/被中断；2 = 超时
_sk_read_line() {
  local __var=$1 __timeout=${2:-} __line="" __rc=0 __start=0
  if [ -z "$__timeout" ] || [ "$__timeout" = "0" ]; then
    IFS= read -r __line || __rc=$?
  else
    __start=$SECONDS
    IFS= read -r -t "$__timeout" __line || __rc=$?
    if [ "$__rc" != "0" ]; then
      if [ "$__rc" -gt 128 ] 2>/dev/null; then
        __rc=2
      elif [ $((SECONDS - __start)) -ge "$__timeout" ]; then
        __rc=2
      fi
    fi
  fi
  printf -v "$__var" '%s' "$__line"
  return "$__rc"
}

# _sk_ask_raw VAR RENDERED_PROMPT [DEFAULT] [TIMEOUT]
_sk_ask_raw() {
  local __var=$1 __msg=$2 __default=${3:-} __timeout=${4:-} __line="" __rc=0
  if [ "${SHELLKIT_NONINTERACTIVE:-0}" = "1" ] || [ ! -t 0 ]; then
    if [ -z "$__default" ]; then
      log_error "$(_t 'Non-interactive mode requires a default value'): $__msg"
      return "$SK_PRECOND"
    fi
    printf -v "$__var" '%s' "$__default"
    log_warn "$(_t 'Non-interactive, using default'): $__default"
    return 0
  fi
  printf '%s: ' "$__msg" >&2
  _sk_read_line __line "$__timeout" || __rc=$?
  if [ "$__rc" = "2" ]; then
    if [ -z "$__default" ]; then
      log_error "$(_t 'Input timed out and no default is set'): $__msg"
      return "$SK_PRECOND"
    fi
    log_warn "$(_t 'Input timed out, using default'): $__default"
    printf -v "$__var" '%s' "$__default"
    return 0
  fi
  if [ "$__rc" != "0" ]; then
    log_error "$(_t 'Input closed unexpectedly')"
    return "$SK_ERR"
  fi
  if [ -z "$__line" ]; then
    __line=$__default
  fi
  printf -v "$__var" '%s' "$__line"
  return 0
}

# ask VAR PROMPT [DEFAULT] [TIMEOUT]
ask() {
  local __var=$1 __prompt=$2 __default=${3:-} __timeout=${4:-} __msg
  if ! _sk_is_name "$__var"; then
    log_error "$(_t 'invalid variable name'): $__var"
    return "$SK_USAGE"
  fi
  __msg=$__prompt
  if [ -n "$__default" ]; then
    __msg="$__msg [$(_t 'default'): $__default] "
  fi
  _sk_ask_raw "$__var" "$__msg" "$__default" "$__timeout"
}

# ask_yn VAR PROMPT [DEFAULT=y] [TIMEOUT] —— 结果写入 y 或 n
ask_yn() {
  local __var=$1 __prompt=$2 __default=${3:-y} __timeout=${4:-} _sk_ans="" _sk_tries=0 _sk_msg _sk_hint
  if ! _sk_is_name "$__var"; then
    log_error "$(_t 'invalid variable name'): $__var"
    return "$SK_USAGE"
  fi
  case "$__default" in
    y | Y | yes | YES) _sk_hint="[Y/n]" ;;
    *) _sk_hint="[y/N]" ;;
  esac
  _sk_msg="$__prompt $_sk_hint"
  while [ "$_sk_tries" -lt 3 ]; do
    _sk_tries=$((_sk_tries + 1))
    _sk_ask_raw _sk_ans "$_sk_msg" "$__default" "$__timeout" || return $?
    _sk_ans=$(printf '%s' "$_sk_ans" | tr '[:upper:]' '[:lower:]')
    if [ -z "$_sk_ans" ]; then
      _sk_ans=$(printf '%s' "$__default" | tr '[:upper:]' '[:lower:]')
    fi
    case "$_sk_ans" in
      y | yes)
        printf -v "$__var" '%s' "y"
        return 0
        ;;
      n | no)
        printf -v "$__var" '%s' "n"
        return 0
        ;;
    esac
    log_warn "$(_t 'please answer y or n')"
  done
  return "$SK_USAGE"
}

# ask_choice VAR PROMPT "a|b|c" [DEFAULT] [TIMEOUT]
ask_choice() {
  local __var=$1 __prompt=$2 __choices=$3 __default=${4:-} __timeout=${5:-} _sk_ans="" _sk_tries=0 _sk_msg
  if ! _sk_is_name "$__var"; then
    log_error "$(_t 'invalid variable name'): $__var"
    return "$SK_USAGE"
  fi
  if [ -n "$__default" ]; then
    case "|$__choices|" in
      *"|$__default|"*) ;;
      *)
        log_error "$(_t 'default value is not one of the choices'): $__default"
        return "$SK_USAGE"
        ;;
    esac
  fi
  _sk_msg="$__prompt [$__choices]"
  if [ -n "$__default" ]; then
    _sk_msg="$_sk_msg ($(_t 'default'): $__default)"
  fi
  while [ "$_sk_tries" -lt 3 ]; do
    _sk_tries=$((_sk_tries + 1))
    _sk_ask_raw _sk_ans "$_sk_msg" "$__default" "$__timeout" || return $?
    case "|$__choices|" in
      *"|$_sk_ans|"*)
        printf -v "$__var" '%s' "$_sk_ans"
        return 0
        ;;
    esac
    log_warn "$(_t 'invalid choice'): $_sk_ans"
  done
  return "$SK_USAGE"
}

# confirm PROMPT [DEFAULT=n] [TIMEOUT] —— 只返回码
confirm() {
  local __prompt=${1:-} __default=${2:-n} __timeout=${3:-} _sk_confirm_ans=""
  ask_yn _sk_confirm_ans "$__prompt" "$__default" "$__timeout" || return $?
  if [ "$_sk_confirm_ans" = "y" ]; then
    return 0
  fi
  return 1
}
