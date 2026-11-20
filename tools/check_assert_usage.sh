#!/usr/bin/env bash
#
# 门禁：断言不许把提示文案当成被测命令的参数。
#
# 为什么需要这道门：assert_true / assert_false 把**全部**参数交给被测命令
# （它们的约定是：只能传命令，不能带说明文案）。于是
#
#     assert_false test -e "$p" "the rejected project must not be created"
#
# 实际执行的是 test -e <路径> "说明文案" ⇒ test 报
# 「binary operator expected」并退出 **2**（非 0）⇒ assert_false 看到
# 「失败」就**通过**了 ⇒ 这条断言从头到尾没有判据能力：
# 目录真的被创建出来时，它照样绿。
#
# 这不是理论风险：2026-11-20 在 CI 日志里顺出来一条真的
# （tests/test_scaffold.sh），它在 Linux 上一直绿，而日志里一直有一行
# test 的报错 —— 没人看。
#
# 规则（只看 test / [ 的参数个数与位置，不猜值）：
#   剥掉前导的 ! 之后：
#     1 个参数   → 合法（一元表达式或字符串）
#     2 个参数   → 第 1 个必须以 - 开头（一元运算符，如 -e / -f / -d）
#     3 个参数   → 第 2 个必须是二元运算符
#                  （= != == -eq -ne -lt -le -gt -ge -ef -nt -ot -a -o）
#     4 个以上   → 非法（bash 的 test 最多接受 3 个操作数）
#   不满足 ⇒ 点名文件与行号，退出码 5。
#
# 为什么不改 assert_true / assert_false 的语义（那才是根因）：
#   helper 随包分发（install-self 与 tarball 都带 tests/），改它的语义
#   等于改**用户工程**里那条断言的结果 —— 那属于对外行为变更，得走
#   minor + 迁移表。而「仓库自己别再写出这种断言」是仓库内部纪律，
#   用一道门禁钉住就够了。
#
#   bash tools/check_assert_usage.sh   # 0 合格；5 不合格
set -u

# SHELLKIT_CHECK_ROOT 只给自测用：在一棵假的树副本上跑本门禁。
if [ -n "${SHELLKIT_CHECK_ROOT:-}" ]; then
  ROOT="$SHELLKIT_CHECK_ROOT"
else
  ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)
fi

__files=()
for __f in "$ROOT"/tests/*.sh "$ROOT"/templates/tests/*.sh "$ROOT"/examples/*/tests/*.sh; do
  [ -f "$__f" ] || continue
  __files+=("$__f")
done

if [ "${#__files[@]}" -eq 0 ]; then
  printf 'check_assert_usage: no test file found under %s\n' "$ROOT" >&2
  exit 1
fi

__out=$(awk '
function is_binop(s) {
  return (s == "=" || s == "==" || s == "!=" || s == "-eq" || s == "-ne" ||
          s == "-lt" || s == "-le" || s == "-gt" || s == "-ge" || s == "-ef" ||
          s == "-nt" || s == "-ot" || s == "-a" || s == "-o")
}
# tok_split —— 引号感知的切分
# 为什么不能按空白切：说明文案里通常带空格 ⇒ 一条参数会被切成好几段，
# 参数个数就数错了 —— 判据失灵还不报错。
function tok_split(s, arr,   i, n, c, cur, inq, len) {
  n = 0; cur = ""; inq = ""; len = length(s); i = 1
  while (i <= len) {
    c = substr(s, i, 1)
    if (inq != "") {
      if (c == inq) inq = ""
      else cur = cur c
      i++
      continue
    }
    if (c == "\"" || c == sprintf("%c", 39)) { inq = c; i++; continue }
    if (c == " " || c == "\t") {
      if (cur != "") { n++; arr[n] = cur; cur = "" }
      i++
      continue
    }
    cur = cur c
    i++
  }
  if (cur != "") { n++; arr[n] = cur }
  return n
}
{
  line = $0
  if (line ~ /^[ \t]*#/) next
  if (line !~ /^[ \t]*assert_(true|false)[ \t]+/) next
  rest = line
  sub(/^[ \t]*assert_(true|false)[ \t]+/, "", rest)
  nt = tok_split(rest, T)
  if (nt < 1) next
  cmd = T[1]
  if (cmd != "test" && cmd != "[") next
  m = 0
  for (i = 2; i <= nt; i++) {
    if (cmd == "[" && i == nt && T[i] == "]") continue
    m++
    A[m] = T[i]
  }
  if (m > 0 && A[1] == "!") {
    for (i = 2; i <= m; i++) A[i - 1] = A[i]
    m--
  }
  if (m <= 1) next
  bad = 0
  if (m == 2) {
    if (A[1] !~ /^-/) bad = 1
  } else if (m == 3) {
    if (!is_binop(A[2])) bad = 1
  } else {
    bad = 1
  }
  if (bad == 1) printf "%s:%d: %s\n", FILENAME, FNR, line
}
' "${__files[@]}" 2>&1)
__rc=$?
if [ "$__rc" -ne 0 ]; then
  printf 'check_assert_usage: the scan failed\n' >&2
  exit 1
fi

if [ -n "$__out" ]; then
  printf '%s\n' "$__out" >&2
  printf 'check_assert_usage: an assertion passes prose to test/[ as an argument\n' >&2
  printf 'check_assert_usage: assert_true / assert_false give EVERY argument to the command\n' >&2
  printf 'check_assert_usage: use assert_eq / assert_contains, or write the check yourself\n' >&2
  exit 5
fi

printf 'check_assert_usage: ok (%d files)\n' "${#__files[@]}"
exit 0
