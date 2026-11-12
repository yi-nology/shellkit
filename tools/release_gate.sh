#!/usr/bin/env bash
#
# release 质量准入：确认「被 tag 的那个 SHA」上全部必需检查都成功。
#
# tag 一推就发布是不行的：ci.yml 与 release.yml 之间没有任何依赖关系，
# CI 没跑、跑了但失败、或者还在跑，tag 照样能发布（issue #42）。
# GitHub 的一个事实：**从 tag 触发的工作流不会自动等另一个工作流**，
# 所以发布之前在这里主动查询同一 SHA 的 check-runs —— 查不到、没结论、
# 结论不是 success，一律不放行。
#
#   bash tools/release_gate.sh <commit-sha> [--timeout SEC] [--interval SEC] [--once]
#
# 退出码：0 全部必需检查成功 / 1 有失败或缺席（fail-closed）/ 2 用法错 /
#         3 等到超时还没有结论
#
# 必需检查清单是 ci.yml 的六个 job（矩阵 job 按 name 逐个点名）。
# SHELLKIT_GATE_CHECKS="a|b|c"（| 分隔）可整体覆盖 —— 供测试与应急使用。
# 必需性在这里显式声明：ci.yml 加删 job 要同步改这份清单。
set -u

PROG=tools/release_gate.sh
DEFAULT_CHECKS="test on macos-latest|test on macos-15|test on ubuntu-latest|test on ubuntu-22.04|test on ubuntu-24.04-arm|compat on debian:12 (ubuntu-latest)|compat on rockylinux:9 (ubuntu-latest)|compat on openeuler/openeuler:24.03-lts (ubuntu-latest)|compat on openeuler/openeuler:24.03-lts (ubuntu-24.04-arm)|bats suite|docs site|coverage ratchet|mutation campaign"

TIMEOUT=2400
INTERVAL=30
ONCE=0
SHA=""
CHECKS="${SHELLKIT_GATE_CHECKS:-$DEFAULT_CHECKS}"

_say() { printf '[gate] %s\n' "$*" >&2; }
_die() {
  printf '[gate] ERROR: %s\n' "$*" >&2
  exit "${2:-2}"
}

_usage() {
  printf '%s\n' \
    "usage: bash $PROG <commit-sha> [--timeout SEC] [--interval SEC] [--once]" \
    '' \
    '  <commit-sha>   被 tag 的那个 commit；必需检查查的就是它的 check-runs' \
    '  --timeout SEC  轮询上限（默认 2400）；到点还没结论按未通过处理' \
    '  --interval SEC 轮询间隔（默认 30）' \
    '  --once         只查一轮，不等待（测试与人工核对用）'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h | --help)
      _usage
      exit 0
      ;;
    --timeout)
      [ "$#" -ge 2 ] || _die "--timeout needs a value" 2
      TIMEOUT=$2
      shift
      ;;
    --timeout=*) TIMEOUT=${1#*=} ;;
    --interval)
      [ "$#" -ge 2 ] || _die "--interval needs a value" 2
      INTERVAL=$2
      shift
      ;;
    --interval=*) INTERVAL=${1#*=} ;;
    --once) ONCE=1 ;;
    --?*) _die "unknown option: $1" 2 ;;
    *)
      if [ -n "$SHA" ]; then
        _die "only one commit SHA is allowed: $1" 2
      fi
      SHA=$1
      ;;
  esac
  shift
done

case "$SHA" in
  '' | *[!0-9a-fA-F]*) _die "a commit SHA is required (got: ${SHA:-nothing})" 2 ;;
esac

# 仓库归属：Actions 里有现成的 GITHUB_REPOSITORY；本地从 origin 反推
GATE_REPO=${GITHUB_REPOSITORY:-}
if [ -z "$GATE_REPO" ]; then
  __url=$(git config --get remote.origin.url 2>/dev/null) ||
    _die "cannot determine the GitHub repository (set GITHUB_REPOSITORY)" 2
  case "$__url" in
    git@github.com:*) GATE_REPO=${__url#git@github.com:} ;;
    https://github.com/*) GATE_REPO=${__url#https://github.com/} ;;
    *) _die "origin is not a GitHub remote: $__url" 2 ;;
  esac
  GATE_REPO=${GATE_REPO%.git}
fi

if ! command -v gh >/dev/null 2>&1; then
  # 查不了状态 = 验证不了 = 不发布（fail-closed）
  _die "gh is required to query check runs" 3
fi

# _gate_one NAME —— 查一个必需检查的结论，输出三种词之一：
#   MISSING（该 SHA 上根本没有这个名字的检查）/ PENDING（还没跑完）/
#   SUCCESS / FAILED:<conclusion>
_gate_one() {
  local __name=$1 __out
  __out=$(gh api -X GET "repos/$GATE_REPO/commits/$SHA/check-runs" \
    -f check_name="$__name" -f filter=latest -f per_page=100 \
    --jq 'if .total_count == 0 then "MISSING" else .check_runs[0].status + "/" + (.check_runs[0].conclusion // "none") end' 2>/dev/null) || {
    printf 'QUERY_FAILED'
    return 0
  }
  printf '%s' "$__out"
}

# _gate_count LIST —— 清单里实际有几条必需检查
#
# ⚠ 不能用 `printf '%s' "$LIST" | tr '|' '\n' | wc -l`：printf 不补尾换行，
# wc -l 数的是**换行符个数**而不是行数 ⇒ 永远比实际条数少 1（issue #70：
# 清单 13 条却报 12，跟下面 verdict 行的 13 对不上 —— 同一个清单两个数）。
# 这里按 | 逐段拆、空段丢掉 —— 与判定循环的口径完全一致。
_gate_count() {
  local __rest=${1:-} __n=0 __item
  while [ -n "$__rest" ]; do
    case "$__rest" in
      *'|'*)
        __item=${__rest%%|*}
        __rest=${__rest#*|}
        ;;
      *)
        __item=$__rest
        __rest=""
        ;;
    esac
    [ -n "$__item" ] || continue
    __n=$((__n + 1))
  done
  printf '%s' "$__n"
}

_say "repository: $GATE_REPO"
_say "commit: $SHA"
_say "required checks: $(_gate_count "$CHECKS")"

__waited=0
while :; do
  printf '%s\n' "$CHECKS" | tr '|' '\n' | while IFS= read -r __name; do
    [ -n "$__name" ] || continue
    __verdict=$(_gate_one "$__name")
    case "$__verdict" in
      SUCCESS) __v=ok ;;
      completed/success) __v=ok ;;
      MISSING) __v=missing ;;
      QUERY_FAILED) __v=query ;;
      completed/*) __v=fail ;;
      *) __v=pending ;;
    esac
    # 循环体在管道子 shell 里：计数器出不来，结论打进 stdout，
    # 由外层从结果文件里重新统计（见下）。
    printf '%s\t%s\n' "$__v" "$__name"
  done >"${TMPDIR:-/tmp}/release-gate-results.$$"

  # 子 shell 计数器出不来，用结果文件重新统计
  __pending=0 __failed=0 __passed=0
  __first_bad=""
  while IFS=$'\t' read -r __v __name; do
    case "$__v" in
      ok) __passed=$((__passed + 1)) ;;
      pending) __pending=$((__pending + 1)) ;;
      *)
        __failed=$((__failed + 1))
        [ -n "$__first_bad" ] || __first_bad="$__name ($__v)"
        ;;
    esac
  done <"${TMPDIR:-/tmp}/release-gate-results.$$"
  while IFS=$'\t' read -r __v __name; do
    case "$__v" in
      ok) _say "  [ OK ] $__name" ;;
      pending) _say "  [....] $__name (pending)" ;;
      missing) _say "  [FAIL] $__name (missing — has ci.yml run on this SHA?)" ;;
      query) _say "  [FAIL] $__name (query failed)" ;;
      fail) _say "  [FAIL] $__name" ;;
    esac
  done <"${TMPDIR:-/tmp}/release-gate-results.$$"
  rm -f "${TMPDIR:-/tmp}/release-gate-results.$$"

  if [ "$__failed" -gt 0 ]; then
    _say "verdict: NOT PASSED — $__failed required check(s) failed or missing (first: $__first_bad)"
    exit 1
  fi
  if [ "$__pending" -eq 0 ]; then
    _say "verdict: PASSED — all $__passed required checks succeeded"
    exit 0
  fi
  _say "verdict: $__pending pending, $__passed passed so far"
  if [ "$ONCE" = "1" ]; then
    _say "stopping after one round (--once)"
    exit 3
  fi
  if [ "$__waited" -ge "$TIMEOUT" ]; then
    _say "timed out after ${TIMEOUT}s with checks still pending — refusing to publish"
    exit 3
  fi
  sleep "$INTERVAL"
  __waited=$((__waited + INTERVAL))
done
