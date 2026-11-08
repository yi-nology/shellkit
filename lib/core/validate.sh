#!/usr/bin/env bash
# 校验器。统一行为：通过返回 0，失败返回 1 并把原因写入 SK_VALIDATE_ERR。

# 调用方读取最近一次校验失败原因
# shellcheck disable=SC2034
SK_VALIDATE_ERR=""

_sk_vfail() {
  SK_VALIDATE_ERR="${1:-}"
  return 1
}

# validate_not_empty VALUE
validate_not_empty() {
  if [ -n "${1:-}" ]; then
    return 0
  fi
  _sk_vfail "$(_t 'value must not be empty')"
}

# validate_single_line VALUE —— 配置文件的值不允许换行
validate_single_line() {
  case "${1:-}" in
    *$'\n'* | *$'\r'*)
      _sk_vfail "$(_t 'value must be a single line')"
      return 1
      ;;
  esac
  return 0
}

# validate_key VALUE —— 合法配置键名
validate_key() {
  case "${1:-}" in
    [A-Za-z_]*) ;;
    *)
      _sk_vfail "$(_t 'invalid configuration key'): ${1:-}"
      return 1
      ;;
  esac
  case "${1:-}" in
    *[!A-Za-z0-9_]*)
      _sk_vfail "$(_t 'invalid configuration key'): ${1:-}"
      return 1
      ;;
  esac
  return 0
}

# validate_port VALUE
validate_port() {
  local __v="${1:-}"
  case "$__v" in
    '' | *[!0-9]*)
      _sk_vfail "$(_t 'port must be a number'): $__v"
      return 1
      ;;
  esac
  if [ "$__v" -ge 1 ] && [ "$__v" -le 65535 ]; then
    return 0
  fi
  _sk_vfail "$(_t 'port out of range'): $__v"
}

# validate_ip VALUE
validate_ip() {
  local __v="${1:-}" __o
  if ! [[ "$__v" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    _sk_vfail "$(_t 'invalid IPv4 address'): $__v"
    return 1
  fi
  for __o in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"; do
    if [ "$__o" -gt 255 ]; then
      _sk_vfail "$(_t 'invalid IPv4 address'): $__v"
      return 1
    fi
  done
  return 0
}

# validate_version VALUE
validate_version() {
  local __v="${1:-}"
  if [[ "$__v" =~ ^v?[0-9]+(\.[0-9]+){0,2}([-.+][0-9A-Za-z.-]+)?$ ]]; then
    return 0
  fi
  _sk_vfail "$(_t 'invalid version'): $__v"
}

# validate_abs_path VALUE
validate_abs_path() {
  case "${1:-}" in
    /*) return 0 ;;
  esac
  _sk_vfail "$(_t 'path must be absolute'): ${1:-}"
}

# validate_url VALUE
validate_url() {
  local __v="${1:-}"
  if [[ "$__v" =~ ^https?://[^[:space:]]+$ ]]; then
    return 0
  fi
  _sk_vfail "$(_t 'invalid URL'): $__v"
}

# validate_enum VALUE "a|b|c"
validate_enum() {
  local __v="${1:-}" __choices="${2:-}"
  case "|$__choices|" in
    *"|$__v|"*) return 0 ;;
  esac
  _sk_vfail "$(_t 'value not in allowed set'): $__v ($__choices)"
}
