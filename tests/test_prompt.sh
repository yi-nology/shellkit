#!/usr/bin/env bash
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"

SHELLKIT_NONINTERACTIVE=1

v=""
ask v "Project name" "demo" 2>/dev/null
assert_eq "demo" "$v" "ask uses default"

assert_exit_code 3 ask v "Project name" 2>/dev/null
assert_exit_code 2 ask "bad-name" "p" "d" 2>/dev/null

v=""
ask_yn v "Continue?" "y" 2>/dev/null
assert_eq "y" "$v" "ask_yn default y"

v=""
ask_yn v "Continue?" "n" 2>/dev/null
assert_eq "n" "$v" "ask_yn default n"

assert_true confirm "Proceed?" "y" 2>/dev/null
assert_false confirm "Proceed?" "n" 2>/dev/null

v=""
ask_choice v "Engine" "mysql|postgresql" "postgresql" 2>/dev/null
assert_eq "postgresql" "$v" "ask_choice default"

assert_exit_code 2 ask_choice v "Engine" "mysql|postgresql" "oracle" 2>/dev/null

f="$TEST_TMP_ROOT/line.txt"
printf 'abc\n' >"$f"
line=""
_sk_read_line line "" <"$f"
assert_eq "abc" "$line" "_sk_read_line reads"

line=""
assert_exit_code 1 _sk_read_line line "" </dev/null

start=$SECONDS
line=""
assert_exit_code 2 _sk_read_line line 1 < <(sleep 5)
elapsed=$((SECONDS - start))
if [ "$elapsed" -gt 3 ]; then
  _fail "_sk_read_line timeout took ${elapsed}s, expected about 1s"
fi

# 目标变量名与库内部缓冲同名时，读到的内容也必须写回调用方。
# printf -v 写的是「最近一层声明了该名字的作用域」：_sk_read_line 若自己声明了
# 同名 local，内容就写回自己那层，函数一返回即丢失。历史上缓冲与目标变量都叫
# __line，于是 ask/ask_yn/ask_choice/confirm 永远返回默认值、用户输入被丢弃。
__line=""
_sk_read_line __line "" <"$f"
assert_eq "abc" "$__line" "_sk_read_line must not lose the value when the target name shadows the internal buffer"

# ---- 出参名保留字：撞上出参链路上的局部变量必须当场拒绝 ----
# 不拒绝的话，内容会写回函数自己的局部变量，调用方拿到的还是原值 —— 静默失效。
assert_exit_code 2 ask __var "Q" 2>/dev/null
assert_exit_code 2 ask_yn __msg "Q" 2>/dev/null
assert_exit_code 2 ask_choice __choices "Q" "a|b" 2>/dev/null

# 但不是「__ 前缀一律拒绝」：名单之外的变量名照常能用。
# 非交互且没有默认值时是 3（前置条件），不是 2（保留名）—— 这就证明没被误拒。
assert_exit_code 3 ask __not_reserved "Q" 2>/dev/null

# 私有读行函数也不能让目标名撞上自己的局部变量
assert_exit_code 2 _sk_read_line __buf "" </dev/null
