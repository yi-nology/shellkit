#!/usr/bin/env bats

# upgrade 的独立用例：每个 @test 一个进程，互不影响。
#
# 与 tests/test_upgrade.sh 的分工：那边是自研断言库（一次跑完一串断言），
# 这边是 bats（每个用例独立进程，失败能精确定位到用例）。

setup() {
  TEST_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SK="$TEST_ROOT/shellkit"
  work="$(mktemp -d "${BATS_TEST_TMPDIR}/sk.XXXXXX")"
  cp -R "$TEST_ROOT/templates" "$work/tpl"
  "$SK" new --name tool "$work/proj" --cmd run --yes >/dev/null 2>&1
}

teardown() {
  if [ -n "${work:-}" ]; then
    rm -rf "$work"
  fi
}

@test "a locally edited file survives two consecutive upgrades" {
  printf 'LOCAL EDIT\n' >>"$work/proj/README.md"

  run "$SK" upgrade "$work/proj" --template "$work/tpl"
  [ "$status" -eq 0 ]
  [[ "$output" == *"left alone"* ]]

  # 第二次才是真正的考题：第一次升级把清单重写过，
  # 如果基线被推进成「用户改过的内容」，这一次就会覆盖掉它
  run "$SK" upgrade "$work/proj" --template "$work/tpl"
  [ "$status" -eq 0 ]
  [[ "$output" == *"left alone"* ]]

  run cat "$work/proj/README.md"
  [[ "$output" == *"LOCAL EDIT"* ]]
}

@test "an unmodified file is updated and the project stays usable" {
  printf '\nTEMPLATE ADDITION\n' >>"$work/tpl/AGENTS.md"

  run "$SK" upgrade "$work/proj" --template "$work/tpl"
  [ "$status" -eq 0 ]
  [[ "$output" == *"updated"* ]]

  run cat "$work/proj/AGENTS.md"
  [[ "$output" == *"TEMPLATE ADDITION"* ]]

  run "$work/proj/bin/tool" --help
  [ "$status" -eq 0 ]
}

@test "a missing file is restored by the upgrade" {
  rm -f "$work/proj/README.md"

  run "$SK" upgrade "$work/proj" --template "$work/tpl"
  [ "$status" -eq 0 ]
  [[ "$output" == *"added"* ]]

  [ -f "$work/proj/README.md" ]
}

@test "a directory without a manifest is rejected without touching files" {
  mkdir -p "$work/plain"
  printf 'hello\n' >"$work/plain/README.md"

  run "$SK" upgrade "$work/plain" --template "$work/tpl"
  [ "$status" -eq 3 ]

  run cat "$work/plain/README.md"
  [ "$output" = "hello" ]
}
