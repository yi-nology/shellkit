#!/usr/bin/env bash
#
# 变异测试工具（tools/mutation.sh）自己的回归。
#
# 要防的是这件事：「变异工具说什么都杀死了」——工具永远报 KILLED，
# 回归网的判据能力就是一句空话。所以每条用例都带负对照：
#
#   1) 引擎必须能报 KILLED：合成目标（return 0 的函数）+ 会断言的合成
#      测试 ⇒ return 0 -> return 1 必须被杀灭，得分 100%。
#   2) SURVIVED 负对照：同一合成目标 + 什么都不断言的恒 0 测试 ⇒
#      同一变异必须报 SURVIVED，得分不达标退出 1。
#      （工具若连「跑没跑测试」都分不出来，所有 campaign 都是假绿。）
#   3) 真 campaign：对 shellkit 升级路径的守卫区跑有界变异
#      （位点由函数名锚定、数量封顶），守卫用例就是为这些缺陷写的，
#      必须 100% 杀灭。若个别变异 SURVIVED，不要强行凑分 —— 把它加进
#      --skip 白名单并在这里点名注明「该变异当前无判据」。
#   4) 位点枚举必须确定：同一份树跑两次，位点集合与顺序逐字一致。
#
# 断言纪律：断完整记录不断单词；临时目录名只用编号；SHELLKIT_LANG=en
# 由 test_helper.sh 统一设置。
#
# TEST_TIMEOUT: 900 —— 真 campaign 要把守卫套件按计分位点数跑那么多遍
# （每个位点一遍，几分钟），默认的 300 秒上限会把它掐在半路。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

MUT="$TEST_ROOT/tools/mutation.sh"

# --------------------------------------------------------------------------
# 合成小树：一个 return 0 的函数 + 两个测试（会断言的 / 恒 0 的）
# --------------------------------------------------------------------------

mut_synth_root() {
  local d=$1
  mkdir -p "$d/tests" || return 1
  cat >"$d/target.sh" <<'EOF'
#!/usr/bin/env bash
# 合成目标：一个永远成功的函数（return 0 是唯一变异位点）
probe() {
  return 0
}
EOF
  cat >"$d/tests/check.sh" <<'EOF'
#!/usr/bin/env bash
# 会断言的测试：probe 必须成功
. "$(dirname "$0")/../target.sh"
probe || exit 1
EOF
  cat >"$d/tests/noassert.sh" <<'EOF'
#!/usr/bin/env bash
# 什么都不断言，恒 0 退出 —— 任何变异都杀不掉它
exit 0
EOF
  return 0
}

# --------------------------------------------------------------------------
# 用例
# --------------------------------------------------------------------------

# CASE: 引擎自测 —— 会断言的测试必须把 return 0 -> return 1 杀灭
d=$(tmpdir) || _fail "cannot create tmpdir"
mkdir -p "$d"
mut_synth_root "$d/root" || _fail "case.1: cannot build the synthetic tree"
rc=0
out=$(bash "$MUT" --root "$d/root" --target target.sh \
  --test "bash tests/check.sh" --min-score 100 \
  --report "$d/report" 2>"$d/log") || rc=$?
assert_eq "0" "$rc" "case.1: an asserting test must reach 100% against a return-0 mutation"
assert_contains "$(cat "$d/report")" $'return\treturn 0\treturn 1\tKILLED' \
  "case.1: the return-0 site must be recorded as KILLED"
assert_contains "$out" "score: 100% (1/1 killed)" \
  "case.1: the stdout table must show the perfect score"

# CASE: SURVIVED 负对照 —— 恒 0 的空测试杀不掉任何变异，必须如实报 SURVIVED
d=$(tmpdir) || _fail "cannot create tmpdir"
mkdir -p "$d"
mut_synth_root "$d/root" || _fail "case.2: cannot build the synthetic tree"
rc=0
bash "$MUT" --root "$d/root" --target target.sh \
  --test "bash tests/noassert.sh" --min-score 100 \
  --report "$d/report" >"$d/out" 2>"$d/log" || rc=$?
assert_eq "1" "$rc" "case.2: a vacuous test must score below the minimum (exit 1)"
assert_contains "$(cat "$d/report")" $'return\treturn 0\treturn 1\tSURVIVED' \
  "case.2: the return-0 site must be recorded as SURVIVED"

# CASE: 用法错必须退 2 —— 返回码是工具接口的一部分
rc=0
bash "$MUT" --root "$d/root" --target target.sh >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "usage errors must exit 2"

# CASE: 位点枚举必须确定 —— 同一份树跑两次，集合与顺序逐字一致
. "$MUT"
# 区间锚在库里的共享守卫实现上（升级路径调的就是这份，CLI 已不再持有私有副本）：
# 实现被改名/搬走时 grep 取不到锚点，这里必须 loudly red 而不是静默换个区间。
from_line=$(grep -n '^_sk_fs_rel_safe()' "$TEST_ROOT/lib/core/fs.sh" | cut -d: -f1)
to_line=$(grep -n '^_sk_fs_no_symlink_below()' "$TEST_ROOT/lib/core/fs.sh" | cut -d: -f1)
[ -n "$from_line" ] && [ -n "$to_line" ] ||
  _fail "case.3: the shared path-guard functions are gone — update this test"
a=$(mut_enum_sites "$TEST_ROOT/lib/core/fs.sh" "$from_line" "$to_line")
b=$(mut_enum_sites "$TEST_ROOT/lib/core/fs.sh" "$from_line" "$to_line")
assert_eq "$a" "$b" "case.3: site enumeration must be deterministic across runs"
case $a in
  *$'cond'* | '') ;;
  *) _fail "case.3: the upgrade-path region must still contain cond sites" ;;
esac

# CASE: 真 campaign —— 路径守卫区的有界变异必须 100% 杀灭
#
# 位点区间锚在库里的 _sk_fs_rel_safe / _sk_fs_in_dir 上（grep 现取，实现被重构时
# loudly red），--max-sites 封顶保证跑得完。
#
# 白名单（--skip）用**内容锚点**现算行号，不用「锚点 + 偏移」——
# 偏移会随函数内容变化漂移：上一版加了行注释，白名单就悄悄指到了别的位点，
# 于是「跳过的一个无判据位点」变成「跳过了一个本来有判据的位点」，分数还是 100%。
# 取不到锚点就直接 loud red，不做静默兜底。
#   root_cond / root_ret   in_dir 循环的文件系统根出口 —— 需要父目录链走到根，守卫场景不可达
#   pwd_line:return        $(cd … && pwd -P) 的失败分支 —— 需要父目录不存在/不可执行；
#                          守卫场景的悬空符号链接在更外层被拦，走不到这里
#
# 其余位点都有判据：
#   rel_safe 的空/绝对路径分支与 .. 分支、in_dir 的空参数防御分支 ——
#     由 test_upgrade_guard.sh 末尾把函数从源码抽出来直接断言；
#   in_dir 的「目标在工程子目录」分支 ——
#     由 test_upgrade_guard.sh 里「工程里已经有子目录」那条用例走到。
root_cond=$(awk -v s="$from_line" -v e="$to_line" \
  'NR > s && NR < e && /\[ "\$__parent" = "\$__dir" \]/ { print NR; exit }' \
  "$TEST_ROOT/lib/core/fs.sh")
# 锚点只认 `pwd -P)` 这一行，不认 `|| return 1`：覆盖率分支插桩会把右臂
# 改写成 `|| __cov_hit N return 1`，跨 `||` 的字面量在这里会取不到。
pwd_line=$(awk -v s="$from_line" -v e="$to_line" \
  'NR > s && NR < e && /pwd -P\)/ { print NR; exit }' \
  "$TEST_ROOT/lib/core/fs.sh")
[ -n "$root_cond" ] && [ -n "$pwd_line" ] ||
  _fail "case.4: the whitelist anchors moved — update this test"
root_ret=$((root_cond + 1))
d=$(tmpdir) || _fail "cannot create tmpdir"
mkdir -p "$d"
rc=0
bash "$MUT" --root "$TEST_ROOT" --target lib/core/fs.sh \
  --from-line "$from_line" --to-line "$to_line" --max-sites 13 \
  --skip "$root_cond" --skip "$root_ret" --skip "$pwd_line:return" \
  --test "bash tests/test_upgrade_guard.sh" --min-score 100 \
  --report "$d/report" >"$d/out" 2>"$d/log" || rc=$?
report=$(cat "$d/report")
assert_eq "0" "$rc" "case.4: the upgrade guards must kill every counted mutation (log: $d/log)"
assert_contains "$report" "killed: 10" \
  "case.4: the campaign must score exactly 10 kills (a shifted region changes the count loudly)"
assert_contains "$report" "survived: 0" \
  "case.4: no counted mutation may survive the upgrade guards"
assert_contains "$report" "score: 100%" \
  "case.4: the campaign score must be 100% of the counted sites"

# 计分范围必须摆在明面上：得分只对计分位点负责，不许把跳过的藏起来。
assert_contains "$report" "sites enumerated: " \
  "case.4: the report must say how many sites were enumerated in the range"
assert_contains "$report" "campaign window: 13" \
  "case.4: the report must say how big the campaign window is"
assert_contains "$report" "scored: 10" \
  "case.4: the report must say how many sites were actually scored"
assert_contains "$report" "skipped: 3" \
  "case.4: the report must say how many sites the whitelist skipped"
assert_contains "$report" "skipped by the whitelist" \
  "case.4: the report must list the skipped sites one by one"
assert_contains "$(cat "$d/out")" "scope: " \
  "case.4: stdout must carry the same scope line"

exit 0
