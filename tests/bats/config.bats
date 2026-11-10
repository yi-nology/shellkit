#!/usr/bin/env bats

# 配置模块的独立用例。
#
# 库函数在子 shell 里跑（bash -c）：库里的 run 与 bats 的 run 同名，
# 直接 source 进测试进程会把 bats 的断言助手顶掉。

setup() {
  TEST_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  work="$(mktemp -d "${BATS_TEST_TMPDIR}/sk.XXXXXX")"
}

teardown() {
  if [ -n "${work:-}" ]; then
    rm -rf "$work"
  fi
}

@test "conf_set updates an exported dotenv key in place" {
  printf 'export API_TOKEN=old\n' >"$work/app.env"

  run bash -c '
    set -u
    . "$1/lib/bootstrap.sh"
    f="$2"
    conf_init "$f" --format dotenv
    conf_set API_TOKEN new
    printf "%s|%s\n" "$(cat "$f")" "$(conf_get API_TOKEN)"
  ' _ "$TEST_ROOT" "$work/app.env"
  [ "$status" -eq 0 ]
  [[ "$output" == *"export API_TOKEN=new"* ]]
  [[ "$output" == *"|new"* ]]
}

@test "conf_unset removes an exported dotenv key" {
  printf 'export API_TOKEN=secret\nKEEP=me\n' >"$work/app.env"

  run bash -c '
    set -u
    . "$1/lib/bootstrap.sh"
    f="$2"
    conf_init "$f" --format dotenv
    conf_unset API_TOKEN
    cat "$f"
  ' _ "$TEST_ROOT" "$work/app.env"
  [ "$status" -eq 0 ]
  [[ "$output" != *"API_TOKEN"* ]]
  [[ "$output" == *"KEEP=me"* ]]
}

@test "conf_disable comments the line out and keeps the value" {
  printf 'export API_TOKEN=secret\n' >"$work/app.env"

  run bash -c '
    set -u
    . "$1/lib/bootstrap.sh"
    f="$2"
    conf_init "$f" --format dotenv
    conf_disable API_TOKEN
    cat "$f"
  ' _ "$TEST_ROOT" "$work/app.env"
  [ "$status" -eq 0 ]
  [[ "$output" == *"# export API_TOKEN=secret"* ]]
}
