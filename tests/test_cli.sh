#!/usr/bin/env bash
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"

cmd_greet() {
  local name="world"
  cli_opt_init
  cli_opt name --name -n 1
  cli_opts "$@" || return $?
  if [ "${#SK_OPTS_LEFT[@]}" -gt 0 ]; then
    name=${SK_OPTS_LEFT[0]}
  fi
  printf 'hello %s\n' "$name"
}

cmd_boom() {
  log_error "kaboom"
  return 1
}

cmd_quiet() {
  return 1
}

cmd_two_parts() {
  printf 'dashed\n'
}

cli_group "Demo"
cli_cmd greet "greet someone" "greet [--name NAME] [NAME]"
cli_cmd two-parts "dashed name maps to underscore handler"
cli_cmd boom "always fails"
cli_cmd quiet "fails silently"

assert_eq "hello world" "$(cli_run greet 2>/dev/null)" "dispatch with default arg"
assert_eq "hello alice" "$(cli_run greet alice 2>/dev/null)" "positional arg"
assert_eq "hello bob" "$(cli_run greet --name=bob 2>/dev/null)" "long option with ="
assert_eq "hello carol" "$(cli_run greet --name carol 2>/dev/null)" "long option with separate value"
assert_eq "hello dave" "$(cli_run greet -n dave 2>/dev/null)" "short option"

assert_exit_code 2 cli_run greet --nope 2>/dev/null
assert_exit_code 2 cli_run greet --name 2>/dev/null

help_out=$(cli_run --help 2>/dev/null)
assert_contains "$help_out" "greet"
assert_contains "$help_out" "Demo"
assert_contains "$help_out" "--verbose"

assert_eq "0.1.0" "$(cli_run --version 2>/dev/null)" "version output"

assert_exit_code 2 cli_run nope 2>/dev/null

err=$(cli_run gre 2>&1 >/dev/null)
assert_contains "$err" "greet"

assert_exit_code 1 cli_run boom 2>/dev/null
assert_exit_code 1 cli_run quiet 2>/dev/null

err=$(cli_run quiet 2>&1 >/dev/null)
assert_eq "" "$err" "quiet failure prints nothing"

assert_eq "dashed" "$(cli_run two-parts 2>/dev/null)" "dashed command name dispatches to cmd_two_parts"

assert_exit_code 2 cli_cmd greet "dup" 2>/dev/null
assert_exit_code 2 cli_cmd "bad name" "x" 2>/dev/null
assert_exit_code 2 cli_cmd "1leading" "x" 2>/dev/null
assert_exit_code 2 cli_run 2>/dev/null
