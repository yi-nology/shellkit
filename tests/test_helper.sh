#!/usr/bin/env bash
# 极简断言库。断言失败即 exit 1，由 tests/run.sh 逐文件执行。

TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"
TEST_TMP_ROOT="${TEST_TMP_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/shellkit-tests.XXXXXX")}"
export TEST_ROOT TEST_TMP_ROOT

_fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local __expected=$1 __actual=$2 __msg=${3:-values differ}
  if [ "$__actual" != "$__expected" ]; then
    _fail "$__msg: expected <$__expected>, got <$__actual>"
  fi
  return 0
}

assert_ne() {
  local __unexpected=$1 __actual=$2 __msg=${3:-values should differ}
  if [ "$__actual" = "$__unexpected" ]; then
    _fail "$__msg: both are <$__actual>"
  fi
  return 0
}

assert_contains() {
  local __haystack=$1 __needle=$2 __msg=${3:-value does not contain expected text}
  case "$__haystack" in
    *"$__needle"*) return 0 ;;
  esac
  _fail "$__msg: <$__needle>"
}

assert_not_contains() {
  local __haystack=$1 __needle=$2 __msg=${3:-value unexpectedly contains text}
  case "$__haystack" in
    *"$__needle"*) _fail "$__msg: <$__needle>" ;;
  esac
  return 0
}

assert_true() {
  if ! "$@"; then
    _fail "expected success: $*"
  fi
  return 0
}

assert_false() {
  if "$@"; then
    _fail "expected failure: $*"
  fi
  return 0
}

assert_exit_code() {
  local __want=$1
  shift
  local __got=0
  "$@" || __got=$?
  if [ "$__got" != "$__want" ]; then
    _fail "expected exit $__want, got $__got: $*"
  fi
  return 0
}

assert_stdout_empty() {
  local __out
  __out=$("$@" 2>/dev/null) || true
  if [ -n "$__out" ]; then
    _fail "expected empty stdout, got <$__out>"
  fi
  return 0
}

_file_mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

assert_file_mode() {
  local __file=$1 __want=$2 __got
  __got=$(_file_mode "$__file")
  if [ "$__got" != "$__want" ]; then
    _fail "expected mode $__want for $__file, got $__got"
  fi
  return 0
}

# 每个测试文件新建互不干扰的子目录
tmpdir() {
  local __d
  __d=$(mktemp -d "$TEST_TMP_ROOT/case.XXXXXX") || return 1
  printf '%s\n' "$__d"
}
