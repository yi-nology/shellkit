#!/usr/bin/env bash
# 发布顺序：draft -> 独立验签 -> 公开（评估 2026-11-16）。
#
# 以前的顺序是「先公开发布、再下载验签」：验签失败时资产已经挂在网页上，
# 用户能下到一个没通过校验的版本。这条用例把顺序钉成结构判据 —— 改坏了必须红。
#
# 全文用纯 bash 扫描 YAML，不写 `grep | head` / `... | grep -q`：那两个命令命中即退出，
# 上游被 SIGPIPE 打死（141），调用方开了 pipefail 时整条管道判失败
# （见 tools/check_pipe_safety.sh）。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

CI="$TEST_ROOT/.github/workflows/release.yml"

# 覆盖率跑在副本里，副本按白名单拷目录；万一 .github 不在，要显式说「没验」，
# 而不是拿空文件对账（空文件会让判据看起来通过）。
if [ ! -f "$CI" ]; then
  printf 'NA: .github/workflows/release.yml is not in this tree — the publish order check is skipped\n'
  exit 0
fi

# _first_line FILE PATTERN —— 第一次出现 PATTERN 的行号（空 = 没找到）
_first_line() {
  local __f=$1 __pat=$2 __n=0 __line
  while IFS= read -r __line || [ -n "$__line" ]; do
    __n=$((__n + 1))
    case $__line in
      *"$__pat"*)
        printf '%s\n' "$__n"
        return 0
        ;;
    esac
  done <"$__f"
  return 0
}

# _order_violations FILE —— 有违规就打印出来（空输出 = 通过）
# 一遍读完整个文件，同时取到三处关键行号、create 块里有没有 --draft、draft=false 出现几次。
_order_violations() {
  local __f=$1 __n=0 __line='' __create='' __verify='' __publish='' __count=0 __has_draft=0
  while IFS= read -r __line || [ -n "$__line" ]; do
    __n=$((__n + 1))
    case $__line in
      *'gh release create'*) [ -n "$__create" ] || __create=$__n ;;
      *'name: verify the draft assets'*) [ -n "$__verify" ] || __verify=$__n ;;
      *'draft=false'*)
        [ -n "$__publish" ] || __publish=$__n
        __count=$((__count + 1))
        ;;
    esac
    # create 命令本身加上紧跟的 8 行，就是它的参数块
    if [ -n "$__create" ] && [ "$__n" -ge "$__create" ] && [ "$__n" -le $((__create + 8)) ]; then
      case $__line in
        *--draft*) __has_draft=1 ;;
      esac
    fi
  done <"$__f"
  if [ -z "$__create" ]; then
    printf 'no gh release create in %s\n' "$__f"
    return 0
  fi
  if [ "$__has_draft" -ne 1 ]; then
    printf 'gh release create does not use --draft\n'
  fi
  if [ -z "$__verify" ] || [ -z "$__publish" ]; then
    printf 'missing either the draft verification step or the publish step\n'
    return 0
  fi
  if [ "$__verify" -ge "$__publish" ]; then
    printf 'the draft is published before it is verified (verify=%s publish=%s)\n' "$__verify" "$__publish"
  fi
  if [ "$__count" -ne 1 ]; then
    printf 'the draft must be turned public exactly once\n'
  fi
  return 0
}

out=$(_order_violations "$CI")
assert_eq "" "$out" "the release must go draft -> verify -> publish (violations: $out)"

# 顺序要看得见：create 在 verify 之前，verify 在 publish 之前
create_line=$(_first_line "$CI" 'gh release create')
verify_line=$(_first_line "$CI" 'name: verify the draft assets')
publish_line=$(_first_line "$CI" 'draft=false')
assert_true test "$create_line" -lt "$verify_line"
assert_true test "$verify_line" -lt "$publish_line"

# 自证：把 --draft 去掉、再把两个步骤对调，判据都必须报出来
d=$(tmpdir)
cp "$CI" "$d/a.yml"
sed -i.bak 's/^              --draft$//' "$d/a.yml"
rm -f "$d/a.yml.bak"
assert_contains "$(_order_violations "$d/a.yml")" "does not use --draft" \
  "dropping --draft must break the check"

cp "$CI" "$d/b.yml"
python3 - "$CI" "$d/b.yml" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
i = text.index("      - name: verify the draft assets")
j = text.index("      - name: publish the draft")
verify = text[i:j]
publish = text[j:].split("\n  # deb / rpm")[0]
rest = text[j + len(publish):]
open(dst, "w", encoding="utf-8").write(text[:i] + publish + verify + rest)
PY
assert_contains "$(_order_violations "$d/b.yml")" "published before it is verified" \
  "swapping the two steps must break the check"

exit 0
