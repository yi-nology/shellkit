#!/usr/bin/env bash
#
# 从源码注释生成 API 参考。零依赖：只用 awk。
#   bash tools/shdoc.sh            # 输出 markdown 到 stdout（完整参考）
#   bash tools/shdoc.sh --index    # 输出能力索引（每个公开函数一行）
#
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --index：紧凑索引模式。
#
# 为什么要有它：完整参考是 182 个函数的全文（两千多行）⇒ 「这个能力库里
# 有没有 X」只能靠猜或全文搜 ⇒ 边缘但真实的能力（str_suggest / validate_* /
# parallel_map …）就这么被漏掉，然后被下游工程**重写一遍**（issue #161 的
# 实证：str_suggest 早就在库里，vendor 副本里也有，工程还是自己写了一遍）。
# 索引是**能一眼扫完**的那一份：落点表覆盖常用路径，索引覆盖全部。
capmode=0
if [ "${1:-}" = "--index" ]; then
  capmode=1
  shift
fi

if [ "$capmode" = "1" ]; then
  printf '# 能力索引：库里有什么\n\n'
  printf '> 生成物：由 `tools/shdoc.sh --index` 从源码注释生成（改完注释跑 `make docs`）。\n'
  printf '> 每一行 = 一个公开函数 + 一句话。\n'
  printf '> **这是「还有哪些能力」的答案** —— 落点表（SKILL.md）覆盖常用路径，\n'
  printf '> 这里覆盖的是**全部**；要看签名与退出码再去 references/reference.md。\n\n'
fi

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
    awk -v mod="$m" -v capmode="$capmode" -f "$ROOT/tools/shdoc.awk" "$f"
  fi
done <"$ROOT/lib/modules.txt"
