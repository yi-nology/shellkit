#!/usr/bin/env bash
# 结构判据：凡是会调用 tools/sign_release.sh 的 CI job，必须**自己**先装 minisign。
#
# 为什么要有这条（评估 2026-11-16 / v0.26.0 首发事故）：Ubuntu runner 默认没有
# minisign，而 sign_release.sh 在「配了私钥但工具缺失」时按设计红（退出码 3）。
# release job 里这条坑在 v0.21.0 就踩过并写进了注释，但 packages job 是后加的、
# 没照做 —— 更糟的是那个 job 带 continue-on-error：红被吞掉，那一版静默地
# 少了 deb/rpm 两个资产（网页上看不出来，只是「这一版没有系统包」）。
# 注释管不住新增的 job，所以用一条结构判据盯住所有 workflow 文件。
#
# 全文纯 bash 扫描，不写 `grep | head`（pipe-safety 门禁会判 SIGPIPE 风险）。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

WF_DIR="$TEST_ROOT/.github/workflows"

# 覆盖率跑在副本里，副本按白名单拷目录；没有 .github 时显式说「没验」，
# 而不是拿空目录对账（空目录会让判据看起来通过）。
if [ ! -d "$WF_DIR" ]; then
  printf 'NA: .github/workflows is not in this tree — the signing toolchain check is skipped\n'
  exit 0
fi

# _violations FILE —— 打印「签名了但没装工具」的 job（空输出 = 通过）
_violations() {
  local __f=$1 __n=0 __line='' __job='' __in_jobs=0
  local __signed='' __tool=0 __trim=''
  while IFS= read -r __line || [ -n "$__line" ]; do
    __n=$((__n + 1))
    case $__line in
      'jobs:')
        __in_jobs=1
        continue
        ;;
      '')
        continue
        ;;
    esac
    # 顶格的键（除了 jobs 之后）说明已经离开 jobs 段
    case $__line in
      [A-Za-z_]*:)
        if [ "$__in_jobs" = 1 ]; then
          __in_jobs=0
          _flush
        fi
        continue
        ;;
    esac
    [ "$__in_jobs" = 1 ] || continue
    # 注释行不算：文档里写的 `sign_release.sh` / `minisign` 不是真调用
    __trim=$__line
    while [ "${__trim# }" != "$__trim" ]; do __trim=${__trim# }; done
    case $__trim in
      '#'*) continue ;;
    esac
    # 2 空格缩进的键 = job id
    case $__line in
      '  '*)
        case ${__line#  } in
          ' '* | '') ;; # 三格以上（或空）不是 job 头
          [A-Za-z0-9_-]*:)
            _flush
            __job=${__line#  }
            __job=${__job%%:*}
            __signed=''
            __tool=0
            continue
            ;;
        esac
        ;;
    esac
    case $__line in
      *sign_release.sh*)
        [ -n "$__signed" ] || __signed=$__n
        ;;
      *minisign*)
        [ -n "$__signed" ] || __tool=1
        ;;
    esac
  done <"$__f"
  _flush
  return 0
}

# 当前 job 收尾：签名了却没装工具就报出来
_flush() {
  if [ -n "$__signed" ] && [ "$__tool" -ne 1 ]; then
    printf '%s: job "%s" calls sign_release.sh (line %s) without installing minisign first\n' \
      "${__f:-?}" "${__job:-?}" "$__signed"
  fi
  return 0
}

_bad=''
_count=0
for wf in "$WF_DIR"/*.yml "$WF_DIR"/*.yaml; do
  [ -f "$wf" ] || continue
  _count=$((_count + 1))
  out=$(_violations "$wf")
  [ -z "$out" ] || _bad="${_bad}${out}\n"
done

assert_true test "$_count" -gt 0
assert_eq "" "$_bad" "every job that signs the release must install minisign first (violations: $_bad)"

# 自证：把 install minisign 那一步从副本里删掉，判据必须报出来
d=$(tmpdir)
cp "$TEST_ROOT/.github/workflows/release.yml" "$d/w.yml"
python3 - "$d/w.yml" <<'PY'
import re
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
# 删掉 packages job 里那个 install minisign 步骤（它是最后一个 install minisign 块）
blocks = text.split("      - name: install minisign\n")
assert len(blocks) >= 2, "expected at least two install minisign steps"
tail = blocks[-1]
# 步骤体到下一个 "      - name:" 为止
cut = tail.index("\n      - name:")
open(path, "w", encoding="utf-8").write(
    "      - name: install minisign\n".join(blocks[:-1]) + tail[cut + 1:]
)
PY
assert_contains "$(_violations "$d/w.yml")" 'job "packages"' \
  "dropping the tool install from the packages job must break the check"

exit 0
