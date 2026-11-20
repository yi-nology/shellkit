#!/usr/bin/env bash
# 分支覆盖工具（tools/coverage.sh --branch）的自证测试。
#
# 每条判据都带负对照（造坏 ⇒ 必须变红；不变红 ⇒ 这条用例没有判据能力）：
#   1) 机制与四层口径：迷你树跑 --branch，报告必须有 enumerated / hit /
#      skipped / whitelist 四个数、paths 四行路径数字、skipped 与 whitelist
#      明细；已覆盖的臂绝不进白名单。
#   2) 棘轮规则一：未覆盖臂不在基线 ⇒ 红并点名。
#   3) 棘轮规则二：已覆盖臂留在基线 ⇒ 红并点名（覆盖回退不许被白名单掩盖）。
#   4) 棘轮规则三：基线里是已不存在的臂 ⇒ 红并点名（名单腐烂）。
#   5) 正对照：基线 = 当前未覆盖集合 ⇒ 绿。
#   6) 守卫机制：命中臂守卫绿；未覆盖臂的守卫即使基线齐全也红；子串匹配不上也红。
#   7) 真库快跑（test_str 套件）：报告格式、四条路径数字、--out 与 stdout
#      一致；第二遍用 /bin/bash 起工具（macOS 上即 3.2 解析执行）+ 正对照基线。
#   8) 被打断的运行不留半截基线（SIGTERM ⇒ 退出时清掉临时文件）。
#   9) 未覆盖集合超过上限 ⇒ 拒绝重写基线（且不留临时文件）。
#  10) 树里有巨型残留 ⇒ 开跑前就拒绝（不是拷贝到一半才 ENOSPC）。
#
# 断言纪律：断完整文案不断单词；临时目录名只用编号；SHELLKIT_LANG=en 由
# test_helper.sh 统一设置。
#
# TEST_TIMEOUT: 900 —— 这个文件要造几十棵变异树、每棵都跑一遍守卫套件：
# 实测 macOS 上 155 秒（Linux 20 秒）⇒ 慢机器上直接撞全局 300 秒上限 ⇒
# 「机器慢」被误读成「测试坏了」。只放宽这一个文件（全局一改，所有文件的
# 卡死检测都跟着变慢）。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

TOOL="$TEST_ROOT/tools/coverage.sh"
COV_TIMEOUT=240

# _cov_run OUTVAR ARGS... —— 跑覆盖率工具，退出码写进 OUTVAR，
# stdout 进 $COV_STDOUT、stderr 进 $COV_STDERR。
_cov_run() {
  local __outvar=$1
  shift
  local __tool="${COV_TOOL:-$TOOL}"
  local __rc=0
  _cov_out="$TEST_TMP_ROOT/cov.stdout"
  _cov_err="$TEST_TMP_ROOT/cov.stderr"
  if command -v timeout >/dev/null 2>&1; then
    timeout "$COV_TIMEOUT" bash "$__tool" "$@" >"$_cov_out" 2>"$_cov_err" </dev/null || __rc=$?
  else
    bash "$__tool" "$@" >"$_cov_out" 2>"$_cov_err" </dev/null || __rc=$?
  fi
  printf -v "$__outvar" '%s' "$__rc"
  COV_STDOUT="$_cov_out"
  COV_STDERR="$_cov_err"
  return 0
}

# _cov_run_bash OUTVAR INTERP ARGS... —— 指定解释器跑工具（/bin/bash = 3.2 基线）
_cov_run_bash() {
  local __outvar=$1 __interp=$2
  shift 2
  local __rc=0
  _cov_out="$TEST_TMP_ROOT/cov.stdout"
  _cov_err="$TEST_TMP_ROOT/cov.stderr"
  if command -v timeout >/dev/null 2>&1; then
    timeout "$COV_TIMEOUT" "$__interp" "$TOOL" "$@" >"$_cov_out" 2>"$_cov_err" </dev/null || __rc=$?
  else
    "$__interp" "$TOOL" "$@" >"$_cov_out" 2>"$_cov_err" </dev/null || __rc=$?
  fi
  printf -v "$__outvar" '%s' "$__rc"
  COV_STDOUT="$_cov_out"
  COV_STDERR="$_cov_err"
  return 0
}

# _cov_tree DIR —— 造迷你树：if 双臂、case 双臂、|| 守卫臂各一类。
_cov_tree() {
  local dir=$1
  mkdir -p "$dir/lib/core" "$dir/tests" || return 1

  cat >"$dir/lib/core/i18n.sh" <<'I18N'
#!/usr/bin/env bash
# 假 i18n：__cov_hit 的注入落点（modules.txt 的第一个模块）。
I18N

  cat >"$dir/lib/core/mini.sh" <<'MINI'
#!/usr/bin/env bash
# 迷你库：if 双臂、case 双臂、|| 守卫臂各一。
mini_alpha() {
  if [ -n "${1:-}" ]; then
    printf 'a\n'
  else
    printf 'b\n'
  fi
}

mini_beta() {
  case "${1:-}" in
    ok) printf 'ok\n' ;;
    *) printf 'no\n' ;;
  esac
}

mini_guard() {
  [ -n "${1:-}" ] || return 1
  return 0
}
MINI

  cat >"$dir/tests/run.sh" <<'SUITE'
#!/usr/bin/env bash
# 迷你套件：只走 mini_alpha 的 then 臂与 mini_guard 的守卫臂。
# mini_beta 两条 case 臂、mini_alpha 的 else 臂一次都碰不到。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/core/i18n.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/core/mini.sh"
mini_alpha x >/dev/null
if mini_guard ok; then :; fi
if ! mini_guard ""; then :; fi
SUITE
  return 0
}

# _cov_whitelist OUT FILE —— 从报告里抽 whitelist 段（跳过段头，逐条写 FILE）
_cov_whitelist() {
  awk '/^whitelist /{f=1; next} /^excluded:/{f=0} f && /^  /{sub(/^  /,""); print}' "$1" >"$2"
  return 0
}

# -------------------------------------------------------------------------
# CASE 1：机制 + 四层口径（空基线 ⇒ 规则一红，报告必须四层齐全）
# -------------------------------------------------------------------------
d=$(tmpdir) || _fail "cannot create tmpdir"
_cov_tree "$d" || _fail "cannot build the mini tree"
base="$d/base"

rc=0
_cov_run rc --branch --root "$d" --suite 'bash tests/run.sh' --guards '' --baseline "$base"
assert_ne "0" "$rc" "an empty baseline must violate the ratchet (rule 1)"
err=$(cat "$COV_STDERR")
assert_contains "$err" "branch not in the baseline: lib/core/mini.sh:mini_alpha:2" \
  "the ratchet must name the uncovered else arm"

out=$(cat "$COV_STDOUT")
hl=$(printf '%s\n' "$out" | awk '/^branch coverage:/{print; exit}')
assert_contains "$hl" "enumerated " "the headline must state the enumerated count"
assert_contains "$hl" "hit " "the headline must state the hit count"
assert_contains "$hl" "skipped " "the headline must state the skipped count"
assert_contains "$hl" "whitelist " "the headline must state the whitelist count"

n=$(printf '%s\n' "$hl" | sed -n 's/.*enumerated \([0-9][0-9]*\).*/\1/p')
w=$(printf '%s\n' "$hl" | sed -n 's/.*whitelist \([0-9][0-9]*\).*/\1/p')
case "$n" in '' | *[!0-9]*) _fail "enumerated is not a number: <$n>" ;; esac
case "$w" in '' | *[!0-9]*) _fail "whitelist is not a number: <$w>" ;; esac
if [ "$n" -lt 4 ]; then
  _fail "the mini tree must enumerate at least 4 arms, got $n"
fi
assert_eq "3" "$w" "exactly the three unhit mini arms belong to the whitelist"

assert_contains "$out" "paths:" "the report must carry the path section"
for __p in Upgrade Install Skill Repair; do
  assert_contains "$out" "  $__p: " "the path section must list $__p"
done
assert_contains "$out" "whitelist 3:" "the whitelist section must be listed"
assert_contains "$out" "lib/core/mini.sh:mini_beta:1" "the uncovered case arm must be named"
assert_not_contains "$out" "lib/core/mini.sh:mini_alpha:1" \
  "the covered then arm must never be listed as uncovered"

# -------------------------------------------------------------------------
# CASE 2：正对照 —— 基线 = 当前未覆盖集合 ⇒ 绿
#
# 基线用 --write-baseline 生成：这样它带得上环境指纹（os/arch/jq/python3），
# 守卫才有东西可比 —— 手搓的白名单没有指纹，只能走「守卫不生效」那条路。
# -------------------------------------------------------------------------
rc=0
_cov_run rc --branch --root "$d" --suite 'bash tests/run.sh' --guards '' --baseline "$base" --write-baseline
assert_eq "0" "$rc" "writing the baseline must succeed"
[ -s "$base" ] || _fail "the written baseline must not be empty"

# 报告里的白名单与写出来的基线必须一致（内容，不含指纹那一行）
_cov_whitelist "$COV_STDOUT" "$base.arms"
grep -v '^# ' "$base" >"$base.arms2" || true
assert_eq "$(cat "$base.arms")" "$(cat "$base.arms2")" \
  "the written baseline must list exactly the arms the report calls uncovered"

# 基线必须记下生成环境（环境守卫靠它）
assert_contains "$(cat "$base")" "# 生成环境: os=" \
  "the written baseline must record the environment fingerprint"

rc=0
_cov_run rc --branch --root "$d" --suite 'bash tests/run.sh' --guards '' --baseline "$base"
assert_eq "0" "$rc" "the ratchet must pass once the baseline lists exactly the uncovered arms"

# -------------------------------------------------------------------------
# CASE 3：规则二 —— 已覆盖臂留在基线 ⇒ 红（防覆盖回退被掩盖）
# -------------------------------------------------------------------------
printf '%s\n' "lib/core/mini.sh:mini_alpha:1" >>"$base"
rc=0
_cov_run rc --branch --root "$d" --suite 'bash tests/run.sh' --guards '' --baseline "$base"
assert_ne "0" "$rc" "a covered arm left in the baseline must fail the ratchet (rule 2)"
err=$(cat "$COV_STDERR")
assert_contains "$err" "the baseline lists a covered branch: lib/core/mini.sh:mini_alpha:1" \
  "rule 2 must name the stale entry"

# 还原
grep -vx 'lib/core/mini.sh:mini_alpha:1' "$base" >"$base.clean" || true
mv "$base.clean" "$base"

# -------------------------------------------------------------------------
# CASE 4：规则三 —— 基线里是已不存在的臂 ⇒ 红（名单腐烂）
# -------------------------------------------------------------------------
printf '%s\n' "lib/core/mini.sh:mini_ghost:1" >>"$base"
rc=0
_cov_run rc --branch --root "$d" --suite 'bash tests/run.sh' --guards '' --baseline "$base"
assert_ne "0" "$rc" "a baseline entry that no longer exists must fail the ratchet (rule 3)"
err=$(cat "$COV_STDERR")
assert_contains "$err" "the baseline lists a branch that no longer exists: lib/core/mini.sh:mini_ghost:1" \
  "rule 3 must name the dead entry"
grep -vx 'lib/core/mini.sh:mini_ghost:1' "$base" >"$base.clean" || true
mv "$base.clean" "$base"

# -------------------------------------------------------------------------
# CASE 5：守卫 —— 未覆盖臂的守卫即使基线齐全也红（白名单救不了）
# -------------------------------------------------------------------------
guards="$d/guards"
# 子串同时匹配 then 臂（已覆盖）与 else 臂（未覆盖）⇒ else 未命中必须红
printf '%s\n' 'G1|lib/core/mini.sh|mini_alpha|[ -n "${1:-}" ]' >"$guards"
rc=0
_cov_run rc --branch --root "$d" --suite 'bash tests/run.sh' --guards "$guards" --baseline "$base"
assert_ne "0" "$rc" "a guard arm that is not hit must fail even with a complete baseline"
err=$(cat "$COV_STDERR")
assert_contains "$err" "guard branch not hit: [G1] lib/core/mini.sh:mini_alpha:2" \
  "the guard violation must name the missed arm"

# -------------------------------------------------------------------------
# CASE 6：守卫 —— 只指向命中臂 ⇒ 绿
# -------------------------------------------------------------------------
printf '%s\n' 'G2|lib/core/mini.sh|mini_guard|return 1' >"$guards"
rc=0
_cov_run rc --branch --root "$d" --suite 'bash tests/run.sh' --guards "$guards" --baseline "$base"
assert_eq "0" "$rc" "a guard over a hit arm must pass"

# -------------------------------------------------------------------------
# CASE 7：守卫 —— 子串在全宇宙里匹配不上 ⇒ 红并点名
# -------------------------------------------------------------------------
printf '%s\n' 'G3|lib/core/mini.sh|mini_alpha|no-such-substring' >"$guards"
rc=0
_cov_run rc --branch --root "$d" --suite 'bash tests/run.sh' --guards "$guards" --baseline "$base"
assert_ne "0" "$rc" "a guard that matches no branch must fail"
err=$(cat "$COV_STDERR")
assert_contains "$err" "guard has no matching branch: [G3] lib/core/mini.sh:mini_alpha" \
  "the unmatched guard must be named"

# -------------------------------------------------------------------------
# CASE 8：真库快跑 —— 报告格式 + 四条路径数字 + --out 一致；
# 第二遍用 /bin/bash 起工具（macOS 上就是 3.2 在解析执行），基线齐全 ⇒ 绿
# -------------------------------------------------------------------------
rb="$TEST_TMP_ROOT/rb.base"
rout="$TEST_TMP_ROOT/rb.report"

rc=0
_cov_run rc --branch --suite 'bash tests/test_str.sh' --guards '' --baseline "$rb" --out "$rout"
assert_eq "1" "$rc" "on the real tree an empty baseline must violate the ratchet"
out=$(cat "$COV_STDOUT")
assert_contains "$out" "branch coverage: enumerated " "the real report must carry the headline"
for __p in Upgrade Install Skill Repair; do
  assert_contains "$out" "  $__p: " "the real report must list the $__p path"
done
assert_contains "$out" "guards:" "the real report must carry the guards section"
assert_contains "$out" "(disabled)" "guards must be reported as disabled when --guards is empty"
assert_contains "$out" "skipped " "the real report must list skipped sites"
[ -f "$rout" ] || _fail "--out was not written"
assert_eq "$out" "$(cat "$rout")" "the --out file must carry the same report as stdout"

_cov_whitelist "$COV_STDOUT" "$rb"
[ -s "$rb" ] || _fail "the real-tree whitelist must not be empty"

rc=0
_cov_run_bash rc /bin/bash --branch --suite 'bash tests/test_str.sh' --guards '' --baseline "$rb"
assert_eq "0" "$rc" "the tool must pass under /bin/bash with a complete baseline"

# -------------------------------------------------------------------------
# CASE 9：环境指纹 —— 基线是在别的环境生成的 ⇒ 门禁必须立刻红并点名
#
# 「未覆盖」是**运行时**结论：装了 jq 走 jq 臂、没装走 python3 臂；Linux 与
# macOS 走的也不是同一条臂 ⇒ 跨环境的基线与当前环境不可比（#143 的 http.sh
# 臂、#145 的 retry 臂都栽在这上面）。指纹对不上时，红的原因必须一眼看出
# 是「环境不同」而不是「代码坏了」—— 所以要能指出是哪个维度对不上。
# -------------------------------------------------------------------------
bad="$d/base.badenv"
__orig=$(cat "$base")
case "$__orig" in
  *'jq=yes'*) __bad=${__orig/jq=yes/jq=never} ;;
  *'jq=no'*) __bad=${__orig/jq=no/jq=never} ;;
  *) _fail "the baseline must record the jq dimension" ;;
esac
printf '%s\n' "$__bad" >"$bad"
assert_ne "$__orig" "$__bad" "the mismatched baseline must differ from the original"

rc=0
_cov_run rc --branch --root "$d" --suite 'bash tests/run.sh' --guards '' --baseline "$bad"
assert_eq "5" "$rc" "a baseline generated in another environment must fail the gate"
err=$(cat "$COV_STDERR")
assert_contains "$err" "基线的生成环境与当前环境不一致" \
  "the mismatch must be reported as an environment difference"
assert_contains "$err" "jq" "the mismatch must name the differing dimension"

# -------------------------------------------------------------------------
# CASE 10：负对照 —— 把守卫改坏（永远放行）⇒ 这条判据就没有承重
#
# 守卫要是根本没被调用，CASE 9 也会「因为别的原因红」—— 所以这里把守卫改坏
# 再跑一遍：改坏之后必须**不再**红。不变红 ⇒ CASE 9 没有判据能力。
# -------------------------------------------------------------------------
mut="$TEST_TMP_ROOT/coverage.mutant.sh"
cp "$TOOL" "$mut" || _fail "cannot copy the tool for the mutation"
sed 's/if \[ -n "\$__cov_diff" \]; then/if false; then/' "$mut" >"$mut.tmp" || true
mv "$mut.tmp" "$mut"
if cmp -s "$TOOL" "$mut"; then
  _fail "the mutation did not change the tool (the guard anchor moved)"
fi

COV_TOOL="$mut"
rc=0
_cov_run rc --branch --root "$d" --suite 'bash tests/run.sh' --guards '' --baseline "$bad"
COV_TOOL=""
assert_ne "5" "$rc" "with the guard broken the mismatched baseline must not be rejected by it"

# -------------------------------------------------------------------------
# CASE 11：被打断的运行不留半截基线
#
# 基线是「同目录临时文件 + rename」原子替换的：临时文件必须与目标同目录，
# rename 才是原子操作。代价是：被打断的运行（Ctrl-C / kill / 磁盘写满）会把
# 半截临时文件留在**工作树里** —— 它动辄很大，被全局 gitignore 的 *.tmp 藏起来
# （git status 干净），却在「整仓拷贝」型步骤里被再拷一遍 ⇒ 磁盘写满 ⇒
# 报错现场落在别的步骤上，看起来像「用例失败」，真因是磁盘不是代码。
#
# 造法：先在基线路径旁放一个半截临时文件（模拟「上一次运行被打断」），
# 再起工具、故意 SIGTERM 它 ⇒ 工具退出时必须把它清掉。
# 负对照：去掉清理那行 ⇒ "$base.tmp" 会留下来 ⇒ 这条用例变红。
# -------------------------------------------------------------------------
d=$(tmpdir) || _fail "cannot create tmpdir"
_cov_tree "$d" || _fail "cannot build the mini tree"
base="$d/base"
: >"$base.tmp"

bash "$TOOL" --branch --root "$d" --suite 'sleep 5' --guards '' --baseline "$base" \
  >"$TEST_TMP_ROOT/term.out" 2>"$TEST_TMP_ROOT/term.err" &
__pid=$!
sleep 1
kill -TERM "$__pid" 2>/dev/null || true
wait "$__pid" 2>/dev/null || true

if [ -e "$base.tmp" ]; then
  _fail "an interrupted run must not leave its baseline temporary file in the tree: $base.tmp"
fi

# -------------------------------------------------------------------------
# CASE 12：未覆盖集合超过上限 ⇒ 拒绝重写基线
#
# 正常是几百条；上千条说明这一趟跑歪了（插桩/解析异常、locale 差异）。
# 不设上限的话，一次跑歪就能把基线写成几百 MB 的垃圾 —— 而这种垃圾会留在
# 工作树里，把别处的门禁拖成假红。
# -------------------------------------------------------------------------
d=$(tmpdir) || _fail "cannot create tmpdir"
_cov_tree "$d" || _fail "cannot build the mini tree"
base="$d/base"

rc=0
SHELLKIT_COV_MAX_UNCOVERED=0 _cov_run rc --branch --root "$d" --suite 'bash tests/run.sh' \
  --guards '' --baseline "$base" --write-baseline
assert_eq "3" "$rc" "an oversized uncovered set must abort the baseline rewrite"
err=$(cat "$COV_STDERR")
assert_contains "$err" "refusing to rewrite the baseline" \
  "the refusal must say that the baseline is not rewritten"
if [ -e "$base" ]; then
  _fail "the baseline must not be written when the uncovered set is over the limit"
fi
if [ -e "$base.tmp" ]; then
  _fail "the aborted run must not leave a baseline temporary file behind"
fi

# -------------------------------------------------------------------------
# CASE 13：树里有巨型残留 ⇒ 开跑前就拒绝
#
# 残留留在树里时，拷贝阶段会把它再拷一份 ⇒ 磁盘写满 ⇒ 报错现场落在拷贝中途，
# 看起来像「工具坏了」。先说清楚，让调用方自己清。
# -------------------------------------------------------------------------
d=$(tmpdir) || _fail "cannot create tmpdir"
_cov_tree "$d" || _fail "cannot build the mini tree"
mkdir -p "$d/tools" || _fail "cannot create the tools dir"
dd if=/dev/zero of="$d/tools/leftover.tmp" bs=1024 count=9216 2>/dev/null ||
  _fail "cannot create the leftover file"

rc=0
_cov_run rc --branch --root "$d" --suite 'bash tests/run.sh' --guards '' --baseline "$d/base"
assert_ne "0" "$rc" "the tool must refuse to run on a tree with a huge leftover"
err=$(cat "$COV_STDERR")
assert_contains "$err" "large leftover temporary file" \
  "the refusal must name the leftover as such"
assert_contains "$err" "tools/leftover.tmp" \
  "the refusal must point at the leftover file"

exit 0
