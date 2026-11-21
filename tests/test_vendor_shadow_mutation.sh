#!/usr/bin/env bash
#
# 变异自证：把「扫描的退出码不漏出来」与「残骸不算工程代码」改坏 ⇒
# tests/test_vendor_shadow_scan.sh 的契约断言必须红。
#
# 变异一（退出码 · 旧实现）：把**旧实现逐字放回去**（CI 红之前的那一版）——
#   逐个文件 grep，函数的退出码由管道末端的 grep 决定 ⇒ grep「没匹配」
#   返回 1 ⇒「扫完了、一个都没撞」被当成「扫不动」⇒ 调用方静默放行。
#   放回去之后，扫描在「一个都没撞」时返回 1 ⇒ 契约断言（必须是 0）必须红。
#
# 变异二（退出码 · 现实现）：把现实现里兜底的三处一起去掉
#   （set +o pipefail / 子 shell 的 exit 0 / 函数末尾的 return 0），
#   退出码于是又由管道决定 ⇒ 契约断言必须红。
#
# 变异三（残骸）：删掉 .shellkit-old 的排除 ⇒ 残骸里的库函数被当成工程的代码。
#
# 单独成文件：这一条要**改写源码里的字面量**。分支覆盖的插桩会改写 CLI 里的
# 分支臂 ⇒ 同一个字面量在插桩后的文件里已经对不上了 ⇒ 变异造不成 ⇒ 断言
# 反而会红（覆盖工具会判定「插桩后套件变红」）。仓库里同类的例子是
# tests/test_meta_gates.sh 与 tests/test_str_mutation.sh。
set -u
# pipefail 必须跟 CLI 一致（CLI 是 set -euo pipefail）：退出码的泄漏只在
# pipefail 开着时才现形 ⇒ 关着的话这个用例恒绿，等于没有判据。
set -o pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

# 覆盖工具插桩后会往源码里塞 __cov_hit —— 抽出来的代码会调它，这里给个空实现
__cov_hit() { :; }

work=$(tmpdir)

plain="$work/case1"
mkdir -p "$plain/lib"
printf '# 没有任何函数定义\nprintf "hello\\n"\n' >"$plain/lib/plain.sh"

leftover="$work/case2"
mkdir -p "$leftover/lib" "$leftover/vendor/.shellkit-old/lib"
printf 'my_own_helper() { :; }\n' >"$leftover/lib/mine.sh"
cp -R "$TEST_ROOT/lib/core" "$leftover/vendor/.shellkit-old/lib/"

# ---- 变异一：把旧实现逐字放回去 ⇒ 退出码又漏出来 ----
cat >"$work/old.sh" <<'OLD_EOF'
_sk_shadow_project_fns() {
  local __dir=$1 __rel=$2 __abs __f __line __rest __name
  __abs=$(cd "$__dir" 2>/dev/null && pwd -P) || return 1
  find "$__abs" -type f -name '*.sh' -not -path "$__abs/$__rel/*" -not -path "$__abs/.git/*" 2>/dev/null |
    while IFS= read -r __f; do
      grep -n -E '^[a-z_][a-z0-9_]*\(\)' "$__f" 2>/dev/null |
        while IFS=: read -r __line __rest; do
          [ -n "$__line" ] || continue
          __name=${__rest%%(*}
          [ -n "$__name" ] || continue
          printf '%s\t%s:%s\n' "$__name" "${__f#"$__abs"/}" "$__line"
        done
    done
}
OLD_EOF
# shellcheck source=/dev/null
. "$work/old.sh"
out=$(_sk_shadow_project_fns "$plain" "vendor/shellkit")
rc=$?
assert_ne 0 "$rc" "the old scan leaks the pipeline status (the contract assert has teeth)"
assert_eq "" "$out" "the old scan still finds nothing in a project without functions"

# ---- 变异二：让扫描返回非 0 ⇒ 契约断言必须红 ----
#
# 老实现里，扫描的退出码就是 grep「没匹配」返回的 1 一路传上来的。
# 这里直接把它变成 1：**不依赖 find 的退出码**（GNU 与 BSD 的 find 在
# 「-exec 的命令返回非 0」时退出码不一样 ⇒ 拿它当判据会变成平台相关）——
# 要判的是「扫描返回非 0 时，契约断言必须红」。

awk '/^_sk_shadow_parse_line\(\)/{f=1} /^_sk_shadow_guard\(\)/{f=0} f' \
  "$TEST_ROOT/shellkit" >"$work/fns.sh"
if [ ! -s "$work/fns.sh" ]; then
  _fail "cannot extract the scan helpers from the CLI"
fi
# 末尾那行 return 0 要**删掉**（不是换成 :）—— 换成 : 反而把状态清成 0，
# 状态就看不见了。删掉之后，函数的状态就是子 shell 的状态。
sed -e 's/^    exit 0$/    exit 1/' \
  -e '/^  return 0$/d' \
  "$work/fns.sh" >"$work/fns-mut.sh"
# shellcheck source=/dev/null
. "$work/fns-mut.sh"
out=$(_sk_shadow_project_fns "$plain" "vendor/shellkit")
rc=$?
assert_ne 0 "$rc" "a scan that returns non-zero must break the contract (the contract assert has teeth)"

# ---- 变异三：残骸又被当成工程的代码 ----
sed -e '/\.shellkit-old/d' "$work/fns.sh" >"$work/fns-mut2.sh"
# shellcheck source=/dev/null
. "$work/fns-mut2.sh"
out=$(_sk_shadow_project_fns "$leftover" "vendor/shellkit")
assert_contains "$out" "registry_scan" "the mutated scan must treat the leftovers as the project's code"

echo "test_vendor_shadow_mutation: all cases passed"
