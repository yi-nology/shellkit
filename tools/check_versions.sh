#!/usr/bin/env bash
#
# 版本号一致性。VERSION 是唯一真相源，其余位置都是它的投影：
#   - locale/shellkit.pot 的 Project-Id-Version 头（翻译工具读它）
#   - README.md 的一键安装钉版本示例
#   - site/index.md 与 site/en/index.md 的下载按钮与钉版本示例
#
# 为什么需要这条：这些位置都是手抄的，发版时漏一处不会报错 —— 网页上挂着上一版的
# 下载按钮、README 教人装旧版，而所有测试和门禁都是绿的。
#
#   bash tools/check_versions.sh    # 0 一致；5 不一致；2 用法错
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_fail=0

_ver="$(tr -d '[:space:]' <"$ROOT/VERSION" 2>/dev/null || true)"
if ! printf '%s\n' "$_ver" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  printf 'versions-check: VERSION is not x.y.z: <%s>\n' "$_ver" >&2
  exit 5
fi

# _check FILE LABEL FOUND... —— 逐项与 VERSION 比对；一个都没找到也算错，
# 因为「模式写错了」和「全都一致」在只看输出的实现里长得一模一样。
_check() {
  local __file=$1 __label=$2 __v
  shift 2
  if [ "$#" -eq 0 ]; then
    printf 'versions-check: %s: no reference for %s\n' "$__file" "$__label" >&2
    _fail=1
    return 0
  fi
  for __v in "$@"; do
    if [ "$__v" != "$_ver" ]; then
      printf 'versions-check: %s: %s says %s, VERSION says %s\n' \
        "$__file" "$__label" "$__v" "$_ver" >&2
      _fail=1
    fi
  done
}

# shellcheck disable=SC2046
_check "README.md" "VERSION=" \
  $(grep -Eo 'VERSION=[0-9]+\.[0-9]+\.[0-9]+' "$ROOT/README.md" | sed 's/^VERSION=//')

# shellcheck disable=SC2046
_check "site/index.md" "VERSION=" \
  $(grep -Eo 'VERSION=[0-9]+\.[0-9]+\.[0-9]+' "$ROOT/site/index.md" | sed 's/^VERSION=//')

# shellcheck disable=SC2046
_check "site/index.md" "download button" \
  $(grep -Eo '下载 [0-9]+\.[0-9]+\.[0-9]+' "$ROOT/site/index.md" | sed 's/^下载 //')

# shellcheck disable=SC2046
_check "site/en/index.md" "VERSION=" \
  $(grep -Eo 'VERSION=[0-9]+\.[0-9]+\.[0-9]+' "$ROOT/site/en/index.md" | sed 's/^VERSION=//')

# shellcheck disable=SC2046
_check "site/en/index.md" "download button" \
  $(grep -Eo 'Download [0-9]+\.[0-9]+\.[0-9]+' "$ROOT/site/en/index.md" | sed 's/^Download //')

# 安装页里也有钉版本的示例：漏改就会教人装上一版
# shellcheck disable=SC2046
_check "site/guide/installation.md" "VERSION=" \
  $(grep -Eo 'VERSION=[0-9]+\.[0-9]+\.[0-9]+' "$ROOT/site/guide/installation.md" | sed 's/^VERSION=//')

# shellcheck disable=SC2046
_check "site/guide/installation.md" "tarball name" \
  $(grep -Eo 'shellkit-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz' "$ROOT/site/guide/installation.md" | sed 's/^shellkit-//; s/\.tar\.gz$//')

# shellcheck disable=SC2046
_check "site/en/guide/installation.md" "VERSION=" \
  $(grep -Eo 'VERSION=[0-9]+\.[0-9]+\.[0-9]+' "$ROOT/site/en/guide/installation.md" | sed 's/^VERSION=//')

# shellcheck disable=SC2046
_check "site/en/guide/installation.md" "tarball name" \
  $(grep -Eo 'shellkit-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz' "$ROOT/site/en/guide/installation.md" | sed 's/^shellkit-//; s/\.tar\.gz$//')

# shellcheck disable=SC2046
_check "locale/shellkit.pot" "Project-Id-Version" \
  $(grep -Eo 'Project-Id-Version: shellkit [0-9]+\.[0-9]+\.[0-9]+' "$ROOT/locale/shellkit.pot" |
    sed 's/.*shellkit //')

if [ "$_fail" -ne 0 ]; then
  printf 'versions-check: mismatched references; bash tools/release.sh <version> fixes them all\n' >&2
  exit 5
fi
printf 'versions-check: ok (%s)\n' "$_ver"
