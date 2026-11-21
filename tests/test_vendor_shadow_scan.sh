#!/usr/bin/env bash
#
# 判据：同名体检的「扫描」这一层必须守得住契约。
#
# 契约三条：
#   1. **退出码固定 0**：扫完了、一个都没撞，是常态不是错误。
#      以前退出码由管道末端的 grep 决定，而 grep「没匹配」返回 1 ⇒
#      「扫不动」与「扫完了」分不开 ⇒ 调用方静默放行（体检形同虚设）；
#      更糟的是那个退出码取决于 find 输出的**最后一个**文件有没有匹配 ⇒
#      同一份代码换个文件系统（ext4 哈希序 vs APFS 创建序）就换一种行为：
#      本机绿、CI 红 —— CI 上那条红就是这么来的。
#   2. 换名残骸（.shellkit-new / .shellkit-old）里的函数**不是**工程的代码：
#      那是库的上一份副本。不排除它们，换名被打断过的工程会被自己的旧副本
#      判成「撞了一整库」⇒ 升级被误挡（恢复流程直接走不通）。
#   3. 输出的路径相对工程 —— 报错要让人看得懂在哪一行。
#
# 为什么直接抽函数来测：这几个函数住在 CLI 脚本里，而 CLI 自己会跑 main，
# 没法整体 source。抽出来单独调，才能把「退出码」这种契约钉死 ——
# 从 CLI 外面只能看到「有没有报撞名」，而那受扫描顺序影响，测不稳。
set -u
# pipefail 必须跟 CLI 一致（CLI 是 set -euo pipefail）：扫描函数的退出码以前
# 就是被管道末端的 grep 决定 ⇒ pipefail 关着时那个泄漏根本看不出来 ⇒
# 判据会变成一句空话（在这里恒绿）。
set -o pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

# 覆盖工具插桩后会往源码里塞 __cov_hit —— 抽出来的代码会调它，这里给个空实现
__cov_hit() { :; }

work=$(tmpdir)

# 从 CLI 源码里抽出这三个扫描函数
awk '/^_sk_shadow_parse_line\(\)/{f=1} /^_sk_shadow_guard\(\)/{f=0} f' \
  "$TEST_ROOT/shellkit" >"$work/fns.sh"
if [ ! -s "$work/fns.sh" ]; then
  _fail "cannot extract the scan helpers from the CLI"
fi
# shellcheck source=/dev/null
. "$work/fns.sh"

# ---- 1. 一个函数都没有的项目：退出码必须是 0（不是「扫不动」）----
plain="$work/case1"
mkdir -p "$plain/lib"
printf '# 没有任何函数定义\nprintf "hello\\n"\n' >"$plain/lib/plain.sh"
out=$(_sk_shadow_project_fns "$plain" "vendor/shellkit")
rc=$?
assert_eq 0 "$rc" "a scan that finds nothing must still report success"
assert_eq "" "$out" "a project without functions has nothing to report"

# ---- 2. 有函数的项目：名字、相对路径、行号 ----
p2="$work/case2"
mkdir -p "$p2/lib"
printf 'registry_scan() {\n  :\n}\n' >"$p2/lib/mine.sh"
out=$(_sk_shadow_project_fns "$p2" "vendor/shellkit")
rc=$?
assert_eq 0 "$rc" "a scan that finds functions must report success"
assert_contains "$out" "registry_scan" "the function name is reported"
assert_contains "$out" "lib/mine.sh:1" "the path and the line are reported"
assert_not_contains "$out" "$p2" "the path must be relative to the project"

# ---- 3. 换名残骸里的函数不算工程的 ----
p3="$work/case3"
mkdir -p "$p3/lib" "$p3/vendor/.shellkit-new/lib" "$p3/vendor/.shellkit-old/lib"
printf 'my_own_helper() { :; }\n' >"$p3/lib/mine.sh"
cp -R "$TEST_ROOT/lib/core" "$p3/vendor/.shellkit-new/lib/"
cp -R "$TEST_ROOT/lib/core" "$p3/vendor/.shellkit-old/lib/"
out=$(_sk_shadow_project_fns "$p3" "vendor/shellkit")
rc=$?
assert_eq 0 "$rc" "the swap leftovers must not break the scan"
assert_contains "$out" "my_own_helper" "the project's own function is reported"
assert_not_contains "$out" "registry_scan" "the leftovers are the library's copy, not the project's code"

# ---- 4. 库的扫描：退出码 0，列得出公开函数 ----
out=$(_sk_shadow_lib_fns "$TEST_ROOT/lib")
rc=$?
assert_eq 0 "$rc" "the library scan must report success"
assert_contains "$out" "registry_scan" "the library's own public functions are listed"
assert_contains "$out" "core/registry.sh" "the path is relative to the library"

echo "test_vendor_shadow_scan: all cases passed"
