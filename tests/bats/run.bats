#!/usr/bin/env bats

# run / run_concurrent / parallel_map 的独立用例。

setup() {
  TEST_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  work="$(mktemp -d "${BATS_TEST_TMPDIR}/sk.XXXXXX")"
}

teardown() {
  if [ -n "${work:-}" ]; then
    rm -rf "$work"
  fi
}

@test "a password never reaches the log" {
  run bash -c '
    set -u
    . "$1/lib/bootstrap.sh"
    run --no-die sh -c "exit 3" --password hunter2
  ' _ "$TEST_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" != *"hunter2"* ]]
  [[ "$output" == *"command failed"* ]]
}

@test "a token in KEY=VALUE form never reaches the log" {
  run bash -c '
    set -u
    . "$1/lib/bootstrap.sh"
    run --no-die sh -c "exit 3" API_TOKEN=abc123
  ' _ "$TEST_ROOT"
  [[ "$output" != *"abc123"* ]]
}

@test "an instance killed by a signal is not counted as a success" {
  run bash -c '
    set -u
    . "$1/lib/bootstrap.sh"
    ok=$(run_concurrent 1 -- sh -c "kill -9 \$PPID" 2>/dev/null) || true
    printf "%s\n" "$ok"
  ' _ "$TEST_ROOT"
  [[ "$output" != *"1"* ]]
}

@test "parallel_map reports one result line per item" {
  run bash -c '
    set -u
    . "$1/lib/bootstrap.sh"
    printf "%s\n" alpha beta gamma | parallel_map 2 -- sh -c "exit 0" _
  ' _ "$TEST_ROOT"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [[ "${lines[0]}" == *"alpha"* ]]
  [[ "${lines[2]}" == *"gamma"* ]]
}

@test "parallel_map returns the first failing item's exit code" {
  run bash -c '
    set -u
    . "$1/lib/bootstrap.sh"
    printf "%s\n" ok bad | parallel_map 2 -- sh -c "[ \"\$1\" = bad ] && exit 9; exit 0" _
  ' _ "$TEST_ROOT"
  [ "$status" -eq 9 ]
}
