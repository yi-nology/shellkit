#!/usr/bin/env bash
# trap_install 在子 shell 里**不得**替父进程收尾。
#
# 缺陷现场：调用方 `trap 'rm -rf "$work"' EXIT`，随后在**子 shell** 里调了任何
# 会走到 trap_install 的函数（lock_acquire / fs_tmp_init / proc_*）⇒ 子 shell
# 退出时把调用方的 work 目录删了 ⇒ 父进程后续写文件直接 "No such file or directory"。
#
# bash 自己**不会**执行继承来的 EXIT trap（3.2 与 5 都是）—— 是库里把 handler
# 捕获下来再 eval，等于替 bash 执行了它。捕获能不能发生，看子 shell 里 `trap -p`
# 读到的形态（两版 bash 实测）：
#   命令替换 $( )：3.2 与 5 都读到完整形态（"trap -- '...' EXIT"）⇒ 都会捕获
#   括号子 shell ( )：3.2 读到**空**（不捕获）、5 读到完整形态（捕获）
# ⇒ 判据一律用**命令替换**：那是两个版本都会中招的写法，断言在两边都有牙齿。
#
# 「替父进程收尾」有**两层**，判据三个场景各钉一层：
#   A 调用方自设的 EXIT handler（_SK_TRAP_SAVED_EXIT）
#   B 父进程自己 trap_install 过 ⇒ 子 shell 继承来的那份
#   C 父进程 trap_push 过 ⇒ 子 shell 继承来的清理栈条目（_SK_TRAP_CMDS）
# 只钉 A 是不够的：第一版修法（把「清继承状态」写在捕获分支里）实测仍复现 B 与 C。
#
# ⚠ 层级归属不能在使用时现读 BASH_SUBSHELL：bash 3.2 执行**函数型** EXIT handler
# 时会把它复位成 0（字符串型不复位；bash 5 两者都不复位）⇒ 处理器里现读会把
# 子 shell 误判成顶层 ⇒ 归属判定全错。
#
# ⚠ 每个场景必须跑在**独立进程**里：场景的「父进程」得是顶层 shell
# （BASH_SUBSHELL=0）。库在子 shell 里**按设计**不捕获调用方的 EXIT handler
#（那正是修复的一部分）⇒ 若把「父进程」也塞进 $( )，它自己就不捕获
# ⇒ 继承层根本不存在 ⇒ 场景恒绿、判据没有牙齿（第一版就踩了这个）。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"

d="$(tmpdir)"

# 场景脚本：$1 = 库路径（可指向变异副本），$2 = 场景
cat >"$d/case.sh" <<'EOS'
#!/usr/bin/env bash
set -u
. "$TEST_ROOT/lib/bootstrap.sh"
. "$1"
mode="$2"
dd=$(mktemp -d)
w="$dd/target"
mkdir -p "$w"
case "$mode" in
user_trap)
  trap 'rm -rf "$w"' EXIT
  ;;
inherited_handler)
  trap 'rm -rf "$w"' EXIT
  trap_install >/dev/null 2>&1
  ;;
inherited_stack)
  trap_push "rm -rf \"$w\""
  trap_install >/dev/null 2>&1
  ;;
*)
  echo "unknown mode: $mode" >&2
  exit 2
  ;;
esac
__o=$(trap_install >/dev/null 2>&1)
if [ -d "$w" ]; then printf 'survived'; else printf 'deleted'; fi
rm -rf "$dd"
EOS

# ------------------------------------------------------------------
# 场景 A：调用方自设的 EXIT handler —— 子 shell 里不得提前执行
# ------------------------------------------------------------------
# 注意：检查必须放在**命令替换结束之后** —— 清理是在替换退出时才跑的，
# 在替换里面查 ⇒ 查的是「还没退出的状态」，永远看着是 survived。
res_a=$("$BASH" "$d/case.sh" "$TEST_ROOT/lib/core/trap.sh" user_trap)
assert_eq "survived" "$res_a" "场景A：子 shell 里不得提前执行调用方的 EXIT 清理"

# ------------------------------------------------------------------
# 场景 B：父进程自己 trap_install 过 ⇒ 子 shell 继承来的那份不得执行
# ------------------------------------------------------------------
res_b=$("$BASH" "$d/case.sh" "$TEST_ROOT/lib/core/trap.sh" inherited_handler)
assert_eq "survived" "$res_b" "场景B：子 shell 不得执行继承来的调用方 EXIT 清理"

# ------------------------------------------------------------------
# 场景 C：父进程 trap_push 过 ⇒ 子 shell 继承来的清理栈条目不得执行
# ------------------------------------------------------------------
res_c=$("$BASH" "$d/case.sh" "$TEST_ROOT/lib/core/trap.sh" inherited_stack)
assert_eq "survived" "$res_c" "场景C：子 shell 不得执行继承来的清理栈条目"

# ------------------------------------------------------------------
# 变异自证 1：把守卫改坏 ⇒ 场景 A 必须复现
# ------------------------------------------------------------------
# 变异：把**守卫那一行**改坏（判据调用改成 false）⇒ 守卫永远不生效 ⇒ 缺陷复现。
# 为什么改守卫而不是改判定函数：判定函数里有多个 return，改哪一句都可能
# 「改到了但没改到点上」（第一版就踩了这个：改的是末尾那句 return 0，
# 而 case 分支里的 return 0 提前返回了 ⇒ 变异等于没改）。
# 守卫那一行是单行、无歧义的 ⇒ 变异一定落在要测的那条路径上。
__hits=$(grep -c -F '&& _sk_trap_in_subshell; then' "$TEST_ROOT/lib/core/trap.sh")
if [ "$__hits" != "1" ]; then
  printf 'FAIL: 守卫那行匹配到 %s 次（应为 1）—— 变异没落到源码上，判据自己坏了\n' "$__hits" >&2
  exit 1
fi
awk '{ if (index($0, "&& _sk_trap_in_subshell; then") > 0) { sub(/_sk_trap_in_subshell/, "false") } print }' "$TEST_ROOT/lib/core/trap.sh" >"$d/m1.sh"
if cmp -s "$TEST_ROOT/lib/core/trap.sh" "$d/m1.sh"; then
  printf 'FAIL: 变异 1 没改到任何东西 —— 判据自己坏了\n' >&2
  exit 1
fi
res_m1=$("$BASH" "$d/case.sh" "$d/m1.sh" user_trap)
assert_eq "deleted" "$res_m1" "变异自证 1：守卫改坏后，场景 A 必须复现"

# ------------------------------------------------------------------
# 变异自证 2：拆掉「继承状态」的两道防线 ⇒ 场景 B 必须复现
# ------------------------------------------------------------------
# 场景 B 由两道防线兜着：① trap_install 在子 shell 里清掉继承来的 SAVED_EXIT；
# ② trap_cleanup 只执行「本层捕获」的那份。只拆一道，另一道还兜着 ⇒ 断言不会红
# ⇒ 这条变异必须**两道一起拆**（拆干净才是「还原成缺陷前的行为」）。
# 形状守卫：两处各只匹配一次，否则变异可能没落到要测的那条路径上。
__h1=$(grep -c -F 'if _sk_trap_in_subshell; then' "$TEST_ROOT/lib/core/trap.sh")
__h2=$(grep -c -F 'SAVED_EXIT_LVL:-0' "$TEST_ROOT/lib/core/trap.sh")
if [ "$__h1" != "1" ] || [ "$__h2" != "1" ]; then
  printf 'FAIL: 变异 2 的两处锚点命中数异常（%s / %s，应为 1 / 1）—— 判据自己坏了\n' "$__h1" "$__h2" >&2
  exit 1
fi
awk '
  { if (index($0, "if _sk_trap_in_subshell; then") > 0) { sub(/if _sk_trap_in_subshell; then/, "if false; then") } }
  { if (index($0, "SAVED_EXIT_LVL:-0") > 0) { print "    [ \"x\" = \"x\" ]; then"; next } }
  { print }
' "$TEST_ROOT/lib/core/trap.sh" >"$d/m2.sh"
if cmp -s "$TEST_ROOT/lib/core/trap.sh" "$d/m2.sh"; then
  printf 'FAIL: 变异 2 没改到任何东西 —— 判据自己坏了\n' >&2
  exit 1
fi
res_m2=$("$BASH" "$d/case.sh" "$d/m2.sh" inherited_handler)
assert_eq "deleted" "$res_m2" "变异自证 2：继承状态的两道防线都拆掉后，场景 B 必须复现"

# ------------------------------------------------------------------
# 变异自证 3：拆掉清理栈的层级过滤 ⇒ 场景 C 必须复现
# ------------------------------------------------------------------
__h3=$(grep -c -F '[ "$__ent" = "$__lvl" ]' "$TEST_ROOT/lib/core/trap.sh")
if [ "$__h3" != "1" ]; then
  printf 'FAIL: 变异 3 的锚点命中 %s 次（应为 1）—— 判据自己坏了\n' "$__h3" >&2
  exit 1
fi
awk '{ if (index($0, "[ \"$__ent\" = \"$__lvl\" ]") > 0) { print "    if [ -n \"$__cmd\" ] && [ \"x\" = \"x\" ]; then"; next } print }' "$TEST_ROOT/lib/core/trap.sh" >"$d/m3.sh"
if cmp -s "$TEST_ROOT/lib/core/trap.sh" "$d/m3.sh"; then
  printf 'FAIL: 变异 3 没改到任何东西 —— 判据自己坏了\n' >&2
  exit 1
fi
res_m3=$("$BASH" "$d/case.sh" "$d/m3.sh" inherited_stack)
assert_eq "deleted" "$res_m3" "变异自证 3：清理栈的层级过滤拆掉后，场景 C 必须复现"

echo "OK: 子 shell 里的 trap_install 不再替父进程收尾（调用方 handler / 继承状态 / 清理栈 三层）"
