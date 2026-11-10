#!/usr/bin/env bash
# stub 这个 harness 自己的回归。历史缺陷：--body 是原样拼进 shell 函数的，
# body 里的 exit 会把整个测试脚本干掉 —— 退出码恰好是 0 ⇒ runner 判「全过」，
# 后面所有断言都没跑过（test_svc.sh 后半段就那么消失过）。
# 用「子 shell 里放 marker」的方式判据：脚本被提前杀掉时 marker 不会存在。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

work=$(tmpdir)

# CASE: body 里的 exit 0 不能杀掉调用方
marker="$work/case1"
(
  stub x --body 'exit 0'
  x
  touch "$marker"
) >/dev/null 2>&1
assert_eq "0" "$?" "a stub body that exits 0 must not fail the caller"
# （assert_true 只能传命令，说明写在注释里）
assert_true test -f "$marker"

# CASE: body 里的 exit N 是「让 stub 返回 N」，不是退出码包装纸
marker="$work/case2"
out="$work/case2.out"
(
  stub y --body 'exit 3'
  y || printf 'y_rc=%s' "$?" >"$out"
  touch "$marker"
) >/dev/null 2>&1
assert_true test -f "$marker"
assert_eq "y_rc=3" "$(cat "$out")" "the stub must return the body's exit code"

# CASE: body 的 return N 短路优先于 --exit；自然走完则落回 --exit
out="$work/case3.out"
(
  stub a --body 'return 22'
  a || printf 'a_rc=%s\n' "$?" >"$out"
  stub b --exit 7 --body 'return 0'
  b || printf 'b_rc=%s' "$?" >>"$out"
) >/dev/null 2>&1
assert_eq "a_rc=22
b_rc=7" "$(cat "$out")" "return N wins over --exit; fallthrough keeps --exit"

# CASE: body 里的 "$@" 是 stub 被调时的实参
out="$work/case4.out"
(
  stub c --body 'printf "%s" "$#:$1" >"'$out'"'
  c alpha beta
) >/dev/null 2>&1
assert_eq "2:alpha" "$(cat "$out")" "the body must see the stub's arguments"

exit 0
