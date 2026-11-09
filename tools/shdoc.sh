#!/usr/bin/env bash
#
# 从源码注释生成 API 参考。零依赖：只用 awk。
#   bash tools/shdoc.sh            # 输出 markdown 到 stdout
#
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 顺序来自 lib/modules.txt，与 lib/bootstrap.sh 同源 —— 不会再出现
# 「bootstrap 加载了但文档没写」这种漂移。
# 清单是两列的：第一列模块名，第二列它依赖的模块。模块名取第一列。
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    '' | '#'*) continue ;;
  esac
  m="${line%%[[:space:]]*}"
  case "$m" in
    '' | '#'*) continue ;;
  esac
  f="$ROOT/lib/core/$m.sh"
  if [ -f "$f" ]; then
    awk -v mod="$m" -f "$ROOT/tools/shdoc.awk" "$f"
  fi
done <"$ROOT/lib/modules.txt"
