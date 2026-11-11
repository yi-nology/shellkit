#!/usr/bin/env bash
# 独立修复脚本（repair.sh）的回归。
#
# 要守的是一条运维底线：**CLI 起不来时，还有一条不依赖 CLI 的路能把机器救回来**。
#
# 场景：安装或 vendor 同步在「旧目录已经移走、新目录还没就位」的瞬间被中断，
# 装好的 shellkit 就此起不来 —— 恢复逻辑写在 CLI 里，而 CLI 自己就是那个
# 起不来的东西。备份不一定丢，缺的是入口。
#
# 断言纪律：断完整文案不断单词；临时目录名只用编号。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

REPAIR="$TEST_ROOT/repair.sh"

# mk_copy DIR —— 造一份「完整的 shellkit 副本」
#
# 判据用 lib/bootstrap.sh：CLI 与库都靠它启动，缺了它这份副本就是半份。
mk_copy() {
  local d=$1
  mkdir -p "$d/lib" || return 1
  printf '#!/usr/bin/env bash\n' >"$d/lib/bootstrap.sh" || return 1
  printf '#!/usr/bin/env bash\necho shellkit\n' >"$d/shellkit" || return 1
  chmod 755 "$d/shellkit" || return 1
  return 0
}

# CASE: 脚本本身不依赖任何库
#
# 它必须能在「只剩已安装副本、没有源码仓库」的机器上独立跑起来。
# 判据是「没有任何 source 点」—— 有 source 就说明它会去别处找东西。
n_source=$(grep -cE '^[[:space:]]*(\.|[[:space:]]source[[:space:]])' "$REPAIR" || true)
assert_eq "0" "$n_source" "the repair script must not source anything"

# CASE: 主副本没了、旧副本完整 —— 必须把旧副本挪回去
d=$(tmpdir) || _fail "cannot create tmpdir"
prefix="$d/p1"
mk_copy "$prefix/share/shellkit.old" || _fail "cannot build the old copy"
out=$(bash "$REPAIR" --prefix "$prefix" 2>&1)
rc=$?
assert_eq "0" "$rc" "the repair must succeed when the old copy is complete"
assert_contains "$out" "restored from the old copy" "the repair must say what it did"
assert_true test -f "$prefix/share/shellkit/lib/bootstrap.sh"
assert_false test -e "$prefix/share/shellkit.old"

# CASE: 主副本完整、旁边留着旧副本 —— 残骸是垃圾，清掉
d=$(tmpdir) || _fail "cannot create tmpdir"
prefix="$d/p2"
mk_copy "$prefix/share/shellkit" || _fail "cannot build the copy"
mk_copy "$prefix/share/shellkit.old" || _fail "cannot build the leftover"
out=$(bash "$REPAIR" --prefix "$prefix" 2>&1)
rc=$?
assert_eq "0" "$rc" "a healthy install with leftovers must still succeed"
assert_true test -f "$prefix/share/shellkit/lib/bootstrap.sh"
assert_false test -e "$prefix/share/shellkit.old"

# CASE: 工程里的 vendor 副本 —— 同样能救
d=$(tmpdir) || _fail "cannot create tmpdir"
proj="$d/p3"
mk_copy "$proj/vendor/.shellkit-old" || _fail "cannot build the old vendored copy"
out=$(bash "$REPAIR" --prefix "$d/p3prefix" --project "$proj" 2>&1)
rc=$?
assert_eq "0" "$rc" "the repair must restore a broken vendored copy"
assert_true test -f "$proj/vendor/shellkit/lib/bootstrap.sh"
assert_false test -e "$proj/vendor/.shellkit-old"

# CASE: 修不了的时候必须明说，不能假装成功
d=$(tmpdir) || _fail "cannot create tmpdir"
prefix="$d/p4"
# 半份副本：目录在、bootstrap.sh 不在 —— 判据认得出它不能用
mkdir -p "$prefix/share/shellkit.old/lib"
printf 'half\n' >"$prefix/share/shellkit.old/lib/other.sh"
out=$(bash "$REPAIR" --prefix "$prefix" 2>&1)
rc=$?
assert_ne "0" "$rc" "an unrepairable copy must not report success"
assert_contains "$out" "nothing to restore from" "the refusal must say why"

# CASE: --check 只报告，不动手
d=$(tmpdir) || _fail "cannot create tmpdir"
prefix="$d/p5"
mk_copy "$prefix/share/shellkit.old" || _fail "cannot build the old copy"
out=$(bash "$REPAIR" --prefix "$prefix" --check 2>&1)
rc=$?
assert_ne "0" "$rc" "a broken copy must be reported even in check mode"
assert_false test -e "$prefix/share/shellkit"
assert_true test -f "$prefix/share/shellkit.old/lib/bootstrap.sh"

# CASE: 「只剩已安装副本、没有源码仓库」的那台机器
#
# 脚本自己就在被中断的旧副本里（rename 之前它已经就位了），
# 从自己的位置反推 PREFIX 就能修 —— 不需要 --prefix，也不需要源码仓库。
d=$(tmpdir) || _fail "cannot create tmpdir"
prefix="$d/p6"
mk_copy "$prefix/share/shellkit.old" || _fail "cannot build the old copy"
cp "$REPAIR" "$prefix/share/shellkit.old/repair.sh" || _fail "cannot place the repair script"
chmod 755 "$prefix/share/shellkit.old/repair.sh"
out=$(bash "$prefix/share/shellkit.old/repair.sh" 2>&1)
rc=$?
assert_eq "0" "$rc" "the repair script must work from inside the broken install"
assert_true test -f "$prefix/share/shellkit/lib/bootstrap.sh"
assert_false test -e "$prefix/share/shellkit.old"

# CASE: 用法错必须退 2
rc=0
bash "$REPAIR" --nope >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "usage errors must exit 2"
rc=0
bash "$REPAIR" --prefix >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "an option without its value must exit 2"

exit 0
