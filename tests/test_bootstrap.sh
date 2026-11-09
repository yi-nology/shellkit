#!/usr/bin/env bash
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"

assert_eq "$(cd "$TEST_ROOT" && pwd)" "$SHELLKIT_HOME" "SHELLKIT_HOME"
assert_eq "0" "$SK_OK" "SK_OK"
assert_eq "3" "$SK_PRECOND" "SK_PRECOND"
assert_eq "4" "$SK_NET" "SK_NET"
assert_eq "shellkit" "$TEXTDOMAIN" "TEXTDOMAIN"

# 不改变 cwd
out=$(cd / && . "$TEST_ROOT/lib/bootstrap.sh" && pwd)
assert_eq "/" "$out" "bootstrap must not change cwd"

# 不改变 shell 选项
before=$(set -o | awk '$1 == "pipefail" { print $2 }')
. "$TEST_ROOT/lib/bootstrap.sh"
after=$(set -o | awk '$1 == "pipefail" { print $2 }')
assert_eq "$before" "$after" "bootstrap must not change shell options"

# 常量
# 对磁盘上的 VERSION 取真值：bump 版本不该弄红门禁
assert_eq "$(tr -d '[:space:]' <"$TEST_ROOT/VERSION")" "$SK_VERSION" "SK_VERSION"

# ---------------------------------------------------------------------------
# 按需加载：SHELLKIT_MODULES
#
#   不设 / 设为空  -> 全部模块（与以前逐字一致）
#   SHELLKIT_MODULES="log fs" -> 这两个模块 + 它们的传递依赖
#   i18n 恒定加载（_t 是公共依赖）
# ---------------------------------------------------------------------------

# 清单里的模块（第一列）
_manifest_modules() {
  awk '!/^[[:space:]]*#/ && NF { print $1 }' "$TEST_ROOT/lib/modules.txt"
}

# 已加载的模块清单（一行一个，按模块名排序）。
# 判断依据：模块里定义的某个函数在 bootstrap 之后存在。
# SHELLKIT_MODULES 为空 = 不限制 = 全部模块。
_loaded_modules() {
  SHELLKIT_MODULES="${1-}" bash -c '
    . "$1/lib/bootstrap.sh" >/dev/null 2>&1 || exit 1
    for f in "$1"/lib/core/*.sh; do
      m=${f##*/}
      m=${m%.sh}
      fn=$(grep -E "^[A-Za-z_][A-Za-z0-9_]*[(][)]" "$f" | head -1 | sed "s/[(].*//")
      [ -n "$fn" ] || continue
      if declare -F "$fn" >/dev/null 2>&1; then printf "%s\n" "$m"; fi
    done
  ' _ "$TEST_ROOT"
}

# 1) 默认全量加载：清单里的每个模块都要加载
assert_eq "$(_manifest_modules | LC_ALL=C sort | paste -sd' ' -)" \
  "$(_loaded_modules "" | LC_ALL=C sort | paste -sd' ' -)" \
  "default load must load every module listed in lib/modules.txt"

# 2) SHELLKIT_MODULES 只加载闭包：log fs -> i18n log error trap fs
assert_eq "error fs i18n log trap" \
  "$(_loaded_modules "log fs" | LC_ALL=C sort | paste -sd' ' -)" \
  'SHELLKIT_MODULES="log fs" must load exactly the dependency closure'

# 3) i18n 恒定加载
assert_eq "i18n log" \
  "$(_loaded_modules "log" | LC_ALL=C sort | paste -sd' ' -)" \
  "i18n must always be loaded"

# 4) 未知模块报错：stderr 说清楚是哪个模块，退出码非 0
rc=0
err=$(SHELLKIT_MODULES=nosuchmodule bash -c '. "$1/lib/bootstrap.sh"' _ "$TEST_ROOT" 2>&1 >/dev/null) || rc=$?
assert_ne "0" "$rc" "an unknown module in SHELLKIT_MODULES must fail"
assert_contains "$err" "nosuchmodule" "the error must name the unknown module"

# 5) 列出全部模块 == 不设变量
_all=$(_manifest_modules | paste -sd' ' -)
assert_eq "$(_loaded_modules "" | LC_ALL=C sort | paste -sd' ' -)" \
  "$(_loaded_modules "$_all" | LC_ALL=C sort | paste -sd' ' -)" \
  "listing every module must be equivalent to leaving SHELLKIT_MODULES unset"

# 6) SHELLKIT_DEBUG=1 时向 stderr 打印一行，说明加载了哪几个模块
dbg=$(SHELLKIT_DEBUG=1 SHELLKIT_MODULES="log fs" bash -c '. "$1/lib/bootstrap.sh"' _ "$TEST_ROOT" 2>&1 >/dev/null)
assert_contains "$dbg" "loading modules:" "SHELLKIT_DEBUG=1 must print the module list to stderr"
assert_contains "$dbg" "i18n log" "the debug line must list the loaded modules"

# ---------------------------------------------------------------------------
# 依赖门禁自测：人造两种坏清单，门禁必须红
# ---------------------------------------------------------------------------
g=$(tmpdir)
mkdir -p "$g/root" || _fail "mkdir failed"
cp -R "$TEST_ROOT/lib" "$TEST_ROOT/tools" "$TEST_ROOT/tests" "$g/root/" || _fail "copy failed"

# (a) 依赖声明缺失：cli 用了 str 的函数，依赖里却没有 str
awk '{
  if ($1 == "cli") {
    out = ""
    for (i = 2; i <= NF; i++) {
      if ($i != "str") out = out " " $i
    }
    print "cli" out
    next
  }
  print
}' "$TEST_ROOT/lib/modules.txt" >"$g/root/lib/modules.txt"
rc=0
out=$(bash "$g/root/tools/check_module_order.sh" 2>&1) || rc=$?
assert_ne "0" "$rc" "the gate must reject a missing dependency declaration"
assert_contains "$out" "dependency closure" "the gate must say which dependency is missing"

# (b) 依赖顺序颠倒：把 i18n 挪到最后，依赖它的模块全变成「依赖排在后面」
awk '/^i18n[[:space:]]*$/{ i = $0; next } { print } END { if (i != "") print i }' \
  "$TEST_ROOT/lib/modules.txt" >"$g/root/lib/modules.txt"
rc=0
out=$(bash "$g/root/tools/check_module_order.sh" 2>&1) || rc=$?
assert_ne "0" "$rc" "the gate must reject a dependency that is listed after its user"
assert_contains "$out" "is listed after" "the gate must say which dependency is out of order"

# (c) 扫描器自己坏了：门禁必须红，不能「什么都没扫到 ⇒ 算通过」
#
# 这是真踩过的坑：awk 报错时输出里没有门禁认识的行，门禁就以为一切正常 ——
# 工具崩了与检查通过必须分得开。
printf 'if (\n' >>"$g/root/tools/module_order.awk"
rc=0
out=$(bash "$g/root/tools/check_module_order.sh" 2>&1) || rc=$?
assert_ne "0" "$rc" "the gate must fail when the scanner itself breaks"
assert_contains "$out" "scanner failed" "the gate must say the scanner failed"
