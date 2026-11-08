#!/usr/bin/env bash
#
# 日志。全部写 stderr —— 这是全库最重要的约定：
# stdout 只留给数据，所以 v=$(conf_get KEY) 永远不会混进 [INFO]。

_sk_color_on() {
  case "${SHELLKIT_COLOR:-auto}" in
    always) return 0 ;;
    never) return 1 ;;
    *) [ -t 2 ] ;;
  esac
}

if _sk_color_on; then
  SK_COLOR_ON=1
else
  SK_COLOR_ON=0
fi

_sk_log() {
  local __level=$1 __color=$2
  shift 2
  if [ "${SK_COLOR_ON:-0}" = "1" ] && [ -n "$__color" ]; then
    printf '\033[%sm[%s]\033[0m %s\n' "$__color" "$__level" "$*" >&2
  else
    printf '[%s] %s\n' "$__level" "$*" >&2
  fi
}

log_info() { _sk_log INFO "" "$@"; }
log_ok() { _sk_log " OK " "1;32" "$@"; }
log_warn() { _sk_log WARN "1;33" "$@"; }

log_error() {
  # 公开变量：cli_run 负责补印一次
  # shellcheck disable=SC2034
  SK_ERRMSG="$*"
  _SK_ERRMSG_SHOWN=1
  _sk_log ERROR "1;31" "$@"
}

log_debug() {
  if [ "${SHELLKIT_DEBUG:-0}" = "1" ]; then
    _sk_log DEBUG "1;36" "$@"
  fi
  return 0
}

log_section() {
  if [ "${SK_COLOR_ON:-0}" = "1" ]; then
    printf '\n\033[1;33m==> %s\033[0m\n' "$*" >&2
  else
    printf '\n==> %s\n' "$*" >&2
  fi
}
