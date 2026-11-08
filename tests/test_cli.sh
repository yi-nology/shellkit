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

cmd_force() {
  local force=""
  cli_opt_init
  cli_opt force --force -f
  cli_opts "$@" || return $?
  printf 'force=[%s]\n' "$force"
}

cmd_target() {
  local target=""
  cli_opt_init
  cli_opt target --target -t 1
  cli_opts "$@" || return $?
  printf 'target=[%s]\n' "$target"
}

cli_group "Demo"
cli_cmd greet "greet someone" "greet [--name NAME] [NAME]"
cli_cmd two-parts "dashed name maps to underscore handler"
cli_cmd boom "always fails"
cli_cmd quiet "fails silently"
cli_cmd force "boolean option"
cli_cmd target "option with a value"

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

assert_eq "$(tr -d '[:space:]' <"$TEST_ROOT/VERSION")" "$(cli_run --version 2>/dev/null)" "version output"

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

# 布尔选项不接受 --flag=value：把 "garbage" 写进变量比直接拒绝难查得多
assert_eq "force=[1]" "$(cli_run force --force 2>/dev/null)" "a boolean option sets 1"
assert_eq "force=[1]" "$(cli_run force -f 2>/dev/null)" "a boolean short option sets 1"
assert_exit_code 2 cli_run force --force=yes 2>/dev/null
assert_contains "$(cli_run force --force=yes 2>&1 >/dev/null)" "--force" "the rejected option is named"

# 带值选项的 --opt=value 仍然可用
assert_eq "target=[x]" "$(cli_run target --target=x 2>/dev/null)" "an option with a value still accepts ="

# 重名注册必须当场拒绝，而不是让解析静默命中最后一个
assert_exit_code 2 bash -c '. "$1/lib/bootstrap.sh"; cli_opt_init; cli_opt a --same; cli_opt b --same' _ "$TEST_ROOT"
assert_exit_code 2 bash -c '. "$1/lib/bootstrap.sh"; cli_opt_init; cli_opt a --x -q; cli_opt b --y -q' _ "$TEST_ROOT"

# 补印分支是死代码：handler 只通过 log_error 报错，错误必须只出现一次
err=$(cli_run boom 2>&1 >/dev/null)
assert_eq "1" "$(printf '%s\n' "$err" | grep -c 'kaboom')" "a failing command reports its error exactly once"
