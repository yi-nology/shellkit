#!/usr/bin/env bash
#
# 判据：选区解析的「越界判错」必须真的拦得住（变异自证）。
#
# 为什么单独成文件：这一条要**改写源码里的字面量**再跑一遍。
# 分支覆盖的插桩会改写 lib/core 的分支臂 ⇒ 同一个字面量在插桩后的文件里
# 已经对不上了 ⇒ 变异造不成 ⇒ 断言反而会红（覆盖工具会判定「插桩后套件变红」）。
# 仓库里同类的例子是 tests/test_meta_gates.sh —— 它在分支模式下被排除
# （tools/coverage.sh 的 COV_EXCLUDES），理由写在那里。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"

# ---- 变异自证：把「越界判错」改坏 ⇒ 越界必须被接受 ----
# 判据没有牙齿的话，tests/test_str.sh 里那几条退 1 的断言只是「照着实现抄的」。
# 这里造一份被改坏的 str.sh（同一个库、只坏这一处）再跑一遍：
# 它必须**接受**越界编号 —— 证明拦住越界的确实是源码里那一条。
_mut_work=$(tmpdir)
sed -E 's/\[ "\$__n" -le "\$__max" \] \|\| return 1/: # 变异：不再判越界/' "$TEST_ROOT/lib/core/str.sh" >"$_mut_work/str.sh"
# 跑法写成脚本文件：路径在写文件时就展开，避开嵌套引号与「变量没导出」两个坑。
cat >"$_mut_work/run.sh" <<EOF
. "$TEST_ROOT/lib/bootstrap.sh" >/dev/null 2>&1
. "$_mut_work/str.sh"
str_parse_indices '9' 3
EOF
_mut_out=$(bash "$_mut_work/run.sh" 2>/dev/null || true)
assert_eq "9" "$_mut_out" "the mutated copy accepts an out-of-range index (the case above has teeth)"

echo "test_str_mutation: all cases passed"
