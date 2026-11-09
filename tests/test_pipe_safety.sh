#!/usr/bin/env bash
#
# 门禁自测：check_pipe_safety.sh 必须在「有人写出提前退出的管道消费者」时变红。
#
# 为什么需要自测：门禁自己崩了、或者规则写空了，输出就会是「一切正常」——
# 而那恰恰是最需要它响的时候。
#
# 坏例子写在单引号里、且压成一行：门禁按行扫描源码，引号里的 | 不算管道；
# 跨行的字符串第二行会被当成真实代码扫描。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

GATE="$TEST_ROOT/tools/check_pipe_safety.sh"
FAKE="$TEST_TMP_ROOT/fake-root"
PROBE="$FAKE/lib/core/probe.sh"

mkdir -p "$FAKE/lib/core" "$FAKE/tools"
cp "$GATE" "$FAKE/tools/check_pipe_safety.sh"

run_gate() {
  SHELLKIT_CHECK_ROOT="$FAKE" bash "$FAKE/tools/check_pipe_safety.sh" 2>&1
}

# printf 只写一次，接在 grep -q 后面是安全的
GOOD='v() { printf "%s\n" "$1" | grep -q x; }'
# 生产者会被 SIGPIPE 打死的三种写法
BAD_GREP='y() { some_cmd | grep -q x; }'
BAD_HEAD='z() { ls -1 | head -1; }'
BAD_READ='w() { ls -1 | read v; }'

# 好树：必须绿
printf '%s\n' "$GOOD" >"$PROBE"
out=$(run_gate) || _fail "完好的树应该通过门禁，实际输出：$out"

# 坏树 1：grep -q 提前退出
printf '%s\n' "$BAD_GREP" >"$PROBE"
out=$(run_gate) && _fail "出现会提前退出的 grep -q 时门禁必须红"
case "$out" in
  *SIGPIPE*) ;;
  *) _fail "门禁没有说明是 SIGPIPE 的问题：$out" ;;
esac

# 坏树 2：head 提前退出
printf '%s\n' "$BAD_HEAD" >"$PROBE"
out=$(run_gate) && _fail "出现会提前退出的 head 时门禁必须红"

# 坏树 3：read 只读一行就退出
printf '%s\n' "$BAD_READ" >"$PROBE"
out=$(run_gate) && _fail "出现会提前退出的 read 时门禁必须红"

# 门禁自己坏了必须报错：扫描目标没了，不能当成「没有违规」
printf '%s\n' "$GOOD" >"$PROBE"
mv "$FAKE/lib/core" "$FAKE/lib/core.gone"
out=$(run_gate) && _fail "扫描目标不存在时门禁必须红（不能静默放行）"
mv "$FAKE/lib/core.gone" "$FAKE/lib/core"

# 修好之后必须重新变绿
out=$(run_gate) || _fail "修好之后应该重新通过，实际输出：$out"
