#!/usr/bin/env bash
#
# 从源码注释生成 API 参考。零依赖：只用 awk。
#   bash tools/shdoc.sh            # 输出 markdown 到 stdout
#
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 按 bootstrap 的加载顺序输出，读者按「先有什么、后有什么」看
MODULES="error i18n log str validate fs os trap run retry lock net config prompt cli"

printf '# API 参考\n\n'
printf '> 由 tools/shdoc.sh 从源码注释生成，请勿手工编辑。改完注释跑 shellkit docs。\n>\n'
printf '> 函数上方注释块的第一行即摘要；@brief / @param / @exitcode / @example / @see 可选，@internal 表示不导出。\n\n'

for m in $MODULES; do
  f="$ROOT/lib/core/$m.sh"
  if [ -f "$f" ]; then
    awk -v mod="$m" -f "$ROOT/tools/shdoc.awk" "$f"
  fi
done
