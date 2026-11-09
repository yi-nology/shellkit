#!/usr/bin/env bash
#
# 模块顺序与依赖门禁。六件事：
#   1. lib/core/ 下的每个模块都必须在 lib/modules.txt 里列上（否则等于没加载）
#   2. modules.txt 里列的模块必须有文件，也必须有对应的 tests/test_<name>.sh
#   3. 同一个函数不能被两个模块定义（谁在前面都可能出错）
#   4. 顺序必须对：某个模块调用了另一个模块的函数，那个模块必须先加载
#   5. 清单第二列声明的依赖必须排在它前面（依赖必须先加载）
#   6. 清单第二列声明必须完整：某模块用了另一模块的函数，另一模块就得在它的
#      依赖闭包里（直接声明或间接声明都算）
#
# 为什么需要第 4 条：模块顺序以前只靠人记。写错了不会在加载时报错，
# 而是在运行时炸在「command not found」上 —— 往往还是别人的脚本在别人的机器上炸。
#
# 为什么需要第 5、6 条：清单第二列是「直接依赖」的声明。只加载用得上的模块
# （SHELLKIT_MODULES）靠它算闭包；依赖没声明或写反了，加载时会缺函数。
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIST="$ROOT/lib/modules.txt"
COREDIR="$ROOT/lib/core"

if [ ! -f "$LIST" ]; then
  printf 'check_module_order: missing module list: %s\n' "$LIST" >&2
  exit 1
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/shellkit-modorder.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

bad=0

# ---- 读顺序与依赖（清单两列：模块名 + 直接依赖，空白分隔）----
: >"$TMP/order"
: >"$TMP/deps"
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%%#*}"
  case "$line" in
    '' | '#'*) continue ;;
  esac
  mod="${line%%[[:space:]]*}"
  [ -n "$mod" ] || continue
  rest="${line#"$mod"}"
  deps=""
  for w in $rest; do
    deps="$deps $w"
  done
  printf '%s\n' "$mod" >>"$TMP/order"
  printf '%s %s\n' "$mod" "${deps# }" >>"$TMP/deps"
done <"$LIST"

# ---- 模块 -> 函数表 ----
: >"$TMP/owners"
while IFS= read -r mod; do
  [ -n "$mod" ] || continue
  if [ ! -f "$COREDIR/$mod.sh" ]; then
    printf 'check_module_order: listed module has no file: lib/core/%s.sh\n' "$mod" >&2
    bad=1
    continue
  fi
  grep -E '^[A-Za-z_][A-Za-z0-9_]*\(\)' "$COREDIR/$mod.sh" | sed 's/().*//' |
    while IFS= read -r fn; do
      printf '%s %s\n' "$fn" "$mod"
    done >>"$TMP/owners"
done <"$TMP/order"

# ---- lib/core 里的文件都得在清单里 ----
for f in "$COREDIR"/*.sh; do
  [ -f "$f" ] || continue
  base=$(basename "$f" .sh)
  if ! grep -qxF "$base" "$TMP/order"; then
    printf 'check_module_order: module is not listed in lib/modules.txt: %s\n' "$base" >&2
    bad=1
  fi
done

# ---- 每个模块都要有测试 ----
while IFS= read -r mod; do
  [ -n "$mod" ] || continue
  if [ ! -f "$ROOT/tests/test_$mod.sh" ]; then
    printf 'check_module_order: module has no test file: tests/test_%s.sh\n' "$mod" >&2
    bad=1
  fi
done <"$TMP/order"

# ---- 同一个函数不能被两个模块定义 ----
cut -d' ' -f1 "$TMP/owners" | sort | uniq -d >"$TMP/dups"
while IFS= read -r dup; do
  [ -n "$dup" ] || continue
  printf 'check_module_order: function defined in more than one module: %s\n' "$dup" >&2
  bad=1
done <"$TMP/dups"

# ---- 顺序对不对 ----
awk -v list="$TMP/order" -v owners="$TMP/owners" -v depsfile="$TMP/deps" -f "$ROOT/tools/module_order.awk" \
  "$COREDIR"/*.sh >"$TMP/probs" 2>&1 || true
if [ -s "$TMP/probs" ]; then
  while IFS= read -r p; do
    printf '%s\n' "$p" >&2
  done <"$TMP/probs"
  bad=1
fi

if [ "$bad" -ne 0 ]; then
  printf 'check_module_order: found problems\n' >&2
  exit 1
fi
printf 'check_module_order: ok\n'
