#!/usr/bin/env bash
#
# 模板里含 {{NAME}} / {{CMD}} 这类占位符，直接对模板跑 shellcheck 会被当成语法错误。
# 这里先渲染成真实脚本，再按同一套规则检查——检查的是「生成出来的东西」。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"

if ! command -v shellcheck >/dev/null 2>&1; then
  printf 'shellcheck not installed, skipping template lint\n' >&2
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

render() {
  sed -e 's|{{NAME}}|demo|g' \
    -e 's|{{SHELLKIT_VERSION}}|0.0.0|g' \
    -e 's|{{CMD}}|start|g' \
    "$1" >"$2"
}

render "$ROOT/templates/bin/__NAME__" "$tmp/entry.sh"
render "$ROOT/templates/lib/app.sh" "$tmp/app.sh"
render "$ROOT/templates/commands/__CMD__.sh" "$tmp/cmd.sh"
render "$ROOT/templates/tests/test_smoke.sh" "$tmp/smoke.sh"

# 渲染产物在临时目录里，shellcheck 找不到仓库根上的 .shellcheckrc，显式传进去
shellcheck -S warning -x --rcfile "$ROOT/.shellcheckrc" "$tmp"/*.sh
