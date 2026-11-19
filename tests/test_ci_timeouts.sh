#!/usr/bin/env bash
#
# 结构判据：CI 的「内层包安装超时」必须同时满足两条 ——
#   1. 不短于实测最慢的一次装包（否则合法慢镜像被误杀）；
#   2. 不把 job 的总预算吃光（否则失败会以「job 超时」的面目出现，
#      而不是一句清楚的原因）。
#
# 为什么要有这条（2026-11-18 v1.1.0 发布现场）：openeuler 的 compat job 被
# 40 分钟的 job 总超时砍掉 —— 砍掉的是「装包慢」不是「卡死」。修法是两条一起：
# 装包加内层超时（早失败、说清原因）+ job 总超时放宽到 75 分钟。
# 但内层超时那个数是**手抄**的：抄小了会把同一批 runner 上合法的一次慢安装
# （实测 1069 秒）判成失败 —— 修超时修出新问题，而且这次没人在现场盯着。
#
# 判据来源是 .github/workflows/ci.yml 里的三个数：compat job 的
# timeout-minutes、PKG_TIMEOUT，以及实测最慢装包（写在本文件里）。
#
# 全文纯 bash 扫描，不写 `grep | head`（pipe-safety 门禁会判 SIGPIPE 风险）。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

CI_YML="$TEST_ROOT/.github/workflows/ci.yml"

# 实测最慢的一次装包（2026-11-18，openeuler amd64 共享 runner）：**2340 秒（39 分钟）**。
# 这个数是「合法慢」的**下界** —— 装包慢到它仍然该过，只是慢。
#
# 2026-11-19 更正：原来这里写的是 1069 秒（17 分 49 秒），那是**另一次**实测，
# 不是最坏值 —— 而 ci.yml 的内层超时（当时 1800 秒）恰好短于这个真实最坏值，
# 于是合法慢装被判成失败。常数抄小了，判据就抓不到这种自相矛盾：
# 判据只能保证「超时 ≥ 常数」，常数本身偏小 ⇒ 一并错。
OBSERVED_SLOW_INSTALL=2340
# 装包之后还要跑测试套件（实测 6-10 分钟），留 15 分钟。
TEST_BUDGET=900
# job 总超时至少要给的分钟数：慢但没卡死的一轮不该被杀。
MIN_JOB_MINUTES=40

# _ci_timeout_violations FILE —— 打印不合规之处（空输出 = 合格）
_ci_timeout_violations() {
  local __f=$1 __raw __trim __rest __job='' __in_jobs=0
  local __job_timeout='' __pkg_timeout=''

  while IFS= read -r __raw || [ -n "$__raw" ]; do
    __trim=$__raw
    while [ "${__trim# }" != "$__trim" ]; do __trim=${__trim# }; done
    case $__trim in
      '' | '#'*) continue ;;
    esac
    if [ "$__raw" = 'jobs:' ]; then
      __in_jobs=1
      continue
    fi
    [ "$__in_jobs" = 1 ] || continue
    # job 头：两空格缩进 + 名字 + 冒号（更深缩进的键不是 job 头）
    case $__raw in
      '  '*)
        __rest=${__raw#  }
        case $__rest in
          ' '* | '') ;;
          *:)
            __job=${__rest%%:*}
            # 只在进入 compat 时清空 —— 后面还有别的 job，它们的头不能把
            # compat 已经采到的值抹掉（踩过一次：artifact 一出现就归零）。
            if [ "$__job" = 'compat' ]; then
              __job_timeout=''
              __pkg_timeout=''
            fi
            continue
            ;;
        esac
        ;;
    esac
    [ "$__job" = 'compat' ] || continue
    case $__trim in
      timeout-minutes:*)
        __job_timeout=${__trim#timeout-minutes:}
        while [ "${__job_timeout# }" != "$__job_timeout" ]; do __job_timeout=${__job_timeout# }; done
        while [ "${__job_timeout% }" != "$__job_timeout" ]; do __job_timeout=${__job_timeout% }; done
        ;;
      PKG_TIMEOUT=*)
        __pkg_timeout=${__trim#PKG_TIMEOUT=}
        ;;
    esac
  done <"$__f"

  if [ -z "$__pkg_timeout" ]; then
    printf '%s: the compat job has no inner package-install timeout (PKG_TIMEOUT)\n' "$__f"
    return 0
  fi
  if [ -z "$__job_timeout" ]; then
    printf '%s: the compat job has no timeout-minutes\n' "$__f"
    return 0
  fi
  case "$__job_timeout$__pkg_timeout" in
    *[!0-9]*)
      printf '%s: non-numeric timeout values (timeout-minutes=%s PKG_TIMEOUT=%s)\n' \
        "$__f" "$__job_timeout" "$__pkg_timeout"
      return 0
      ;;
  esac

  if [ "$__pkg_timeout" -lt "$OBSERVED_SLOW_INSTALL" ]; then
    printf '%s: PKG_TIMEOUT=%s is shorter than the slowest observed install (%ss) — a legitimate slow mirror gets killed\n' \
      "$__f" "$__pkg_timeout" "$OBSERVED_SLOW_INSTALL"
  fi
  if [ "$__job_timeout" -lt "$MIN_JOB_MINUTES" ]; then
    printf '%s: timeout-minutes=%s is below the %s minutes a slow-but-alive compat job needs\n' \
      "$__f" "$__job_timeout" "$MIN_JOB_MINUTES"
  fi
  if [ $((__pkg_timeout + TEST_BUDGET)) -gt $((__job_timeout * 60)) ]; then
    printf '%s: PKG_TIMEOUT=%s plus the %ss test budget exceeds the job timeout (%s minutes) — the inner timeout eats the job budget\n' \
      "$__f" "$__pkg_timeout" "$TEST_BUDGET" "$__job_timeout"
  fi
  return 0
}

if [ ! -f "$CI_YML" ]; then
  printf 'NA: .github/workflows/ci.yml is not in this tree — the CI timeout check is skipped\n'
  exit 0
fi

out=$(_ci_timeout_violations "$CI_YML")
assert_eq "" "$out" "the compat job's inner timeout must tolerate a slow install and must not eat the job budget"

# 自证：把内层超时抄小 ⇒ 判据必须报出来
d=$(tmpdir)
sed 's/PKG_TIMEOUT=[0-9][0-9]*/PKG_TIMEOUT=60/' "$CI_YML" >"$d/ci-small.yml"
assert_contains "$(_ci_timeout_violations "$d/ci-small.yml")" "PKG_TIMEOUT=60" \
  "shrinking the inner package-install timeout must break the check"

# 自证：把 job 总超时抄到吃光预算 ⇒ 判据必须报出来
sed 's/timeout-minutes: [0-9][0-9]*/timeout-minutes: 20/' "$CI_YML" >"$d/ci-budget.yml"
assert_contains "$(_ci_timeout_violations "$d/ci-budget.yml")" "eats the job budget" \
  "a job timeout that the inner timeout eats must break the check"
# --------------------------------------------------------------------------
# 判据二：CI 里每个下载都必须有超时
#
# 为什么（2026-11-19 实测）：
# 内层包安装超时（PKG_TIMEOUT）只包住 `dnf install`；装完包之后的
# `sk_fetch`（拉 shellcheck / shfmt）用的是裸 `curl -fsSL`，**没有 --max-time**。
# GitHub release 下载一旦卡住，这个 job 就无限期挂着 —— 外层 30 分钟超时
# 管不到它，只能等 job 级 75 分钟超时兜底，失败现场是「job 被取消」，
# 离病根（一个卡住的下载）很远。
#
# 同一个坑的另一半：#147 修了「装包慢」，没修「下载慢」。
#
# 判据形状：ci.yml 里每一处 `curl -fsSL` / `wget` 下载都必须带超时参数。
# --------------------------------------------------------------------------

_download_without_timeout() {
  local __f=$1 __line __n=0
  while IFS= read -r __line || [ -n "$__line" ]; do
    __n=$((__n + 1))
    case "$__line" in
      *'curl -fsSL'* | *'curl -sSL'*)
        # 已经有 --max-time / --connect-timeout 的算合规
        case "$__line" in
          *'--max-time'* | *'--connect-timeout'*) continue ;;
        esac
        printf '%s:%s: a download without a timeout will hang the job until the job-level timeout: %s\n' \
          "${__f##*/}" "$__n" "$__line"
        ;;
    esac
  done <"$__f"
  return 0
}

dl=$(_download_without_timeout "$CI_YML")
assert_eq "" "$dl" "every download in the CI workflow must carry a timeout"

# 自证：去掉一个下载的超时 ⇒ 判据必须报出来
sed 's|curl -fsSL --max-time|curl -fsSL|' "$CI_YML" >"$d/ci-dl.yml"
assert_contains "$(_download_without_timeout "$d/ci-dl.yml")" "a download without a timeout" \
  "removing the download timeout must break the check"

# --------------------------------------------------------------------------
# 判据三：CI 里每个下载都必须有**重试**
#
# 为什么（2026-11-19 实测踩到）：GitHub release 的 CDN 偶尔返回 504
# （网关超时）—— 实测 ubuntu-latest 的 job 就死在
# `curl: (22) The requested URL returned error: 504` 上。
# 超时能防「卡住」，防不住「服务端明确报错」：一次 504 就让整个 job 挂掉，
# 而那不是代码的问题 —— 重试一次就好了。
#
# 判据形状：每一处下载都必须落在**一个带重试循环的函数**里
# （函数体里有 while 循环 + 「attempt」标记）；落在函数外的下载连重试的
# 机会都没有，直接判不合格。
# --------------------------------------------------------------------------
_download_without_retry() {
  local __f=$1
  awk '
    function check_block(s, e,   i, l, has_while, has_attempt) {
      has_while = 0
      has_attempt = 0
      for (i = s; i <= e; i++) {
        l = lines[i]
        if (l ~ /while/) has_while = 1
        if (l ~ /attempt/) has_attempt = 1
      }
      for (i = s; i <= e; i++) {
        l = lines[i]
        if (l ~ /curl -fsSL|curl -sSL|wget .*-O|urlretrieve/) {
          if (!has_while || !has_attempt) {
            printf "%s:%d: a download without a retry loop dies on a single 5xx: %s\n", FILENAME, i, l
          }
        }
      }
    }
    {
      lines[NR] = $0
      t = $0
      sub(/^[ \t]+/, "", t)
      if (t ~ /^#/) next
      if ($0 ~ /^[ \t]*[a-zA-Z_][a-zA-Z0-9_]*\(\)[ \t]*\{/) { fstart = NR; infn = 1; next }
      if (infn && $0 ~ /^[ \t]*\}[ \t]*$/) { check_block(fstart, NR); infn = 0; next }
      if (!infn && $0 ~ /curl -fsSL|curl -sSL|wget .*-O|urlretrieve/) {
        printf "%s:%d: a download outside any function cannot be retried: %s\n", FILENAME, NR, $0
      }
    }
    END {
      if (infn) check_block(fstart, NR)
    }
  ' "$__f"
}

retry_gaps=$(_download_without_retry "$CI_YML")
assert_eq "" "$retry_gaps" "every download in the CI workflow must sit behind a retry loop"

# 自证：把重试标记去掉 ⇒ 判据必须报出来
sed 's/attempt/try/g' "$CI_YML" >"$d/ci-noretry.yml"
assert_contains "$(_download_without_retry "$d/ci-noretry.yml")" "without a retry loop" \
  "removing the retry loop must break the check"

exit 0
