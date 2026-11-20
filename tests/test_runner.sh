#!/usr/bin/env bash
#
# 测试执行器自身的测试。
#
# 为什么要有这个文件：tests/run.sh 是整条门禁的地基，它一坏，全仓库的
# 「绿」都不可信。而它以前没有任何测试 —— TAP/JUnit/并行这些能力都是
# 新加的，加完没有回归保护。
#
# 测法：把真的 tests/run.sh 复制到一个临时「假仓库」里（假仓库的
# tests/ 目录里放几个受控的假测试文件），然后对这个副本跑各种选项，
# 检查它的输出与退出码。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

d=$(tmpdir)
fake="$d/fake"
mkdir -p "$fake/tests" || _fail "mkdir failed"

# 真的执行器（根目录由脚本自身位置推导，所以复制到哪它就跑哪）
cp "$TEST_ROOT/tests/run.sh" "$fake/tests/run.sh" || _fail "copy run.sh failed"

# ---- 受控的假测试文件 ----
# 一个全过
cat >"$fake/tests/test_aaa_ok.sh" <<'EOF'
#!/usr/bin/env bash
echo "aaa ran"
exit 0
EOF

# 一个失败，失败原因走 stderr 的 FAIL: 行
cat >"$fake/tests/test_bbb_fail.sh" <<'EOF'
#!/usr/bin/env bash
echo "bbb ran" >&2
echo "FAIL: bbb exploded" >&2
exit 1
EOF

# 一个带 CASE 标记的：第一个用例过，第二个挂
cat >"$fake/tests/test_ccc_cases.sh" <<'EOF'
#!/usr/bin/env bash
# CASE: alpha passes
echo "alpha"
# CASE: beta fails
echo "FAIL: beta exploded" >&2
exit 1
EOF

# test_helper.sh 必须被排除（它是断言库，不是测试）
cat >"$fake/tests/test_helper.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

# 这个包装器就是用来透传参数的，shellcheck 看不到调用点
# shellcheck disable=SC2120
run_fake() {
  bash "$fake/tests/run.sh" "$@" </dev/null 2>&1
}

# ---------------------------------------------------------------------------
# 默认（plain + 串行）：行为必须与旧版一致
# ---------------------------------------------------------------------------
out=$(run_fake)
rc=$?
assert_ne "0" "$rc" "the fake suite must fail when one of its files fails"
assert_contains "$out" "==> test_aaa_ok.sh" "plain output keeps the file banner"
assert_contains "$out" "FAILED: test_bbb_fail.sh" "plain output names the failed file"
assert_contains "$out" "aaa ran" "plain output keeps the passing file's output"

# ---------------------------------------------------------------------------
# --list：只列不跑
# ---------------------------------------------------------------------------
out=$(bash "$fake/tests/run.sh" --list </dev/null 2>&1)
assert_eq "0" "$?" "--list must succeed"
assert_contains "$out" "test_aaa_ok.sh"
assert_contains "$out" "test_bbb_fail.sh"
assert_not_contains "$out" "aaa ran" "--list must not run the tests"
assert_not_contains "$out" "test_helper.sh" "--list must exclude test_helper.sh"

# ---------------------------------------------------------------------------
# --filter：只跑匹配的文件
# ---------------------------------------------------------------------------
out=$(bash "$fake/tests/run.sh" --filter '*aaa*' </dev/null 2>&1)
assert_eq "0" "$?" "a filtered run of a passing file must succeed"
assert_contains "$out" "aaa ran"
assert_not_contains "$out" "bbb ran" "--filter must exclude the other files"

# ---------------------------------------------------------------------------
# TAP：失败必须表现为 not ok，且计划行与实际条数一致
# ---------------------------------------------------------------------------
tap=$(bash "$fake/tests/run.sh" --format tap </dev/null 2>&1)
tap_rc=$?
assert_ne "0" "$tap_rc" "tap format must exit non-zero when a file fails"
assert_contains "$tap" "TAP version 13" "tap output declares the protocol version"
assert_contains "$tap" "not ok" "tap output must mark the failed case as not ok"
assert_contains "$tap" "1.." "tap output must carry a plan line"

plan=$(printf '%s\n' "$tap" | sed -n 's/^1\.\.\([0-9][0-9]*\)$/\1/p' | tail -1)
counted=$(printf '%s\n' "$tap" | grep -cE '^(ok|not ok) [0-9]+ - ')
assert_eq "$plan" "$counted" "the TAP plan line must match the number of reported cases"
assert_ne "0" "$plan" "the TAP plan must not be empty"

# TAP 里不能出现协议外的行。曾经 _markers_of 把用例标记直接打到 stdout，
# 报告里就多出「12\t某个用例名」这种行 —— TAP 解析器会当场报错。
stray=$(printf '%s\n' "$tap" | grep -vcE '^(TAP version [0-9]+|ok [0-9]+ - .*|not ok [0-9]+ - .*|#.*|1\.\.[0-9]+)$' || true)
assert_eq "0" "$stray" "the TAP report must not contain lines outside the protocol"

# 失败的原因要能看出来，不能只说「失败了」
assert_contains "$tap" "bbb exploded" "tap output carries the failure reason"

# ---------------------------------------------------------------------------
# JUnit：必须是合法 XML，失败数与实际一致
# ---------------------------------------------------------------------------
xml=$(bash "$fake/tests/run.sh" --format junit </dev/null 2>&1)
xml_rc=$?
assert_ne "0" "$xml_rc" "junit format must exit non-zero when a file fails"
assert_contains "$xml" "<testsuites>" "junit output has the root element"
assert_contains "$xml" "<failure" "junit output must carry a failure element"

if command -v python3 >/dev/null 2>&1; then
  printf '%s\n' "$xml" >"$d/junit.xml"
  if python3 -c 'import sys,xml.etree.ElementTree as ET; ET.parse(sys.argv[1])' "$d/junit.xml" >/dev/null 2>&1; then
    parsed=1
  else
    parsed=0
  fi
  assert_eq "1" "$parsed" "junit output must be parseable XML"

  reported=$(python3 -c 'import sys,xml.etree.ElementTree as ET
r=ET.parse(sys.argv[1]).getroot()
s=r.find("testsuite")
print(s.get("failures"))' "$d/junit.xml" 2>/dev/null || echo "?")
  assert_ne "0" "$reported" "the junit failure count must not be zero when a file failed"
  assert_ne "?" "$reported" "the junit failure count must be readable"

  total=$(python3 -c 'import sys,xml.etree.ElementTree as ET
r=ET.parse(sys.argv[1]).getroot()
s=r.find("testsuite")
print(s.get("tests"))' "$d/junit.xml" 2>/dev/null || echo "?")
  assert_ne "?" "$total" "the junit test count must be readable"
  assert_ne "0" "$total" "the junit test count must not be zero"
fi

# ---------------------------------------------------------------------------
# 绝不允许「有失败但报告说全过」
# ---------------------------------------------------------------------------
# 三种格式都要满足：退出码非 0，且报告里明确出现失败
for fmt in plain tap junit; do
  out=$(bash "$fake/tests/run.sh" --format "$fmt" </dev/null 2>&1)
  rc=$?
  assert_ne "0" "$rc" "format $fmt must exit non-zero when a test file fails"
  case "$fmt" in
    plain) assert_contains "$out" "FAILED:" "plain must report the failure" ;;
    tap) assert_contains "$out" "not ok" "tap must report the failure" ;;
    junit) assert_contains "$out" "<failure" "junit must report the failure" ;;
  esac
done

# ---------------------------------------------------------------------------
# 全过时：三种格式都必须说全过、退出码 0
# ---------------------------------------------------------------------------
allok="$d/allok"
mkdir -p "$allok/tests" || _fail "mkdir failed"
cp "$TEST_ROOT/tests/run.sh" "$allok/tests/run.sh" || _fail "copy failed"
cat >"$allok/tests/test_only.sh" <<'EOF'
#!/usr/bin/env bash
echo "fine"
exit 0
EOF
for fmt in plain tap junit; do
  out=$(bash "$allok/tests/run.sh" --format "$fmt" </dev/null 2>&1)
  rc=$?
  assert_eq "0" "$rc" "format $fmt must exit zero when everything passes"
  case "$fmt" in
    tap)
      assert_contains "$out" "ok 1 - " "tap must mark the passing case as ok"
      assert_not_contains "$out" "not ok" "tap must not report a failure when everything passes"
      ;;
    junit)
      assert_not_contains "$out" "<failure" "junit must not report a failure when everything passes"
      ;;
  esac
done

# ---------------------------------------------------------------------------
# --jobs N：并行下失败照样要被抓到，而且不能互相踩目录
# ---------------------------------------------------------------------------
out=$(bash "$fake/tests/run.sh" --jobs 4 </dev/null 2>&1)
rc=$?
assert_ne "0" "$rc" "a parallel run must exit non-zero when a file fails"
assert_contains "$out" "FAILED: test_bbb_fail.sh" "a parallel run must name the failed file"

# 并行隔离：两个文件各写各的 TEST_TMP_ROOT，互相不能覆盖
iso="$d/iso"
mkdir -p "$iso/tests" || _fail "mkdir failed"
cp "$TEST_ROOT/tests/run.sh" "$iso/tests/run.sh" || _fail "copy failed"
for n in one two; do
  cat >"$iso/tests/test_iso_$n.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$TEST_TMP_ROOT" > "\$TEST_TMP_ROOT/where_$n.txt"
sleep 1
exit 0
EOF
done
out=$(bash "$iso/tests/run.sh" --jobs 2 </dev/null 2>&1)
assert_eq "0" "$?" "the isolation fixture must pass"
assert_contains "$out" "All 2 test files passed." "parallel run counts every file"

# ---------------------------------------------------------------------------
# 用法错：退出码 2
# ---------------------------------------------------------------------------
rc=0
bash "$fake/tests/run.sh" --format nope </dev/null >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "an unknown --format must be a usage error"

rc=0
bash "$fake/tests/run.sh" --jobs 0 </dev/null >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "--jobs 0 must be a usage error"

rc=0
bash "$fake/tests/run.sh" --format </dev/null >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "--format without a value must be a usage error"

rc=0
bash "$fake/tests/run.sh" --bogus </dev/null >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "an unknown option must be a usage error"

# ---------------------------------------------------------------------------
# CASE 标记：失败要落到具体用例上
# ---------------------------------------------------------------------------
tap=$(bash "$fake/tests/run.sh" --format tap --filter '*ccc*' </dev/null 2>&1)
assert_contains "$tap" "beta fails" "the failing CASE must appear in the tap output"
assert_contains "$tap" "not ok" "a failing CASE must be reported as not ok"

# ---------------------------------------------------------------------------
# 过滤器一个都没匹配上：必须报错，不能报「All 0 test files passed.」
#
# 这是典型的假绿：用户以为跑了一组测试，其实一个都没跑，报告却显示全过。
# 退出码 2（用法错），并把可用的测试文件列出来，省得用户去猜 glob 写法。
# ---------------------------------------------------------------------------
rc=0
out=$(bash "$fake/tests/run.sh" --filter 'no_such_file_*' </dev/null 2>&1) || rc=$?
assert_eq "2" "$rc" "a filter that matches nothing must be a usage error"
assert_not_contains "$out" "All 0 test files passed." "a filter that matches nothing must not report success"
assert_contains "$out" "test_aaa_ok.sh" "the error must list the available test files"

# ---------------------------------------------------------------------------
# 并行模式必须保留默认的信号处置
#
# 后台作业默认继承 SIGINT/SIGQUIT 的**忽略**状态（POSIX：非 job control 的
# shell 启动的后台进程把这两个信号置成忽略）⇒ 子 shell 里 trap INT 不生效
# ⇒ 凡是测信号处理的用例在并行模式下必然假红（实测 test_trap.sh 并行必挂、
# 串行必过 —— 假红比不跑更坏：它让人以为库坏了）。
#
# 这里用一条只测「能不能 trap INT」的受控用例把这件事钉住：并行跑它必须过。
# ---------------------------------------------------------------------------
sig="$d/sig"
mkdir -p "$sig/tests" || _fail "mkdir failed"
cp "$TEST_ROOT/tests/run.sh" "$sig/tests/run.sh" || _fail "copy failed"
cat >"$sig/tests/test_sig_int.sh" <<'FIXTURE'
#!/usr/bin/env bash
# 能不能 trap INT？被内核置成忽略时（后台作业的默认情形）这条退出 1。
handler='printf "got-int\n"'
out=$(bash -c 'trap "$1" INT; kill -INT $$; sleep 2' _ "$handler" 2>/dev/null)
case "$out" in
  *got-int*) exit 0 ;;
  *) exit 1 ;;
esac
FIXTURE
rc=0
out=$(bash "$sig/tests/run.sh" --jobs 2 </dev/null 2>&1) || rc=$?
assert_eq "0" "$rc" "a parallel run must not break signal handling inside the test files"
assert_not_contains "$out" "FAILED: test_sig_int.sh" \
  "the signal fixture must pass in parallel mode"

# ---------------------------------------------------------------------------
# CASE: 单文件预算（# TEST_TIMEOUT: N）必须被真的执行
#
# 背景：门禁跑在共享机器上。机器一慢，「重但确定」的文件就撞上全局 300 秒
# ⇒ 「机器慢」被误读成「测试坏了」—— 随机红灯很快就会被忽略，连「真的坏了」
# 都看不见。机制早就有（文件头写一行「# TEST_TIMEOUT: 900」单独放宽），
# 但没人盯着它 —— 这里把它钉住：
#   1. 声明了 1 秒的文件必须**真的**在 1 秒左右被掐掉（不是 300 秒）；
#   2. 超时文案必须报**这个文件自己的**预算（1s），不能报全局的 300s。
#      报全局会让人去改全局 —— 全局一改，所有文件的卡死检测都跟着变慢。
# ---------------------------------------------------------------------------
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  slow="$d/slow"
  mkdir -p "$slow/tests" || _fail "mkdir failed"
  cp "$TEST_ROOT/tests/run.sh" "$slow/tests/run.sh" || _fail "copy failed"
  # fixture 的声明行**拼出来**写，不写成本文件里的一行字面量：
  # 否则下面那条「声明集合」扫描会把这个 fixture 也算进去（自指）。
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '# TEST_TIMEOUT: %s —— 这个文件自己的预算：1 秒。\n' 1
    printf '%s\n' '# 睡 30 秒：预算生效的话，1 秒左右就被掐掉。' 'exec sleep 30'
  } >"$slow/tests/test_slow_budget.sh"
  t0=$SECONDS
  rc=0
  out=$(bash "$slow/tests/run.sh" --format tap --filter '*slow_budget*' </dev/null 2>&1) || rc=$?
  elapsed=$((SECONDS - t0))
  assert_ne "0" "$rc" "a file that exceeds its own budget must fail"
  assert_contains "$out" "timed out after 1s" \
    "the timeout reason must report the file's own budget"
  assert_not_contains "$out" "timed out after 300s" \
    "the timeout reason must not report the global budget"
  if [ "$elapsed" -ge 20 ]; then
    _fail "the per-file budget must be enforced (a 1s budget took ${elapsed}s)"
  fi

  # ── 变异自证：把文案改回「报全局预算」⇒ 判据必须报出来 ─────────────
  # 判据自己先证明「它抓得住回退」：改坏的 runner 必须让上面那条断言变红。
  mut="$d/mut"
  mkdir -p "$mut/tests" || _fail "mkdir failed"
  cp "$slow/tests/run.sh" "$mut/tests/run.sh" || _fail "copy failed"
  cp "$slow/tests/test_slow_budget.sh" "$mut/tests/test_slow_budget.sh" || _fail "copy failed"
  # ⚠️ 正则里不要用 \{ / \}:mawk(Debian/CI 的 awk)不认它 ⇒ awk 直接报错
  # ⇒ 文件原封不动 ⇒ 变异没发生 ⇒「变异自证」变成一句空话。
  awk '
    /msg="timed out after .*the default budget/ {
      print "      msg=\"timed out after ${TEST_TIMEOUT}s\""
      next
    }
    /msg="timed out after .*own budget/ { next }
    { print }
  ' "$mut/tests/run.sh" >"$mut/tests/run.new" && mv "$mut/tests/run.new" "$mut/tests/run.sh"
  if cmp -s "$mut/tests/run.sh" "$slow/tests/run.sh"; then
    _fail "the mutation must actually change the runner"
  fi
  # 变异必须产生**预期的形状**：mawk 会把字符串里的 \$ 原样留着 ⇒ 变异出的是
  # 字面量 \${TEST_TIMEOUT} ⇒ bash 不展开 ⇒ 测的就不是「报全局预算」这件事了。
  case "$(cat "$mut/tests/run.sh")" in
    *'msg="timed out after ${TEST_TIMEOUT}s"'*) ;;
    *) _fail "the mutation must report the global budget" ;;
  esac
  mutout=$(bash "$mut/tests/run.sh" --format tap --filter '*slow_budget*' </dev/null 2>&1) || true
  case "$mutout" in
    *"timed out after 1s"*)
      _fail "the mutation (report the global budget) must break the per-file budget check"
      ;;
  esac
else
  printf 'skip: no timeout(1) on this machine; the per-file budget is not enforced here\n' >&2
fi

# ---------------------------------------------------------------------------
# CASE: 全局默认预算不得低于 300 秒
#
# 300 是「慢但没坏」的底线。再往下压，正常机器上也会随机红灯 ——
# 随机红灯会被忽略，连真的红灯都看不见了。
# ---------------------------------------------------------------------------
# ⚠️ 正则里不要用 \{ / \}:mawk(Debian/CI 的 awk)不认它 ⇒ awk 报错 ⇒
# 读不到默认预算（Linux 上的假红就是这么来的）。改成不含花括号的等价写法。
default_budget=$(awk '/^TEST_TIMEOUT="\$/ {
    line = $0
    sub(/^TEST_TIMEOUT="/, "", line)
    sub(/"$/, "", line)
    n = line
    sub(/^.*:-/, "", n)
    sub(/[^0-9].*$/, "", n)
    print n
    exit
  }' "$TEST_ROOT/tests/run.sh")
case "$default_budget" in
  '' | *[!0-9]*) _fail "cannot read the default TEST_TIMEOUT from tests/run.sh" ;;
esac
if [ "$default_budget" -lt 300 ]; then
  _fail "the default TEST_TIMEOUT must not drop below 300s (got ${default_budget}s)"
fi

# ---------------------------------------------------------------------------
# CASE: 声明了「自己预算」的文件必须登记在册
#
# 不许静默扩大：每放宽一个文件，都要有人知道、有人认。
# 登记在下面的名单里；新增一个声明却忘了登记 ⇒ 这里红。
# 顺带守住上限：预算再大也不能没边（卡死的文件要能被发现）。
# ---------------------------------------------------------------------------
declared=$(awk '
  /^# TEST_TIMEOUT: *[0-9]/ && !seen[FILENAME] {
    line = $0
    sub(/^# TEST_TIMEOUT: */, "", line)
    sub(/[^0-9].*$/, "", line)
    name = FILENAME
    sub(/.*\//, "", name)
    print name " " line
    seen[FILENAME] = 1
  }
' "$TEST_ROOT"/tests/test_*.sh | LC_ALL=C sort)
expected_budgets="test_api_stability.sh 360
test_coverage_branch.sh 900
test_fault.sh 300
test_fault_matrix.sh 900
test_install.sh 900
test_install_lifecycle.sh 900
test_meta_gates.sh 900
test_mutation.sh 900
test_upgrade_crash.sh 900"
assert_eq "$expected_budgets" "$declared" \
  "every file with its own timeout budget must be registered in the list above"

too_big=$(printf '%s\n' "$declared" | awk '$2 > 1800 { print }')
assert_eq "" "$too_big" "no test file may declare a budget above 1800s"
