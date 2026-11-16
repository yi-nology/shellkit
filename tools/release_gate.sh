#!/usr/bin/env bash
#
# release 质量准入：确认「被 tag 的那个 SHA」上全部必需检查都成功。
#
# tag 一推就发布是不行的：ci.yml 与 release.yml 之间没有任何依赖关系，
# CI 没跑、跑了但失败、或者还在跑，tag 照样能发布（issue #42）。
# GitHub 的一个事实：**从 tag 触发的工作流不会自动等另一个工作流**，
# 所以发布之前在这里主动查询同一 SHA 的 check-runs。
#
# 必需检查分三种状态判（issue #85）——以前把「检查尚未注册」与「检查已
# 失败」混为一谈：push / tag 后立刻跑门禁是常态，CI 的 check-run 还没
# 注册到该 SHA 上，查不到就记 [FAIL] 属于竞态假红，重跑才过。
#   - 已完成（status=completed）⇒ 按 conclusion 判：success 放行，其余不放行；
#   - 进行中 / 尚未注册（status 未完成，或该 SHA 上根本查不到）⇒ 在超时
#     窗口内轮询等待 ——「还没注册」与「永不运行」在窗口内分不出来，等是
#     唯一不冤枉任何一方的做法；
#   - 超时后仍缺席 ⇒ 才判失败并说明原因（点名是谁、指路查 ci.yml 是否
#     在这个 SHA 上跑过、job 名是否与必需清单一致）。
#
# 第四种状态是「被 runner 取消」（conclusion=cancelled，常见于 macOS runner
# 配额/抢占）—— 那不是代码失败，也不该靠人盯着网页手动重跑。这里对每个检查
# **有限自动重跑一次**：从 check-run 的 details_url 里取出 run id，请求
# `gh run rerun <id> --failed`，然后继续轮询。同一个检查最多重跑一次：
# 重跑后又被取消 ⇒ 按失败处理（fail-closed，绝不因为「取消」而放行）。
# --no-rerun 可关掉自动重跑（应急与测试用）。
#
#   bash tools/release_gate.sh <commit-sha> [--timeout SEC] [--interval SEC] [--once] [--no-rerun]
#
# 退出码：0 全部必需检查成功 / 1 有失败（含重跑后仍被取消），或超时后仍缺席
#         （fail-closed）/ 2 用法错 / 3 等到超时还没有结论（进行中或尚未注册）
#
# 必需检查清单是 ci.yml 的六个 job（矩阵 job 按 name 逐个点名）。
# SHELLKIT_GATE_CHECKS="a|b|c"（| 分隔）可整体覆盖 —— 供测试与应急使用。
# 必需性在这里显式声明：ci.yml 加删 job 要同步改这份清单。
set -u

PROG=tools/release_gate.sh
DEFAULT_CHECKS="test on macos-latest|test on macos-15|test on ubuntu-latest|test on ubuntu-22.04|test on ubuntu-24.04-arm|compat on debian:12 (ubuntu-latest)|compat on rockylinux:9 (ubuntu-latest)|compat on openeuler/openeuler:24.03-lts (ubuntu-latest)|compat on openeuler/openeuler:24.03-lts (ubuntu-24.04-arm)|bats suite|docs site|coverage ratchet|mutation campaign|release artifact smoke|cross-version upgrade matrix"

TIMEOUT=2400
INTERVAL=30
ONCE=0
RERUN=1
SHA=""
CHECKS="${SHELLKIT_GATE_CHECKS:-$DEFAULT_CHECKS}"

_say() { printf '[gate] %s\n' "$*" >&2; }
_die() {
  printf '[gate] ERROR: %s\n' "$*" >&2
  exit "${2:-2}"
}

_usage() {
  printf '%s\n' \
    "usage: bash $PROG <commit-sha> [--timeout SEC] [--interval SEC] [--once] [--no-rerun]" \
    '' \
    '  <commit-sha>   被 tag 的那个 commit；必需检查查的就是它的 check-runs' \
    '  --timeout SEC  轮询上限（默认 2400）；到点还没结论按未通过处理' \
    '  --interval SEC 轮询间隔（默认 30）' \
    '  --once         只查一轮，不等待（测试与人工核对用）' \
    '  --no-rerun     检查被 runner 取消时不自动重跑（默认会自动重跑一次）'
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
    --no-rerun) RERUN=0 ;;
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

# _gate_one NAME —— 查一个必需检查的结论，输出「结论[ TAB details_url ]」：
#   MISSING（该 SHA 上还没有这个名字的检查 —— 可能尚未注册，也可能永不运行）
#   PENDING（还没跑完）/ SUCCESS / FAILED:<conclusion>
# MISSING 不在这里定生死：主循环把它当「未注册」处理（issue #85）。
# details_url 只在被取消时用得上（从里面取 run id 去重跑），别的结论不需要它 ——
# 所以测试桩只回「结论」也照样能用（没有 TAB 就当作没有 URL）。
_gate_one() {
  local __name=$1 __out
  __out=$(gh api -X GET "repos/$GATE_REPO/commits/$SHA/check-runs" \
    -f check_name="$__name" -f filter=latest -f per_page=100 \
    --jq 'if .total_count == 0 then "MISSING" else .check_runs[0].status + "/" + (.check_runs[0].conclusion // "none") + "\t" + (.check_runs[0].details_url // "") end' 2>/dev/null) || {
    printf 'QUERY_FAILED'
    return 0
  }
  printf '%s' "$__out"
}

# 自动重跑：每个检查最多争取一次。状态记在临时目录里 —— 进程重启就重来，
# 这正是想要的（一次失败的发布流程重新跑，等于又给了它一次机会）。
RERUN_DIR="${TMPDIR:-/tmp}/release-gate-rerun.$$"
mkdir -p "$RERUN_DIR" 2>/dev/null || true
trap 'rm -rf "${RERUN_DIR:?}"' EXIT INT TERM HUP

# _rerun_once NAME DETAILS_URL —— 请求重跑一次；返回 0 = 已经请求、继续等
# 返回 1 = 不重跑（禁用 / 没有 URL / 取不到 run id / 同一个检查已经用掉机会）
_rerun_once() {
  local __name=$1 __url=$2 __rest __runid
  [ "$RERUN" = "1" ] || return 1
  [ -n "$__url" ] || return 1
  case "$__url" in
    */actions/runs/*) ;;
    *) return 1 ;;
  esac
  __rest=${__url#*/actions/runs/}
  __runid=${__rest%%/*}
  case "$__runid" in
    '' | *[!0-9]*) return 1 ;;
  esac
  # 名字会变成文件名（坑 7）：只允许安全字符
  case "$__name" in
    */* | .* | '') return 1 ;;
  esac
  if [ -e "$RERUN_DIR/$__name" ]; then
    return 1
  fi
  : >"$RERUN_DIR/$__name" || return 1
  _say "  [RETRY] $__name — the runner cancelled it; requesting one re-run of run $__runid"
  # --failed 覆盖「有失败/被取消的 job」；老版本 gh 不认就退回整轮重跑
  if gh run rerun "$__runid" --failed >/dev/null 2>&1; then
    return 0
  fi
  if gh run rerun "$__runid" >/dev/null 2>&1; then
    return 0
  fi
  _say "  [FAIL] $__name (cancelled, and the re-run request was rejected)"
  return 1
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
    __raw=$(_gate_one "$__name")
    __url=""
    case "$__raw" in
      *$'\t'*)
        __verdict=${__raw%%$'\t'*}
        __url=${__raw#*$'\t'}
        ;;
      *) __verdict=$__raw ;;
    esac
    case "$__verdict" in
      SUCCESS) __v=ok ;;
      completed/success) __v=ok ;;
      MISSING) __v=missing ;;
      QUERY_FAILED) __v=query ;;
      # 被 runner 取消：不是代码失败，先争取一次重跑；机会用掉或请求不出去
      # 就按失败处理（fail-closed）。
      completed/cancelled)
        if _rerun_once "$__name" "$__url"; then
          __v=cancelled-retried
        else
          __v=cancelled-blocked
        fi
        ;;
      completed/*) __v=fail ;;
      *) __v=pending ;;
    esac
    # 循环体在管道子 shell 里：计数器出不来，结论打进 stdout，
    # 由外层从结果文件里重新统计（见下）。
    printf '%s\t%s\t%s\n' "$__v" "$__name" "$__verdict"
  done >"${TMPDIR:-/tmp}/release-gate-results.$$"

  # 子 shell 计数器出不来，用结果文件重新统计。
  # missing 与 pending 是两类「还没有结论」：前者是检查尚未注册，
  # 窗口内等、超时才判失败（issue #85）；后者照旧等。
  __pending=0 __failed=0 __passed=0 __missing=0 __retried=0
  __first_bad="" __first_missing=""
  while IFS=$'\t' read -r __v __name __raw; do
    case "$__v" in
      ok) __passed=$((__passed + 1)) ;;
      pending) __pending=$((__pending + 1)) ;;
      missing)
        __missing=$((__missing + 1))
        [ -n "$__first_missing" ] || __first_missing="$__name"
        ;;
      cancelled-retried)
        # 重跑请求已经发出去，这一轮当作「还在跑」——下一轮查的是新那次
        __retried=$((__retried + 1))
        __pending=$((__pending + 1))
        ;;
      cancelled-blocked)
        __failed=$((__failed + 1))
        [ -n "$__first_bad" ] || __first_bad="$__name (cancelled by the runner; the one re-run is spent or unavailable)"
        ;;
      *)
        __failed=$((__failed + 1))
        [ -n "$__first_bad" ] || __first_bad="$__name ($__v)"
        ;;
    esac
  done <"${TMPDIR:-/tmp}/release-gate-results.$$"
  while IFS=$'\t' read -r __v __name __raw; do
    case "$__v" in
      ok) _say "  [ OK ] $__name" ;;
      pending) _say "  [....] $__name (pending)" ;;
      missing) _say "  [....] $__name (missing — not yet registered, will keep waiting)" ;;
      query) _say "  [FAIL] $__name (query failed)" ;;
      cancelled-retried) _say "  [WAIT] $__name (cancelled by the runner; one re-run requested)" ;;
      cancelled-blocked) _say "  [FAIL] $__name (cancelled by the runner; the one re-run is spent or unavailable)" ;;
      fail) _say "  [FAIL] $__name" ;;
    esac
  done <"${TMPDIR:-/tmp}/release-gate-results.$$"
  rm -f "${TMPDIR:-/tmp}/release-gate-results.$$"

  if [ "$__failed" -gt 0 ]; then
    _say "verdict: NOT PASSED — $__failed required check(s) failed (first: $__first_bad)"
    exit 1
  fi
  if [ "$__pending" -eq 0 ] && [ "$__missing" -eq 0 ]; then
    _say "verdict: PASSED — all $__passed required checks succeeded"
    exit 0
  fi
  if [ "$__retried" -gt 0 ]; then
    _say "verdict: $__pending pending ($__retried cancelled check(s) re-run once), $__missing not yet registered, $__passed passed so far"
  else
    _say "verdict: $__pending pending, $__missing not yet registered, $__passed passed so far"
  fi
  if [ "$ONCE" = "1" ]; then
    _say "stopping after one round (--once)"
    exit 3
  fi
  if [ "$__waited" -ge "$TIMEOUT" ]; then
    if [ "$__missing" -gt 0 ]; then
      _say "verdict: NOT PASSED — $__missing required check(s) never registered within the ${TIMEOUT}s window (first: $__first_missing)"
      _say "         ci.yml may not have run on this SHA, or the job name does not match the required list"
      exit 1
    fi
    _say "timed out after ${TIMEOUT}s with checks still pending — refusing to publish"
    exit 3
  fi
  sleep "$INTERVAL"
  __waited=$((__waited + INTERVAL))
done
