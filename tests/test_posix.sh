#!/usr/bin/env bash
#
# POSIX 子集的判据。
#
# 两条线：
#   1. **能跑** —— POSIX 子集真的在 POSIX sh（dash）上跑得起来，行为符合约定；
#   2. **不漂** —— 能力清单与源码对得上；混进 bash 专有语法要红。
#
# 判据必须有承重：最后一节把缺陷造回去，用例必须变红 —— 否则这些断言
# 只是在测「文件存在」，测不出「设备侧能不能用」。
#
# shellcheck disable=SC2016
# 下面 _posix '...' 里的 $VAR 是**要传给 POSIX shell** 的，不是当前 shell 的。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

POSIX_LIB="$TEST_ROOT/lib/posix/shellkit-posix.sh"
CAP_FILE="$TEST_ROOT/lib/posix/capabilities.tsv"
GATE="$TEST_ROOT/tools/check_posix.sh"

work=$(tmpdir)

# 真 POSIX shell：优先 dash（最接近 POSIX），没有就退到 sh
POSIX_SH=""
if command -v dash >/dev/null 2>&1; then
  POSIX_SH=dash
elif [ -x /bin/dash ]; then
  POSIX_SH=/bin/dash
else
  POSIX_SH="sh"
fi

export SK_WORK="$work"

# _posix SCRIPT —— 在真 POSIX sh 里加载子集并跑一段脚本
_posix() {
  "$POSIX_SH" -c ". \"$POSIX_LIB\" || exit 99
$1"
}

# fake_tree DIR —— 造一棵能跑 POSIX 门禁的假树
fake_tree() {
  mkdir -p "$1/lib" || return 1
  cp -R "$TEST_ROOT/lib/core" "$1/lib/core" || return 1
  cp -R "$TEST_ROOT/lib/posix" "$1/lib/posix" || return 1
  return 0
}

# CASE: 门禁在真树上通过
assert_exit_code 0 bash "$GATE"

# CASE: POSIX sh 能解析，shellcheck 的 sh 方言没有告警
assert_exit_code 0 "$POSIX_SH" -n "$POSIX_LIB"
if command -v shellcheck >/dev/null 2>&1; then
  assert_exit_code 0 shellcheck -s sh "$POSIX_LIB"
fi

# CASE: 日志一律走 stderr，stdout 只给数据
out=$(_posix 'log_info hello-posix' 2>/dev/null)
assert_eq "" "$out" "log_info must keep stdout clean"
err=$(_posix 'log_info hello-posix' 2>&1 >/dev/null)
assert_contains "$err" "hello-posix" "log_info writes to stderr"

# CASE: retry —— 用法错（退出码 2）不重试；普通失败重试并返回最后的退出码
cat >"$work/rc2.sh" <<'RC2'
#!/bin/sh
printf 'call\n' >>"$SK_COUNTER"
exit 2
RC2
cat >"$work/rc7.sh" <<'RC7'
#!/bin/sh
printf 'call\n' >>"$SK_COUNTER"
exit 7
RC7
chmod +x "$work/rc2.sh" "$work/rc7.sh"
export SK_COUNTER="$work/counter"
export SHELLKIT_RETRY_DELAY=0

: >"$SK_COUNTER"
out=$(_posix 'retry 3 "$SK_WORK/rc2.sh"' 2>&1)
rc=$?
assert_eq 2 "$rc" "retry returns the command's exit code"
assert_eq "1" "$(grep -c '' "$SK_COUNTER")" "retry must not retry a usage error (exit 2)"

: >"$SK_COUNTER"
out=$(_posix 'retry 3 "$SK_WORK/rc7.sh"' 2>&1)
rc=$?
assert_eq 7 "$rc" "retry returns the last failure's exit code"
assert_eq "3" "$(grep -c '' "$SK_COUNTER")" "retry retries a normal failure"

# CASE: fs —— 建目录幂等；建文件不覆盖已有的
assert_exit_code 0 _posix 'fs_ensure_dir "$SK_WORK/d1"'
assert_true test -d "$work/d1"
assert_exit_code 0 _posix 'fs_ensure_dir "$SK_WORK/d1"'
assert_exit_code 0 _posix 'fs_ensure_file "$SK_WORK/f.txt" hello'
assert_eq "hello" "$(cat "$work/f.txt")"
assert_exit_code 0 _posix 'fs_ensure_file "$SK_WORK/f.txt" other'
assert_eq "hello" "$(cat "$work/f.txt")"

# CASE: net —— 摘要与校验（不一致退 5）
printf 'hello\n' >"$work/hello.txt"
SK_SUM=""
if command -v sha256sum >/dev/null 2>&1; then
  SK_SUM="$(sha256sum "$work/hello.txt" | cut -d ' ' -f1)"
elif command -v shasum >/dev/null 2>&1; then
  SK_SUM="$(shasum -a 256 "$work/hello.txt" | cut -d ' ' -f1)"
fi
if [ -n "$SK_SUM" ]; then
  export SK_SUM
  assert_exit_code 0 _posix 'net_sha256 "$SK_WORK/hello.txt"'
  assert_exit_code 0 _posix 'net_verify "$SK_WORK/hello.txt" "$SK_SUM"'
  assert_exit_code 5 _posix 'net_verify "$SK_WORK/hello.txt" 0000000000000000000000000000000000000000000000000000000000000000'
fi

# CASE: conf —— 环境变量 > 配置文件 > 默认值；非法的键名退 2
printf 'FOO=from-file\n' >"$work/conf"
export SK_CONF="$work/conf"
assert_eq "from-file" "$(_posix 'conf_init "$SK_CONF"; conf_get_any FOO default')" "the config file is read"
assert_eq "from-env" "$(env FOO=from-env "$POSIX_SH" -c ". \"$POSIX_LIB\"; conf_get_any FOO default")" "the environment wins over the file"
assert_eq "fallback" "$(_posix 'conf_get_any MISSING fallback')" "the default is used when nothing is set"
assert_exit_code 2 _posix 'conf_get_any "bad-key" default'

# CASE: ver —— 分段比较（1.2.3 < 1.10.0）
assert_eq "-1" "$(_posix 'ver_cmp 1.2.3 1.10.0')" "ver_cmp compares segments numerically"
assert_exit_code 0 _posix 'ver_gt 1.10.0 1.9.0'
assert_exit_code 0 _posix 'ver_lt 1.2.3 1.10.0'
assert_exit_code 0 _posix 'ver_eq 1.0 1.0.0'

# CASE: lock —— 拿锁建目录、放锁删目录；持有者还活着时拒绝
export SHELLKIT_LOCK_DIR="$work/locks"
mkdir -p "$SHELLKIT_LOCK_DIR"
out=$(_posix 'lock_acquire demo && ls -d "$SHELLKIT_LOCK_DIR/shellkit-demo.lock"' 2>&1)
assert_contains "$out" "shellkit-demo.lock" "lock_acquire creates the lock directory"
out=$(_posix 'lock_acquire demo; lock_release demo; test -d "$SHELLKIT_LOCK_DIR/shellkit-demo.lock" && echo STILL || echo GONE' 2>&1)
assert_contains "$out" "GONE" "lock_release removes the lock directory"
mkdir -p "$SHELLKIT_LOCK_DIR/shellkit-demo.lock"
printf '%s\n' "$$" >"$SHELLKIT_LOCK_DIR/shellkit-demo.lock/pid"
out=$(_posix 'lock_acquire demo' 2>&1)
rc=$?
assert_eq 1 "$rc" "lock_acquire refuses when another instance is alive"
assert_contains "$out" "another instance is running" "the refusal says why"
rm -rf "$SHELLKIT_LOCK_DIR"

# CASE: status —— 机器模式输出 STATE=；非法状态码退 1
out=$(env SHELLKIT_STATUS_MODE=machine "$POSIX_SH" -c ". \"$POSIX_LIB\"; status_emit installed 'is running'" 2>&1)
assert_eq "STATE=installed" "$out" "status_emit writes the machine-readable state"
assert_exit_code 0 _posix 'status_state_valid installed'
assert_exit_code 1 _posix 'status_state_valid bogus_state'

# CASE: posix_capable —— 问得到「这条设备侧有没有」
assert_exit_code 0 _posix 'posix_capable log_info'
assert_exit_code 1 _posix 'posix_capable no_such_function_xyz'

# CASE: 能力清单的结构事实
assert_true test -f "$CAP_FILE"
cap_line() {
  grep -m1 "^$1	" "$CAP_FILE" 2>/dev/null || true
}
assert_contains "$(cap_line log_info)" "yes" "log_info is available in the POSIX subset"
assert_contains "$(cap_line ask)" "no" "ask is not available in the POSIX subset"
assert_contains "$(cap_line ask)" "交互" "the reason says why ask is unavailable"
assert_contains "$(cap_line posix_capable)" "yes" "posix_capable is listed"
assert_contains "$(cap_line fs_ensure_file)" "yes" "fs_ensure_file is listed"
# 每个 no 都得写明原因（没有原因 = 设备侧没法判断能不能用）
missing_reason=""
while IFS='	' read -r __fn __has __reason; do
  case "$__fn" in
    '' | '#'*) continue ;;
  esac
  [ "$__has" = "no" ] || continue
  if [ -z "$__reason" ] || [ "$__reason" = "-" ]; then
    missing_reason="$missing_reason $__fn"
  fi
done <"$CAP_FILE"
assert_eq "" "$missing_reason" "every unavailable function says why"
# 清单里不能有重复的函数名
dupes="$(cut -f1 "$CAP_FILE" | grep -v '^#' | grep -v '^$' | sort | uniq -d)"
assert_eq "" "$dupes" "the capability list has no duplicate entries"

# CASE: 判据有承重 —— 把缺陷造回去，门禁必须变红
#
# 这一节是本用例的判据能力证明：四个缺陷，一个都跑不掉。

# M1：POSIX 子集里混进 bash 专有语法（local）⇒ 门禁必须红
t1="$work/fake1"
fake_tree "$t1" || _fail "cannot build the fake tree"
printf '\n_sk_test_bad() {\n  local __x=1\n  printf "%%s" "$__x"\n}\n' >>"$t1/lib/posix/shellkit-posix.sh"
out=$(SHELLKIT_CHECK_ROOT="$t1" bash "$GATE" 2>&1)
rc=$?
assert_eq 5 "$rc" "the gate rejects a bashism in the POSIX subset"
assert_contains "$out" "bash-only syntax" "the gate names the bashism"

# M2：能力清单少一条 ⇒ 门禁必须红
t2="$work/fake2"
fake_tree "$t2" || _fail "cannot build the fake tree"
grep -v '^ask	' "$t2/lib/posix/capabilities.tsv" >"$t2/lib/posix/capabilities.new"
mv "$t2/lib/posix/capabilities.new" "$t2/lib/posix/capabilities.tsv"
out=$(SHELLKIT_CHECK_ROOT="$t2" bash "$GATE" 2>&1)
rc=$?
assert_eq 5 "$rc" "the gate rejects a stale capability list"
assert_contains "$out" "out of date" "the gate says the list is stale"

# M3：清单声称一个不存在的函数可用 ⇒ 门禁必须红
t3="$work/fake3"
fake_tree "$t3" || _fail "cannot build the fake tree"
printf 'no_such_function_xyz\tyes\t-\n' >>"$t3/lib/posix/capabilities.tsv"
out=$(SHELLKIT_CHECK_ROOT="$t3" bash "$GATE" 2>&1)
rc=$?
assert_eq 5 "$rc" "the gate rejects a claim about a function that does not exist"
assert_contains "$out" "but the POSIX subset does not define it" "the gate names the phantom function"

# M4：清单说有的函数被从源码里删了 ⇒ 门禁必须红
t4="$work/fake4"
fake_tree "$t4" || _fail "cannot build the fake tree"
grep -v '^posix_capable() {' "$t4/lib/posix/shellkit-posix.sh" >"$t4/lib/posix/shellkit-posix.new"
mv "$t4/lib/posix/shellkit-posix.new" "$t4/lib/posix/shellkit-posix.sh"
out=$(SHELLKIT_CHECK_ROOT="$t4" bash "$GATE" 2>&1)
rc=$?
assert_eq 5 "$rc" "the gate rejects a capability the POSIX subset no longer provides"
assert_contains "$out" "posix_capable" "the gate names the missing function"

printf 'ok\n'
