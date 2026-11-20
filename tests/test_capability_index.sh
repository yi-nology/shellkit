#!/usr/bin/env bash
#
# 能力索引的判据（issue #161）。
#
# 问题：落点表（SKILL.md 的「常见任务的落点」）只覆盖常用路径 ⇒ 边缘但真实
# 的能力（str_suggest / validate_* / parallel_map …）**找不到** ⇒ 下游工程
# 把库里已有的能力**重写一遍**。实证：两个真实工程各写了 1955 行重写层，
# 其中 str_suggest（编辑距离）shellkit 早就有，vendor 副本里也有。
#
# 解法：落点表管「常用路径」，索引（docs/CAPABILITIES.md）管「全部」。
# 本用例盯住三件事：
#   1. 索引必须**覆盖每一个**公开函数（漏一个就等于又制造了一个「找不到」）；
#   2. 索引必须进 skill 包（不进包就等于 AI 看不到）；
#   3. 变异自证：从索引里删掉一条 ⇒ 判据必须红。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

CAP="$TEST_ROOT/docs/CAPABILITIES.md"
REF="$TEST_ROOT/docs/REFERENCE.md"

[ -f "$CAP" ] || _fail "the capability index must exist (run: shellkit docs)"
[ -f "$REF" ] || _fail "the API reference must exist (run: shellkit docs)"

# ── 判据 1：索引必须覆盖每一个公开函数 ───────────────────────────────────
# 两边用同一种行首（"- "）：把参考里的标题行改成 "- xxx" 再逐条到索引里找。
# 不去动反引号：grep -F 是子串匹配，索引那一行本来就以 "- xxx" 开头。
missing=""
while IFS= read -r head; do
  [ -n "$head" ] || continue
  if ! grep -F -q -- "$head" "$CAP"; then
    missing="$missing $head"
  fi
done <<EOF
$(sed -n 's/^### /- /p' "$REF")
EOF
if [ -n "$missing" ]; then
  _fail "the capability index must list every public function; missing:$missing"
fi

# 条数也要对上：索引不能多出参考里没有的函数（那说明索引自己写飘了）
n_ref=$(grep -c '^### ' "$REF")
n_cap=$(grep -c '^- ' "$CAP")
assert_eq "$n_ref" "$n_cap" "the capability index must have exactly one line per public function"

# ── 判据 2：索引必须进 skill 包 ─────────────────────────────────────────
PACK="$TEST_ROOT/skills/shellkit/references/capabilities.md"
[ -f "$PACK" ] || _fail "the skill pack must ship the capability index"
if ! cmp -s "$CAP" "$PACK"; then
  _fail "the skill pack copy of the capability index must be byte-identical to docs/CAPABILITIES.md"
fi
assert_contains "$(cat "$TEST_ROOT/skills/shellkit/SKILL.md")" "references/capabilities.md" \
  "the skill entry must point at the capability index"

# ── 判据 3：变异自证 ───────────────────────────────────────────────────
# 从索引里删掉一条 ⇒ 判据 1 必须红。（索引要是漏了一条，这个漏就是真的）
# 模式里的点代替反引号：反引号在 shell 里是命令替换，写进模式很危险。
mut="$TEST_TMP_ROOT/cap-mutated.md"
grep -v '^- .log_info.' "$CAP" >"$mut" || _fail "cannot mutate the index"
if cmp -s "$mut" "$CAP"; then
  _fail "the mutation must actually remove a line from the index"
fi
if (
  missing=""
  while IFS= read -r head; do
    [ -n "$head" ] || continue
    if ! grep -F -q -- "$head" "$mut"; then
      missing="$missing $head"
    fi
  done <<EOF2
$(sed -n 's/^### /- /p' "$REF")
EOF2
  [ -z "$missing" ]
) >/dev/null 2>&1; then
  _fail "the coverage check must go red when the index drops a public function"
fi

exit 0
