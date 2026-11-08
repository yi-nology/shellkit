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

# 调用方的 INT/TERM/HUP handler 不能被静默覆盖。
# 顺序：先跑清理栈，再跑调用方的 handler，最后以 128+sig 退出。
# 用 bash -c 起真进程：$() 里 $$ 仍是父 shell 的 pid，kill -INT $$ 会打到测试进程自己身上。
out=$(bash -c '
  . "$1/lib/bootstrap.sh"
  trap "printf \"user-int\\n\"" INT
  trap_push "printf \"cleanup\\n\""
  trap_install
  kill -INT $$
  sleep 5
' _ "$TEST_ROOT")
assert_contains "$out" "cleanup" "cleanup runs before the caller's INT handler"
assert_contains "$out" "user-int" "the caller's INT handler is chained, not replaced"

out=$(bash -c '
  . "$1/lib/bootstrap.sh"
  trap "printf \"user-term\\n\"" TERM
  trap_push "printf \"cleanup\\n\""
  trap_install
  kill -TERM $$
  sleep 5
' _ "$TEST_ROOT")
assert_contains "$out" "user-term" "the caller's TERM handler is chained"

out=$(bash -c '
  . "$1/lib/bootstrap.sh"
  trap "printf \"user-hup\\n\"" HUP
  trap_install
  kill -HUP $$
  sleep 5
' _ "$TEST_ROOT")
assert_contains "$out" "user-hup" "the caller's HUP handler is chained"

# 没有调用方 handler 时，信号仍以 128+sig 退出（清理动作照样跑）
out=$(
  bash -c '
  . "$1/lib/bootstrap.sh"
  trap_push "printf \"cleanup\\n\""
  trap_install
  kill -TERM $$
  sleep 5
  printf "survived\\n"
' _ "$TEST_ROOT"
  printf 'rc=%s' "$?"
)
assert_contains "$out" "cleanup"
assert_contains "$out" "rc=143" "a bare TERM exits with 128+15"
assert_not_contains "$out" "survived"
