#!/usr/bin/env bash
#
# 门禁：文档里写的「N 个模块」必须与 lib/modules.txt 里的实际模块数一致。
#
# 为什么需要这道门：模块数在 README、首页、模块地图、FAQ、迁移指南里各手抄了一份。
# 加一个模块要改六个地方，漏一处的后果不是报错，而是网页上写着「17 个模块」、
# 实际已经是 18 个 —— 读者按这句话去找模块会少一个。
# 这跟「Cookbook 场景数」是同一类腐化：承诺与事实错位，所以同样用门禁钉住。
#
# 真相源：lib/modules.txt 第一列的非空、非注释行数。
#
#   bash tools/check_module_count.sh   # 0 通过；5 对不上
set -u

# SHELLKIT_CHECK_ROOT 只给自测用：在一棵假的树副本上跑本门禁。
ROOT="${SHELLKIT_CHECK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)}"
MANIFEST="$ROOT/lib/modules.txt"

if [ ! -f "$MANIFEST" ]; then
  printf 'check_module_count: %s not found\n' "$MANIFEST" >&2
  exit 1
fi

n=0
while IFS= read -r __line || [ -n "$__line" ]; do
  __line="${__line%%#*}"
  case "$__line" in
    '' | ' '*) continue ;;
  esac
  __name="${__line%%[[:space:]]*}"
  [ -n "$__name" ] || continue
  n=$((n + 1))
done <"$MANIFEST"

if [ "$n" -eq 0 ]; then
  printf 'check_module_count: cannot count modules in %s\n' "$MANIFEST" >&2
  exit 1
fi

bad=0

# 期望写法：中文页写「N 个模块」，英文页写「N modules」。
# 文件里压根没提数量就不管（不是每个页面都非得报数）。
check() {
  local __file=$1
  [ -f "$__file" ] || return 0
  grep -qE '个模块|modules' "$__file" || return 0
  if ! grep -qF "$n 个模块" "$__file"; then
    printf '%s: 模块数应为 %s 个（中文页写「%s 个模块」）\n' "${__file#"$ROOT"/}" "$n" "$n" >&2
    bad=1
  fi
  # 中文页不额外查「中文数词」形式：像「一行一个模块名」「静默加载零个模块」这类自然措辞
  # 满篇都是，按形态判会误伤一大片。真漂移（中文站写成「十七个模块」而漏掉「18 个模块」）
  # 上面那条「必须含 N 个模块」已经抓住了。
}

for __f in \
  "$ROOT/README.md" \
  "$ROOT/docs/MIGRATING.md" \
  "$ROOT/site/index.md" \
  "$ROOT/site/guide/index.md" \
  "$ROOT/site/guide/modules.md" \
  "$ROOT/site/guide/faq.md"; do
  check "$__f"
done

# 英文页：写了模块数就必须也是同一个数。
#
# 「模块数」既可能是数字（18 modules）也可能是英文数词（eighteen modules）。
# 只认数字的话，写成英文数词就能绕过这道门 —— 英文站曾漂移成 seventeen 而门禁全绿。
# 范围表述（one or two modules）说的是「用几个模块」，不是模块数，跳过。
#
# 数词表覆盖 one..twenty：模块数不可能超过这个量级；超出范围按原样数字处理并判红。
for __f in "$ROOT"/site/en/*.md "$ROOT"/site/en/guide/*.md; do
  [ -f "$__f" ] || continue
  __hits="$(awk '{
    for (i = 1; i < NF; i++) {
      nx = $(i+1)
      # 所有格形式（one module 加所有格后缀）不是复数，跳过。
      # 撇号用 sprintf 拼：awk 程序整体在 shell 单引号里，源码与注释都不能出现撇号。
      if (index(nx, sprintf("%c", 39)) > 0) continue
      if (index(nx, sprintf("%c%c%c", 226, 128, 153)) > 0) continue
      nx = tolower(nx)
      gsub(/[^a-z0-9]/, "", nx)
      if (nx != "modules") continue
      w = tolower($i)
      gsub(/[^a-z0-9]/, "", w)
      if (w == "") continue
      if (i >= 2) {
        pv = tolower($(i-1))
        gsub(/[^a-z0-9]/, "", pv)
        if (pv == "or" || pv == "and") continue
      }
      print w
    }
  }' "$__f")"
  [ -n "$__hits" ] || continue
  while IFS= read -r __w; do
    [ -n "$__w" ] || continue
    case "$__w" in
      [0-9]*) __v="$__w" ;;
      one) __v=1 ;;
      two) __v=2 ;;
      three) __v=3 ;;
      four) __v=4 ;;
      five) __v=5 ;;
      six) __v=6 ;;
      seven) __v=7 ;;
      eight) __v=8 ;;
      nine) __v=9 ;;
      ten) __v=10 ;;
      eleven) __v=11 ;;
      twelve) __v=12 ;;
      thirteen) __v=13 ;;
      fourteen) __v=14 ;;
      fifteen) __v=15 ;;
      sixteen) __v=16 ;;
      seventeen) __v=17 ;;
      eighteen) __v=18 ;;
      nineteen) __v=19 ;;
      twenty) __v=20 ;;
      *)
        # 不是数量表述（the modules / listed modules / N modules 这类）⇒ 跳过。
        # 只有数字与已知数词才算「模块数」。
        continue
        ;;
    esac
    if [ "$__v" != "$n" ]; then
      printf '%s: 模块数应为 %s（英文页写「%s modules」）\n' "${__f#"$ROOT"/}" "$n" "$n" >&2
      bad=1
    fi
  done <<EOF
$__hits
EOF
done

if [ "$bad" -ne 0 ]; then
  printf 'check_module_count: 文档里的模块数与 lib/modules.txt 对不上\n' >&2
  exit 5
fi
printf 'check_module_count: ok (%s modules)\n' "$n"
exit 0
