#!/usr/bin/env bash
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"

d=$(tmpdir)

# 逆序执行：后注册的先跑（整段都在子 shell 里，栈的变更自洽）
out=$(
  trap_push 'echo one'
  trap_push 'echo two'
  trap_push 'echo three'
  trap_cleanup
)
assert_eq $'three\ntwo\none' "$out" "cleanup runs in LIFO order"

# 幂等：在当前 shell 里跑，第二次必须什么都不做
trap_push 'echo once'
trap_cleanup >"$d/c1" 2>/dev/null
assert_eq "once" "$(cat "$d/c1")" "first cleanup runs the action"
trap_cleanup >"$d/c2" 2>/dev/null
assert_eq "" "$(cat "$d/c2")" "second cleanup does nothing"

# 单个动作失败不中断其余，且 cleanup 自身仍返回 0
out=$(
  trap_push 'false'
  trap_push 'echo survived'
  trap_cleanup 2>/dev/null
)
assert_eq "survived" "$out" "a failing step does not stop the rest"
assert_exit_code 0 bash -c ". '$TEST_ROOT/lib/bootstrap.sh'; trap_push false; trap_cleanup 2>/dev/null"

# trap_pop 丢弃最近一个且不执行
out=$(
  trap_push 'echo a'
  trap_push 'echo b'
  trap_pop
  trap_cleanup
)
assert_eq "a" "$out" "trap_pop drops the most recent action"

# trap_list 顺序与内容
out=$(
  trap_push 'echo a'
  trap_push 'echo b'
  trap_list
)
assert_contains "$out" "0 echo a" "trap_list shows index 0"
assert_contains "$out" "1 echo b" "trap_list shows index 1"

# 无参数
assert_exit_code 2 trap_push

# 链式保留调用方已有的 EXIT trap
out=$(
  trap 'echo user-exit' EXIT
  trap_push 'echo pushed'
  trap_install
  exit 0
)
assert_eq $'pushed\nuser-exit' "$out" "chained user EXIT trap runs after pushed cleanups"

# trap_install 可重复调用，不会重复执行
out=$(
  trap_push 'echo x'
  trap_install
  trap_install
  exit 0
)
assert_eq "x" "$out" "trap_install is idempotent"

# 退出码保真：cleanup 不能改写脚本的退出码
code=$(
  (
    trap_push 'echo clean' >/dev/null
    trap_install
    exit 42
  ) >/dev/null 2>&1
  printf '%s\n' "$?"
)
assert_eq "42" "$code" "exit status survives cleanup"

# 回归：子 shell 里「trap -p EXIT 看得见、却不会执行」的残影不能骗过幂等判断。
# bash 5 起子 shell 里 trap -p EXIT 仍显示父 shell 设的 trap（实测 5.3：看得见、
# 子 shell 退出时不执行），bash 3.2 显示为空。这里直接造出这种形态：
# 先放一个同名处理器痕迹，再调 trap_install —— 必须仍然真的装上、退出时真的跑。
out=$(
  trap '_sk_trap_on_exit' EXIT
  trap_push 'printf "child-cleanup\n"'
  trap_install
)
assert_contains "$out" "child-cleanup"
