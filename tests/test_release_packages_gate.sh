#!/usr/bin/env bash
# 发布门禁：deb/rpm 必须在**公开之前**构建、冒烟、签名并进入 draft（issue #127）。
#
# 要守的事：旧流程里 packages job `needs: release` 且 `continue-on-error: true`
# —— 系统包在 Release 公开之后才构建，失败了 run 仍然绿。于是「Release 页面
# 存在且绿」与「承诺的发行资产齐全」是两件事（v0.26.0 / v0.26.1 实际缺过包）。
#
# 判据（release.yml 结构扫描）：
#   1. 不得出现 continue-on-error（整条发布链路没有可选步骤）；
#   2. 不得有独立的 packages job（系统包属于 release job 的公开前验收）；
#   3. 顺序：build deb → build rpm → sign the system packages → create draft →
#      verify draft → publish；任何一步排在 publish 之后即红；
#   4. draft 资产清单必须点名 .deb / .rpm；
#   5. 自检 job 仍以 --require-packages 复核已发布资产。
#
# 自证：把 deb 构建步骤挪到 publish 之后、给 release job 加回 continue-on-error，
# 判据都必须报出来（坏实现会红）。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

WF="$TEST_ROOT/.github/workflows/release.yml"
if [ ! -f "$WF" ]; then
  printf 'NA: .github/workflows/release.yml is not in this tree — the packages gate check is skipped\n'
  exit 0
fi

# _gate_violations FILE —— 违规文本（空 = 通过）
_gate_violations() {
  local __f=$1 __n=0 __line='' __trim=''
  local __deb='' __rpm='' __sign='' __create='' __verify='' __publish='' __coe=0 __pkgs=0
  while IFS= read -r __line || [ -n "$__line" ]; do
    __n=$((__n + 1))
    # 注释行不算：文档里写的 continue-on-error / 历史说明不是真配置
    __trim=$__line
    while [ "${__trim# }" != "$__trim" ]; do __trim=${__trim# }; done
    case $__trim in
      '#'*) continue ;;
    esac
    case "$__line" in
      *'name: build deb and smoke it'*) [ -n "$__deb" ] || __deb=$__n ;;
      *'name: build rpm and smoke it'*) [ -n "$__rpm" ] || __rpm=$__n ;;
      *'name: sign the system packages'*) [ -n "$__sign" ] || __sign=$__n ;;
      *'name: create a draft release'*) [ -n "$__create" ] || __create=$__n ;;
      *'name: verify the draft assets'*) [ -n "$__verify" ] || __verify=$__n ;;
      *'draft=false'*) [ -n "$__publish" ] || __publish=$__n ;;
      *'continue-on-error'*) __coe=$((__coe + 1)) ;;
      '  packages:'*) __pkgs=1 ;;
    esac
  done <"$__f"

  if [ "$__coe" -ne 0 ]; then
    printf 'release.yml still has %s continue-on-error directive(s)\n' "$__coe"
  fi
  if [ "$__pkgs" -ne 0 ]; then
    printf 'a separate packages job still exists (system packages must be a pre-publish gate)\n'
  fi
  if [ -z "$__deb" ] || [ -z "$__rpm" ] || [ -z "$__sign" ]; then
    printf 'missing one of the deb/rpm build or package-signing steps\n'
    return 0
  fi
  if [ -z "$__publish" ] || [ -z "$__create" ] || [ -z "$__verify" ]; then
    printf 'missing one of create draft / verify draft / publish steps\n'
    return 0
  fi
  if [ "$__deb" -ge "$__publish" ]; then
    printf 'deb build is not before publish (deb=%s publish=%s)\n' "$__deb" "$__publish"
  fi
  if [ "$__rpm" -ge "$__publish" ]; then
    printf 'rpm build is not before publish (rpm=%s publish=%s)\n' "$__rpm" "$__publish"
  fi
  if [ "$__sign" -ge "$__publish" ]; then
    printf 'system packages are signed after publish (sign=%s publish=%s)\n' "$__sign" "$__publish"
  fi
  if [ "$__create" -ge "$__publish" ] || [ "$__verify" -ge "$__publish" ]; then
    printf 'draft create/verify must both precede publish (create=%s verify=%s publish=%s)\n' \
      "$__create" "$__verify" "$__publish"
  fi
  if [ "$__deb" -ge "$__create" ] || [ "$__rpm" -ge "$__create" ] || [ "$__sign" -ge "$__create" ]; then
    printf 'deb/rpm must be built and signed before the draft is created\n'
  fi
  return 0
}

# _step_block FILE STEP_NAME —— 打印该步骤整段（到下一个步骤之前）
_step_block() {
  awk -v want="$1" '
    BEGIN { on = 0 }
    /^      - name: / {
      name = $0
      sub(/^      - name: /, "", name)
      on = (name == want) ? 1 : 0
      if (on) print
      next
    }
    on && /^      - name: / { on = 0 }
    on { print }
  ' "$2"
}

out=$(_gate_violations "$WF")
assert_eq "" "$out" "deb/rpm must be built and signed before publish (violations: $out)"

create_block=$(_step_block "create a draft release" "$WF")
assert_contains "$create_block" 'shellkit-$ver.deb' "the draft must carry the .deb asset"
assert_contains "$create_block" 'shellkit-$ver.rpm' "the draft must carry the .rpm asset"

self_block=$(_step_block "verify the published asset list" "$WF")
assert_contains "$self_block" "--require-packages" "the published self-check must require the packages"

# 自证 1：把 deb 构建步骤挪到 publish 之后，判据必须报「不在 publish 之前」。
d=$(tmpdir)
python3 - "$WF" "$d/tampered.yml" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
start = text.index("      - name: build deb and smoke it")
end = text.index("      - name: build rpm and smoke it", start)
deb = text[start:end]
rest = text[:start] + text[end:]
# 插到 publish 步骤之后（文件末尾即可：publish 是 release job 的最后一步）
open(dst, "w", encoding="utf-8").write(rest.rstrip("\n") + "\n\n" + deb)
PY
assert_contains "$(_gate_violations "$d/tampered.yml")" "deb build is not before publish" \
  "moving the deb build after publish must break the gate"

# 自证 2：给 release job 加回 continue-on-error，判据必须报出来。
d2=$(tmpdir)
awk '
  /^  release:/ { on = 1 }
  on && /^    name:/ { print; print "    continue-on-error: true"; next }
  { print }
' "$WF" >"$d2/release.yml"
assert_contains "$(_gate_violations "$d2/release.yml")" "continue-on-error" \
  "reintroducing continue-on-error must break the gate"

exit 0