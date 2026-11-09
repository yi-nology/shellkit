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
