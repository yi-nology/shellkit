#!/usr/bin/env bash
# 错误与前置条件检查

# die CODE MSG...
die() {
  local __code=${1:-1}
  shift
  log_error "$*"
  exit "$__code"
}

# fail CODE MSG...  —— 不退出，只返回码
fail() {
  local __code=${1:-1}
  shift
  log_error "$*"
  return "$__code"
}

# require_cmd CMD...
require_cmd() {
  local __c
  for __c in "$@"; do
    if ! command -v "$__c" >/dev/null 2>&1; then
      log_error "$(_t 'Required command not found'): $__c"
      return "$SK_PRECOND"
    fi
  done
  return 0
}

# require_root
require_root() {
  if [ "$(id -u 2>/dev/null)" = "0" ]; then
    return 0
  fi
  log_error "$(_t 'This action must be run as root')"
  return "$SK_PRECOND"
}

# require_file PATH...
require_file() {
  local __f
  for __f in "$@"; do
    if [ ! -e "$__f" ]; then
      log_error "$(_t 'Required file not found'): $__f"
      return "$SK_PRECOND"
    fi
  done
  return 0
}

# require_bash MAJOR [MINOR]
require_bash() {
  local __need_major=${1:-3} __need_minor=${2:-0}
  local __major=${BASH_VERSINFO[0]:-0} __minor=${BASH_VERSINFO[1]:-0}
  if [ "$__major" -gt "$__need_major" ]; then
    return 0
  fi
  if [ "$__major" -eq "$__need_major" ] && [ "$__minor" -ge "$__need_minor" ]; then
    return 0
  fi
  log_error "$(_t 'Bash version is too old'): $__need_major.$__need_minor (found ${BASH_VERSION:-unknown})"
  return "$SK_PRECOND"
}
