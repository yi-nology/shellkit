#!/usr/bin/env bash
# 发布门禁与 CI job 的对账：ci.yml 里的每个 job 都必须出现在
# tools/release_gate.sh 的 DEFAULT_CHECKS 里（或者被明确标注为「只出报告」）。
#
# 为什么要有这一条（评估 2026-11-16）：v0.25.0 给 ci.yml 加了两个 job
# （release artifact smoke / cross-version upgrade matrix），但 DEFAULT_CHECKS
# 仍然是原来的 13 项 —— 于是「真产物验收」与「跨版本升级」即使红了，Release Gate
# 也可能因为其余 13 项全过而放行。这类漏洞不会自己报错，只会让某一天的发版
# 带着已知失败出门。所以把「清单一致」变成判据，而不是靠人记得同步。
#
# 双向：
#   1. ci.yml 的每个 job 名字必须在 DEFAULT_CHECKS 里（或属于 INFO_JOBS）；
#   2. DEFAULT_CHECKS 的每一项都必须对得上某个 ci.yml job（防止改名后留下幽灵项）。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

GATE="$TEST_ROOT/tools/release_gate.sh"
CI="$TEST_ROOT/.github/workflows/ci.yml"

# 只出报告、不挡发版的 job：仓库对 performance bench 的定位就是「CI 里只出报告」
# （见 Makefile help 与 ci.yml 的注释）。要往这里加东西必须有明确理由。
INFO_JOBS="performance bench"

# _gate_line FILE —— DEFAULT_CHECKS 那一行（含 | 分隔）
_gate_line() {
  grep -m1 '^DEFAULT_CHECKS=' "$1"
}

# _job_names FILE —— 每个 job 的 name:；矩阵 job 的 ${{ ... }} 动态部分截掉，只留字面前缀
_job_names() {
  awk '
    /^  [a-z][a-z0-9-]*:$/ { inj = 1; next }
    inj && /^    name: / {
      sub(/^    name: /, "")
      i = index($0, "${{")
      if (i > 0) { $0 = substr($0, 1, i - 1) }
      sub(/[ \t]+$/, "", $0)
      print
      inj = 0
    }
  ' "$1"
}

# _compare GATE CI —— 双向对账；打印违规并返回 1
_compare() {
  local __gate __ci __line __name __prefix __c __found __bad=0
  __gate=$1
  __ci=$2
  __line=$(_gate_line "$__gate")
  __names=$(_job_names "$__ci")

  # 方向 1：每个 CI job 都要在门禁清单里
  while IFS= read -r __name; do
    [ -n "$__name" ] || continue
    case " $INFO_JOBS " in
      *" $__name "*) continue ;;
    esac
    case "$__line" in
      *"$__name"*) ;;
      *)
        printf 'CI job not in the release gate: %s\n' "$__name"
        __bad=1
        ;;
    esac
  done <<EOF
$__names
EOF

  # 方向 2：门禁清单里的每一项都要对得上某个 job（防止 job 改名后留下幽灵项）
  __checks=$(printf '%s' "$__line" | sed 's/^DEFAULT_CHECKS="//; s/"$//' | tr '|' '\n')
  while IFS= read -r __c; do
    [ -n "$__c" ] || continue
    __found=0
    while IFS= read -r __name; do
      [ -n "$__name" ] || continue
      case "$__c" in
        "$__name"*)
          __found=1
          break
          ;;
      esac
    done <<EOF
$__names
EOF
    if [ "$__found" = "0" ]; then
      printf 'release gate entry has no CI job: %s\n' "$__c"
      __bad=1
    fi
  done <<EOF
$__checks
EOF
  return "$__bad"
}

# 正控：当前仓库必须对得上
rc=0
out=$(_compare "$GATE" "$CI" 2>&1) || rc=$?
assert_eq "0" "$rc" "the release gate must list every CI job (violations: $out)"
assert_eq "" "$out" "the reconciliation must report no violation on the current tree"

# 统计口径要看得见：漏一个 job 就必须红，而不是「看起来差不多」
assert_contains "$(_gate_line "$GATE")" "release artifact smoke" \
  "the release artifact smoke job must be a required release check"
assert_contains "$(_gate_line "$GATE")" "cross-version upgrade matrix" \
  "the cross-version upgrade matrix must be a required release check"

# 自证（把缺陷造回去必须变红）：从副本里删掉一个 job，_compare 必须报出来
d=$(tmpdir)
mkdir -p "$d/tools" "$d/.github/workflows"
cp "$GATE" "$d/tools/release_gate.sh"
cp "$CI" "$d/.github/workflows/ci.yml"
# 把 ci.yml 里 bats 这个 job 的名字改掉 —— 门禁清单里还是旧名字，两个方向都该报
sed -i.bak 's/^    name: bats suite$/    name: bats suite renamed/' "$d/.github/workflows/ci.yml"
rm -f "$d/.github/workflows/ci.yml.bak"
rc=0
out=$(_compare "$d/tools/release_gate.sh" "$d/.github/workflows/ci.yml" 2>&1) || rc=$?
assert_ne "0" "$rc" "a renamed CI job must break the reconciliation"
assert_contains "$out" "bats suite renamed" "the violation must name the orphaned job"
assert_contains "$out" "bats suite" "the violation must name the stale gate entry"

exit 0
