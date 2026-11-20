#!/usr/bin/env bash
#
# check_assert_usage 的自测：门禁自己必须先证明「它抓得住」。
#
# 为什么要有这道：门禁静默失效是最难查的一类问题 —— 它不会让 CI 红，
# 只是**不再拦**那些假绿断言。判据要能证明自己没坏。
#
# 四段：
#   1. 真树上跑一遍 ⇒ 必须合格（退出 0）；
#   2. 假树上放一条坏用法 ⇒ 必须点名（退出 5，且消息里有文件与行号）；
#   3. 假树上放合法人用 ⇒ 必须**不**点名（不许误伤）；
#   4. 变异自证：把判据的运算符名单掏空 ⇒ 坏用法就抓不住了 ⇒ 必须红。
#
# ⚠ 本文件里写「坏用法」时**不许**让那一行以 assert_true / assert_false
# 开头 —— 那会被本门禁自己扫到（门禁扫的是 tests/*.sh 全部文件）。
# 所以用 printf 拼出来。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

GATE="$TEST_ROOT/tools/check_assert_usage.sh"
[ -f "$GATE" ] || _fail "the gate script must exist"

# ── 1. 真树必须合格 ─────────────────────────────────────────────────────
assert_exit_code 0 bash "$GATE"

# ── 2. 假树：坏用法必须被点名 ───────────────────────────────────────────
fake="$TEST_TMP_ROOT/fake-tree"
rm -rf "$fake"
mkdir -p "$fake/tests" "$fake/tools"
cp "$GATE" "$fake/tools/check_assert_usage.sh"

# 拼出坏用法（不落在本文件的行首 ⇒ 门禁不会扫到自己）
printf '%s %s\n' 'assert_false test -e "$p8"' '"the rejected project must not be created at all"' \
  >"$fake/tests/test_bad.sh"

out=$(SHELLKIT_CHECK_ROOT="$fake" bash "$fake/tools/check_assert_usage.sh" 2>&1)
rc=0
SHELLKIT_CHECK_ROOT="$fake" bash "$fake/tools/check_assert_usage.sh" >/dev/null 2>&1 || rc=$?
assert_eq "5" "$rc" "the gate must fail on an assertion that passes prose to test"
assert_contains "$out" "test_bad.sh" "the gate must name the offending file"

# ── 3. 假树：合法人用不得被误伤 ─────────────────────────────────────────
# 先把上一段的坏文件撤掉 —— 这一段要证明的是「合法的不被点名」，
# 坏文件还留着的话，门禁当然会红（那是第 2 段已经证明过的事）。
rm -f "$fake/tests/test_bad.sh"
cat >"$fake/tests/test_good.sh" <<'GOOD_EOF'
#!/usr/bin/env bash
assert_true test -f "$f"
assert_false test -e "$p"
assert_true test "$x" -ge 10
assert_true test ! -e "$dest/lib/lib"
assert_false test "$create_line" -lt "$verify_line"
assert_true conf_has "DB_HOST"
assert_true is_num "$__med"
assert_true [ -f "$f" ]
GOOD_EOF

rc=0
SHELLKIT_CHECK_ROOT="$fake" bash "$fake/tools/check_assert_usage.sh" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "the gate must not flag valid assertion usages"

# ── 4. 变异自证：把判据的核心（运算符名单）掏空 ⇒ 必须抓不住坏用法 ────
# 这一条证明「它抓得住」不是「它总是红」：判据本身坏掉时，用例必须红。
mut="$fake/tools/check_assert_usage_mut.sh"
# 把「第 2 个参数必须是二元运算符」这一判据整个掏空 ⇒ 坏用法就抓不住了
sed 's/if (!is_binop(A\[2\])) bad = 1/if (0) bad = 1/' "$GATE" >"$mut"
if cmp -s "$mut" "$GATE"; then
  _fail "the mutation must actually change the gate"
fi
rc=0
SHELLKIT_CHECK_ROOT="$fake" bash "$mut" >/dev/null 2>&1 || rc=$?
if [ "$rc" = "5" ]; then
  _fail "the mutated gate must NOT flag the bad usage (it lost its teeth)"
fi

exit 0
