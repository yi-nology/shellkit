#!/usr/bin/env bash
# doctor 的三类检查：环境、库完整性、vendor 漂移。
# 全部离线：只跑本地 CLI，不碰网络，也不往仓库里写东西。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

# 固定成英文输出，断言才能写死文案
run_doctor() {
  env -u LANGUAGE LC_ALL=C "$@"
}

# 把 CLI 连同它自带的库复制一份，用来造「库不完整」的现场
copy_cli() {
  local __dest=$1
  mkdir -p "$__dest" || return 1
  cp -R "$TEST_ROOT/lib" "$__dest/lib" || return 1
  cp -R "$TEST_ROOT/locale" "$__dest/locale" || return 1
  cp "$TEST_ROOT/VERSION" "$__dest/VERSION" || return 1
  cp "$TEST_ROOT/shellkit" "$__dest/shellkit" || return 1
  chmod 755 "$__dest/shellkit" || return 1
  return 0
}

work=$(tmpdir)

# CASE: 环境正常时三类检查全过，退出 0
out=$(run_doctor bash "$TEST_ROOT/shellkit" doctor 2>&1) && rc=0 || rc=$?
assert_eq 0 "$rc" "doctor exits 0 on a healthy library"
assert_contains "$out" "environment check" "the environment section is printed"
assert_contains "$out" "library integrity" "the library integrity section is printed"
assert_contains "$out" "vendor check" "the vendor section is printed"

# CASE: 模块文件缺失 —— 退出 5，且点名少了哪个模块
broken="$work/broken"
copy_cli "$broken" || _fail "cannot copy the CLI"
mv "$broken/lib/core/http.sh" "$broken/http.sh.moved"
out=$(run_doctor bash "$broken/shellkit" doctor 2>&1) && rc=0 || rc=$?
assert_eq 5 "$rc" "a missing module file is a verification failure"
assert_contains "$out" "http" "the missing module is named"

# CASE: 模块文件是空的 —— 退出 5
empty="$work/empty"
copy_cli "$empty" || _fail "cannot copy the CLI"
: >"$empty/lib/core/retry.sh"
out=$(run_doctor bash "$empty/shellkit" doctor 2>&1) && rc=0 || rc=$?
assert_eq 5 "$rc" "an empty module file is a verification failure"
assert_contains "$out" "retry" "the empty module is named"

# CASE: 模块文件语法坏了 —— 退出 5
badsyn="$work/bad-syntax"
copy_cli "$badsyn" || _fail "cannot copy the CLI"
printf 'if then fi\n' >"$badsyn/lib/core/lock.sh"
out=$(run_doctor bash "$badsyn/shellkit" doctor 2>&1) && rc=0 || rc=$?
assert_eq 5 "$rc" "a broken module file is a verification failure"
assert_contains "$out" "lock" "the broken module is named"

# CASE: vendor 与 CLI 一致 —— 退出 0
proj="$work/proj"
mkdir -p "$proj"
"$TEST_ROOT/shellkit" vendor "$proj" >/dev/null 2>&1 || _fail "vendor failed"
out=$(run_doctor bash "$TEST_ROOT/shellkit" doctor --dir "$proj" 2>&1) && rc=0 || rc=$?
assert_eq 0 "$rc" "an in-sync vendor copy passes"

# CASE: vendor 漂移 —— 退出 5，且点名漂移的文件
printf '# drift\n' >>"$proj/vendor/shellkit/lib/core/log.sh"
out=$(run_doctor bash "$TEST_ROOT/shellkit" doctor --dir "$proj" 2>&1) && rc=0 || rc=$?
assert_eq 5 "$rc" "a drifted vendor copy is a verification failure"
assert_contains "$out" "lib/core/log.sh" "the drifted file is named"

# CASE: 不用 --dir 时看当前目录里的 vendor
out=$(cd "$proj" && run_doctor bash "$TEST_ROOT/shellkit" doctor 2>&1) && rc=0 || rc=$?
assert_eq 5 "$rc" "the current directory is checked for a vendor copy"
assert_contains "$out" "lib/core/log.sh" "the drifted file is named"

# CASE: vendor 路径不是目录 —— 退出 5
notdir="$work/notdir"
mkdir -p "$notdir/vendor"
: >"$notdir/vendor/shellkit"
out=$(run_doctor bash "$TEST_ROOT/shellkit" doctor --dir "$notdir" 2>&1) && rc=0 || rc=$?
assert_eq 5 "$rc" "a vendor path that is not a directory is a verification failure"

# CASE: 目录里没有 vendor —— 退出 0
out=$(run_doctor bash "$TEST_ROOT/shellkit" doctor --dir "$work" 2>&1) && rc=0 || rc=$?
assert_eq 0 "$rc" "a directory without a vendor copy passes"

# CASE: 用法错 —— 退出 2
out=$(run_doctor bash "$TEST_ROOT/shellkit" doctor --bogus 2>&1) && rc=0 || rc=$?
assert_eq 2 "$rc" "an unknown option is a usage error"
out=$(run_doctor bash "$TEST_ROOT/shellkit" doctor --dir 2>&1) && rc=0 || rc=$?
assert_eq 2 "$rc" "an option without a value is a usage error"

# CASE: SHELLKIT_MODULES 是「直接用库」的按需加载开关，不该影响 CLI ——
# 泄漏进来时 os 模块没加载，doctor 把 command not found 伪装成「缺工具」。
# 判据：设与不设该变量，doctor 的输出必须一字不差（issue #32）。
plain_rc=0
plain=$(run_doctor bash "$TEST_ROOT/shellkit" doctor --dir "$work" 2>&1) || plain_rc=$?
limited_rc=0
limited=$(run_doctor env SHELLKIT_MODULES="cli log fs" bash "$TEST_ROOT/shellkit" doctor --dir "$work" 2>&1) || limited_rc=$?
assert_eq "$plain_rc" "$limited_rc" "SHELLKIT_MODULES must not change doctor's exit code"
assert_not_contains "$limited" "command not found" "SHELLKIT_MODULES must not leak into the CLI"
assert_eq "$plain" "$limited" "SHELLKIT_MODULES must not change doctor's output"

# ---------- doctor --json ----------
#
# JSON 形态（issue #62）：stdout 是一份完整的 JSON 文档，字段是契约。
#
# 判据分两层：结构断言永远跑（不依赖解析器），取值断言在有 python3 时跑。
# 机器上没装解析器时测试不能变成空转 —— 所以结构断言不依赖 python3。

# jget FILE PATH —— 取 JSON 里的一个值打印出来（没有 python3 时跳过）
# jlen FILE PATH —— 取 JSON 里的一个数组/对象的长度打印出来
if command -v python3 >/dev/null 2>&1; then
  jget() {
    python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
cur = d
for k in sys.argv[2].split("."):
    cur = cur[int(k)] if k.isdigit() else cur[k]
print(cur)' "$1" "$2"
  }
  jlen() {
    python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
cur = d
for k in sys.argv[2].split("."):
    cur = cur[int(k)] if k.isdigit() else cur[k]
print(len(cur))' "$1" "$2"
  }
else
  jget() {
    printf 'skip: no python3, the JSON value assertions are not run\n' >&2
    return 1
  }
  jlen() {
    printf 'skip: no python3, the JSON value assertions are not run\n' >&2
    return 1
  }
fi

# CASE: --json 的 stdout 只有一份 JSON 文档，stderr 干净
jout="$work/doctor.json"
run_doctor bash "$TEST_ROOT/shellkit" doctor --json >"$jout" 2>"$work/doctor.err" && rc=0 || rc=$?
assert_eq 0 "$rc" "doctor --json exits 0 on a healthy library"
assert_eq "" "$(cat "$work/doctor.err")" "doctor --json writes nothing to stderr"
assert_eq "{" "$(head -c 1 "$jout")" "the JSON report starts with an object"
assert_eq "}" "$(tail -c 2 "$jout" | head -c 1)" "the JSON report ends with an object"

# CASE: JSON 形态里没有混进文本形态的小节标题
assert_not_contains "$(cat "$jout")" "environment check" "the JSON report does not mix in the text section titles"

# CASE: 文本形态与 JSON 形态看到的是同一批检查 —— 少一条就说明有一边漏了
text_out="$(run_doctor bash "$TEST_ROOT/shellkit" doctor 2>/dev/null)"
text_rows="$(printf '%s\n' "$text_out" | grep -cE '^  [A-Z]+ +')"
json_rows=$(($(jlen "$jout" dependencies) + $(jlen "$jout" checks)))
assert_eq "$text_rows" "$json_rows" "the text and JSON forms report the same number of rows"

# CASE: 字段取值 —— schema / 退出码 / 模块清单
assert_eq "shellkit.doctor.v1" "$(jget "$jout" schema)" "the schema identifier is stable"
assert_eq "0" "$(jget "$jout" result.exit_code)" "the JSON exit code matches the command exit code"
assert_eq "False" "$(jget "$jout" result.verify_failed)" "a healthy library has no verification failure"
manifest_n="$(awk '{ sub(/#.*/, ""); if (NF > 0) print $1 }' "$TEST_ROOT/lib/modules.txt" | wc -l | tr -d ' ')"
assert_eq "$manifest_n" "$(jget "$jout" modules.count)" "the module count matches lib/modules.txt"
assert_eq "$manifest_n" "$(jget "$jout" modules.loadable)" "every manifest module is loadable on a healthy library"
assert_eq "$manifest_n" "$(jlen "$jout" modules.listed)" "the listed module array covers the manifest"
assert_eq "0" "$(jget "$jout" result.missing_required)" "nothing required is missing on a healthy library"

# CASE: 库不完整 —— 退出码与文本形态一致（5），JSON 里点出缺哪个模块
run_doctor bash "$broken/shellkit" doctor --json >"$work/broken.json" 2>/dev/null && rc=0 || rc=$?
assert_eq 5 "$rc" "doctor --json exits 5 when a module file is missing"
assert_eq "True" "$(jget "$work/broken.json" result.verify_failed)" "a missing module is a verification failure"
assert_contains "$(jget "$work/broken.json" modules.missing)" "http" "the missing module is named in the report"

# CASE: 缺可选依赖只是降级 —— 退出码仍是 0，必需/可选分开报
#
# PATH 必须是**受控的**（#72）：原来拿 /usr/bin:/bin 当「受限 PATH」，判据
# 实际读的是 Runner 预装了什么 —— Ubuntu 的 /usr/bin 里 shellcheck/xgettext/curl
# 都在，只缺 shfmt，missing_optional=1 ⇒ 本机 ≥2、CI 恒红。
# 现在自己搭一个目录：只放**必需工具与跑 doctor 所需的基础命令**，
# 可选的一个都不放 ⇒ 与机器预装无关。
depdir="$work/deppath"
mkdir -p "$depdir" || _fail "cannot build the controlled PATH directory"
for __c in bash sh sha256sum shasum awk sed cat grep tr sort head tail wc dirname basename uname mktemp find env printf; do
  __p=$(command -v "$__c" 2>/dev/null) || continue
  ln -s "$__p" "$depdir/$__c" 2>/dev/null || true
done
run_doctor env PATH="$depdir" bash "$TEST_ROOT/shellkit" doctor --json >"$work/min.json" 2>/dev/null && rc=0 || rc=$?
assert_eq 0 "$rc" "missing optional tooling does not fail the check"
assert_eq "0" "$(jget "$work/min.json" result.missing_required)" "optional tooling is not counted as required"
opt_n="$(jget "$work/min.json" result.missing_optional)"
if [ "$opt_n" -lt 2 ]; then
  _fail "expected the optional dependencies to be reported missing, got <$opt_n>"
fi
assert_contains "$(jget "$work/min.json" dependencies)" "'required': True" "required dependencies are flagged as required"
assert_contains "$(jget "$work/min.json" dependencies)" "'required': False" "optional dependencies are flagged as optional"

# CASE: 报告要能直接贴进 issue —— 值像凭据时自动脱敏
redact_dir="$work/PASSWORD=hunter2"
mkdir -p "$redact_dir"
run_doctor bash "$TEST_ROOT/shellkit" doctor --json --dir "$redact_dir" >"$work/redact.json" 2>/dev/null
assert_not_contains "$(cat "$work/redact.json")" "hunter2" "a credential in the report is masked"
assert_contains "$(jget "$work/redact.json" checks)" "PASSWORD=***" "the credential value is replaced"

# CASE: 库自己都坏了 —— 仍然给一份 JSON（贴 issue 要的就是这份）
deg="$work/degraded"
copy_cli "$deg" || _fail "cannot copy the CLI"
printf 'if then fi\n' >"$deg/lib/bootstrap.sh"
run_doctor bash "$deg/shellkit" doctor --json >"$work/degraded.json" 2>/dev/null && rc=0 || rc=$?
assert_eq 5 "$rc" "a library that cannot be loaded exits 5"
assert_eq "True" "$(jget "$work/degraded.json" result.verify_failed)" "the degraded report flags the failure"
assert_eq "shellkit.doctor.v1" "$(jget "$work/degraded.json" schema)" "the degraded report has the same schema"

# CASE: 用法错 —— 退出 2（--json 也要认得这个错）
run_doctor bash "$TEST_ROOT/shellkit" doctor --json --bogus >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq 2 "$rc" "an unknown option is a usage error"
