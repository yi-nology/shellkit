#!/usr/bin/env bash
#
# 门禁：同一个文件里不允许出现重复的函数定义。
#
# 为什么需要这道门：bash 里**后定义覆盖先定义**。同一个文件里写了两遍
# `os_release_field`，跑起来的是后面那份，前面那份悄悄失效 ——
# 不报错、不崩，只是「你以为在跑 A，其实在跑 B」。
#
# 这道门是真实事故带出来的（2026-11-10）：一个已阵亡的子代理把自己的实现
# 插进了别人的 lib/core/os.sh，`git add -A` 把它一起提交了。运行期无害
# （被覆盖的是那份外来实现），但文档生成器取的是先定义那份，于是
# docs/REFERENCE.md 里的说明与实现对不上，`make check` 在 test_ai_docs.sh
# 上红。若没有这道门，这类污染会一路潜行到发布。
#
#   bash tools/check_dup_functions.sh   # 0 合格；5 有重复定义
set -u

# SHELLKIT_CHECK_ROOT 只给自测用：在一棵假的树副本上跑本门禁。
ROOT="${SHELLKIT_CHECK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)}"

bad=0

for __f in "$ROOT"/lib/core/*.sh "$ROOT"/lib/bootstrap.sh; do
  [ -f "$__f" ] || continue
  __dup=$(grep -o '^[A-Za-z_][A-Za-z0-9_]*()[[:space:]]*{' "$__f" 2>/dev/null |
    sed 's/[[:space:]]*{$//' | sort | uniq -d)
  [ -n "$__dup" ] || continue
  printf 'dup-functions: %s 里重复定义了：\n' "${__f#"$ROOT"/}" >&2
  while IFS= read -r __name; do
    [ -n "$__name" ] || continue
    printf '  %s\n' "$__name" >&2
  done <<EOF
$__dup
EOF
  bad=1
done

if [ "$bad" -ne 0 ]; then
  printf 'dup-functions: 同一个文件里不能有重复的函数定义（bash 后定义覆盖先定义）\n' >&2
  exit 5
fi

printf 'dup-functions: ok\n'
