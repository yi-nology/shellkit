#!/usr/bin/env bash
#
# 逐个执行 tests/test_*.sh。
#   - 每个测试都从 /dev/null 取 stdin：测试不得依赖调用者的终端输入，
#     否则在 CI 或管道里会因为等待 stdin 而挂死。
#   - 有 timeout(1) 时给每个文件上限，卡死就报错而不是无限等待。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/shellkit-tests.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export TEST_TMP_ROOT="$TMP"

TEST_TIMEOUT="${TEST_TIMEOUT:-120}"
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN=timeout
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN=gtimeout
else
  TIMEOUT_BIN=""
fi

_run_one() {
  local __file=$1
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" "$TEST_TIMEOUT" bash "$__file" </dev/null
  else
    bash "$__file" </dev/null
  fi
}

passed=0
for test_file in "$ROOT"/tests/test_*.sh; do
  case "$test_file" in
    *test_helper.sh) continue ;;
  esac
  printf '\n==> %s\n' "$(basename "$test_file")"
  if ! _run_one "$test_file"; then
    printf '\nFAILED: %s\n' "$(basename "$test_file")" >&2
    exit 1
  fi
  passed=$((passed + 1))
done

printf '\nAll %d test files passed.\n' "$passed"
