#!/usr/bin/env bash
#
# 模块顺序与依赖门禁。四件事：
#   1. lib/core/ 下的每个模块都必须在 lib/modules.txt 里列上（否则等于没加载）
#   2. modules.txt 里列的模块必须有文件，也必须有对应的 tests/test_<name>.sh
#   3. 同一个函数不能被两个模块定义（谁在前面都可能出错）
#   4. 顺序必须对，依赖声明必须既完整又排在前面：
#      - 某模块调用了另一个模块的函数，那个模块必须先加载
#      - 清单第二列声明的每个依赖必须排在它前面
#      - 某模块用了另一模块的函数，另一模块就得在它的依赖闭包里
#
# 为什么需要第 4 条：模块顺序以前只靠人记。写错了不会在加载时报错，
# 而是在运行时炸在「command not found」上 —— 往往还是别人的脚本在别人的机器上炸。
#
# 为什么判断写在 shell 里而不是 awk 里：闭包与拓扑序的算法放在某些 gawk 版本上
# 会让 gawk 自己崩（fatal: internal error / segfault / double free），
# 而 BWK awk 与 mawk 都容忍 —— 本机全绿、CI 才炸。
# awk 只做它擅长且稳定的部分：从源码里认出函数调用。
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
MODS=()
DEPS=()
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
  MODS[${#MODS[@]}]="$mod"
  DEPS[${#DEPS[@]}]="${deps# }"
  printf '%s\n' "$mod" >>"$TMP/order"
done <"$LIST"

# 模块名 -> 序号（出参用 printf -v）。Bash 3.2 没有关联数组，
# 模块又只有十几个，线性查找足够。
mod_index() {
  local i=0 m
  for m in ${MODS[@]+"${MODS[@]}"}; do
    if [ "$m" = "$1" ]; then
      printf -v "$2" '%s' "$i"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# ---- 模块 -> 函数表 ----
: >"$TMP/owners"
for mod in ${MODS[@]+"${MODS[@]}"}; do
  if [ ! -f "$COREDIR/$mod.sh" ]; then
    printf 'check_module_order: listed module has no file: lib/core/%s.sh\n' "$mod" >&2
    bad=1
    continue
  fi
  grep -E '^[A-Za-z_][A-Za-z0-9_]*\(\)' "$COREDIR/$mod.sh" | sed 's/().*//' |
    while IFS= read -r fn; do
      printf '%s %s\n' "$fn" "$mod"
    done >>"$TMP/owners"
done

# ---- lib/core 里的文件都得在清单里 ----
for f in "$COREDIR"/*.sh; do
  [ -f "$f" ] || continue
  base=$(basename "$f" .sh)
  if ! mod_index "$base" _tmp_idx; then
    printf 'check_module_order: module is not listed in lib/modules.txt: %s\n' "$base" >&2
    bad=1
  fi
done

# ---- 每个模块都要有测试 ----
for mod in ${MODS[@]+"${MODS[@]}"}; do
  if [ ! -f "$ROOT/tests/test_$mod.sh" ]; then
    printf 'check_module_order: module has no test file: tests/test_%s.sh\n' "$mod" >&2
    bad=1
  fi
done

# ---- 同一个函数不能被两个模块定义 ----
cut -d' ' -f1 "$TMP/owners" | sort | uniq -d >"$TMP/dups"
while IFS= read -r dup; do
  [ -n "$dup" ] || continue
  printf 'check_module_order: function defined in more than one module: %s\n' "$dup" >&2
  bad=1
done <"$TMP/dups"

# ---- 调用关系（awk 只做提取：谁用了谁的哪个函数）----
awk -v list="$TMP/order" -v owners="$TMP/owners" -f "$ROOT/tools/module_order.awk" \
  "$COREDIR"/*.sh >"$TMP/uses" 2>&1 || true

# awk 自己出错（语法错、读不到输入文件……）时，门禁不能当没事发生 ——
# 「工具崩了」与「检查通过」必须分得开。这里只认两种输出行，其余一律当失败。
grep -vE '^(uses |check_module_order: )' "$TMP/uses" >"$TMP/awkerrs" 2>/dev/null || true
if [ -s "$TMP/awkerrs" ]; then
  printf 'check_module_order: the scanner failed\n' >&2
  sed 's/^/    /' "$TMP/awkerrs" >&2
  bad=1
fi

# 规则 1 的报错由 awk 打出（它知道每个模块在清单里的序号）
if grep '^check_module_order: ' "$TMP/uses" >"$TMP/ordererrs" 2>/dev/null; then
  cat "$TMP/ordererrs" >&2
  bad=1
fi

# ---- 规则 2：声明的依赖必须排在它前面 ----
for mod in ${MODS[@]+"${MODS[@]}"}; do
  if ! mod_index "$mod" mi; then
    continue
  fi
  for d in ${DEPS[$mi]}; do
    di=0
    if ! mod_index "$d" di; then
      printf 'check_module_order: module %s depends on %s, but %s is not listed in lib/modules.txt\n' "$mod" "$d" "$d" >&2
      bad=1
    elif [ "$di" -ge "$mi" ]; then
      printf 'check_module_order: module %s depends on %s, but %s is listed after %s (a dependency must be loaded first)\n' "$mod" "$d" "$d" "$mod" >&2
      bad=1
    fi
  done
done

# ---- 规则 3：用了谁的函数，谁就得在依赖闭包里 ----
# 闭包 = 直接依赖 + 依赖的依赖。用不动点迭代：顺序写错时闭包也算得对
# （顺序问题由规则 2 单独报）。
CLOSURE=()
mi=0
while [ "$mi" -lt "${#MODS[@]}" ]; do
  mod=${MODS[$mi]}
  seen=" $mod "
  work="$mod "
  changed=1
  while [ "$changed" = "1" ]; do
    changed=0
    for d in $work; do
      mod_index "$d" di || continue
      for x in ${DEPS[$di]}; do
        case "$seen" in
          *" $x "*) ;;
          *)
            seen="$seen$x "
            work="$work$x "
            changed=1
            ;;
        esac
      done
    done
  done
  CLOSURE[$mi]="$seen"
  mi=$((mi + 1))
done

grep '^uses ' "$TMP/uses" >"$TMP/pairs" 2>/dev/null || true
while IFS= read -r pair; do
  [ -n "$pair" ] || continue
  # 格式：uses <调用方> <被调用方> <函数名>
  user=$(printf '%s\n' "$pair" | cut -d' ' -f2)
  owner_mod=$(printf '%s\n' "$pair" | cut -d' ' -f3)
  fn=$(printf '%s\n' "$pair" | cut -d' ' -f4)
  ui=0
  mod_index "$user" ui || continue
  # i18n 例外：它恒定加载（_t 是公共依赖），不强制每个模块都声明
  if [ "$owner_mod" = "i18n" ]; then
    continue
  fi
  case " ${CLOSURE[$ui]} " in
    *" $owner_mod "*) ;;
    *)
      printf 'check_module_order: module %s uses %s() from %s, but %s is not in %s dependency closure (declare it in lib/modules.txt)\n' "$user" "$fn" "$owner_mod" "$owner_mod" "$user" >&2
      bad=1
      ;;
  esac
done <"$TMP/pairs"

if [ "$bad" -ne 0 ]; then
  printf 'check_module_order: found problems\n' >&2
  exit 1
fi
printf 'check_module_order: ok\n'
