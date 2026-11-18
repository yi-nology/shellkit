#!/usr/bin/env bash
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

work=$(tmpdir)
proj="$work/app"

"$TEST_ROOT/shellkit" new "$proj" >/dev/null 2>&1 || _fail "shellkit new failed"

# 新生成的工程自带同步好的库
assert_exit_code 0 "$TEST_ROOT/shellkit" vendor "$proj" --check

# 库被改动后 --check 必须判红（5 = SK_VERIFY）
printf '# drift\n' >>"$proj/vendor/shellkit/lib/core/log.sh"
assert_exit_code 5 "$TEST_ROOT/shellkit" vendor "$proj" --check

# 同步**不冲掉**用户改过的文件（issue #69）：保留并告警
out=$(bash "$TEST_ROOT/shellkit" vendor "$proj" 2>&1) && rc=0 || rc=$?
assert_eq 0 "$rc" "the sync still succeeds with a locally modified file"
assert_contains "$out" "modified locally, left alone" "the local change is reported"
assert_contains "$(cat "$proj/vendor/shellkit/lib/core/log.sh")" "drift" "the local change survives the sync"
# 副本仍与库不同 ⇒ --check 仍判红（这是「副本与库不一致」的事实，不是假红）
assert_exit_code 5 "$TEST_ROOT/shellkit" vendor "$proj" --check
# --force 才覆盖；覆盖之后副本与库一致，--check 回绿
assert_exit_code 0 "$TEST_ROOT/shellkit" vendor "$proj" --force
assert_exit_code 0 "$TEST_ROOT/shellkit" vendor "$proj" --check
if grep -q 'drift' "$proj/vendor/shellkit/lib/core/log.sh"; then
  _fail "vendor --force 没有覆盖掉被改动的副本"
fi
assert_eq "$(cat "$TEST_ROOT/VERSION")" "$(cat "$proj/vendor/shellkit/VERSION")" "VERSION is synced"

# 不覆盖"看起来不是 shellkit"的同名目录
other="$work/other"
mkdir -p "$other/vendor/shellkit"
assert_exit_code 3 "$TEST_ROOT/shellkit" vendor "$other"

# 参数校验
assert_exit_code 3 "$TEST_ROOT/shellkit" vendor "$work/does-not-exist"
assert_exit_code 2 "$TEST_ROOT/shellkit" vendor

# 同步过去的库能被直接 source
got=$(
  . "$proj/vendor/shellkit/lib/bootstrap.sh"
  printf '%s' "$SK_VERSION"
)
assert_eq "$(cat "$TEST_ROOT/VERSION")" "$got" "vendored bootstrap reports the synced version"

# ---- vendor 出来的副本必须自带「管它的工具」 ----
#
# 工程被 vendor 到别的机器上时，PATH 上不一定有 shellkit。如果副本里只有库，
# 工程就永远升不了级 —— 而「升级」正是 vendor 这套机制存在的理由。
if [ ! -f "$proj/vendor/shellkit/shellkit" ]; then
  _fail "the vendored copy carries the CLI"
fi
if [ ! -d "$proj/vendor/shellkit/templates" ]; then
  _fail "the vendored copy carries the templates"
fi

# 自带的 CLI 真能跑，而且报的是副本自己的版本
vver=$(bash "$proj/vendor/shellkit/shellkit" --version 2>/dev/null || true)
assert_eq "$(cat "$TEST_ROOT/VERSION")" "$vver" "the vendored CLI runs and reports the synced version"

# 自带的 CLI 能把工程升级（离线：不依赖 PATH 上的 shellkit）
assert_exit_code 0 bash "$proj/vendor/shellkit/shellkit" upgrade "$proj"

# CLI 与模板漂移也要被 --check 抓到
printf '# drift\n' >>"$proj/vendor/shellkit/shellkit"
assert_exit_code 5 "$TEST_ROOT/shellkit" vendor "$proj" --check
# 同样：本地改动被保留 ⇒ --check 仍判红；--force 才覆盖
assert_exit_code 0 "$TEST_ROOT/shellkit" vendor "$proj" --force
assert_exit_code 0 "$TEST_ROOT/shellkit" vendor "$proj" --check

# 用工程自带的副本同步本工程（README 记载的离线升级用法）：目标就是运行源，
# 绝不允许先删后拷 —— 那会把 vendor/shellkit/{lib,locale,templates} 删空、
# 工程入口当场报废（issue #30）。--check 绿的时候，真正的同步也必须绿。
assert_exit_code 0 bash "$proj/vendor/shellkit/shellkit" vendor "$proj" --check
assert_exit_code 0 bash "$proj/vendor/shellkit/shellkit" vendor "$proj"
if [ ! -f "$proj/vendor/shellkit/lib/bootstrap.sh" ]; then
  _fail "self-sync keeps the vendored lib intact"
fi
assert_eq "$(cat "$TEST_ROOT/VERSION")" "$(cat "$proj/vendor/shellkit/VERSION")" \
  "self-sync still lands the right version"
assert_exit_code 0 bash "$proj/bin/app" --version
assert_exit_code 0 "$TEST_ROOT/shellkit" vendor "$proj" --check

# 没有所有权基线的旧副本（issue #137）：同步后版本没变 ⇒ fail-closed，不许报 OK。
# 以前这里会打「vendored library ... (当前版本)」并退出 0，实际一个文件都没换。
legacy="$work/legacy"
mkdir -p "$legacy/vendor/shellkit/lib"
printf '0.0.1\n' >"$legacy/vendor/shellkit/VERSION"
printf '# old bootstrap\n' >"$legacy/vendor/shellkit/lib/bootstrap.sh"
out=$(bash "$TEST_ROOT/shellkit" vendor "$legacy" 2>&1) && rc=0 || rc=$?
assert_eq 5 "$rc" "a legacy copy that cannot be updated must fail closed with SK_VERIFY"
assert_contains "$out" "was not updated" "the failure must say the copy was not updated"
assert_contains "$out" "ownership baseline are kept; re-run with --force to overwrite them: 2" \
  "the failure must name the number of files kept for lack of a baseline (issue #137)"
assert_contains "$out" "--force" "the failure must point at --force"
assert_eq "0.0.1" "$(cat "$legacy/vendor/shellkit/VERSION")" "nothing may be silently replaced"

# --force 是明确的覆盖通道：版本必须真的跟上，随后 --check 绿
assert_exit_code 0 "$TEST_ROOT/shellkit" vendor "$legacy" --force
assert_eq "$(cat "$TEST_ROOT/VERSION")" "$(cat "$legacy/vendor/shellkit/VERSION")" \
  "--force must land the current version"
assert_exit_code 0 "$TEST_ROOT/shellkit" vendor "$legacy" --check

# ---- 库副本落点可配置（issue #143）----
#
# 落点必须只有**一个**真相源：环境变量 > 工程配置文件 > 默认 vendor/shellkit。
# doctor / upgrade / repair.sh 三处读同一个解析结果 —— 各写各的路径字符串，
# 迟早漂：装在一个地方、查在另一个地方，是最难查的那类 bug。
#
# Go 模块仓的仓根不能放 vendor/（Go 会切 vendor 模式然后报 inconsistent
# vendoring），所以落点必须能挪走；挪走之后三处还得都跟得上。
. "$TEST_ROOT/lib/bootstrap.sh"

d2=$(tmpdir)
p1="$d2/p1"
mkdir -p "$p1"

# 默认落点
assert_eq "vendor/shellkit" "$(vendor_dir_rel "$p1")" "the default vendor location is vendor/shellkit"
assert_eq "default" "$(vendor_dir_source "$p1")" "the default location comes from the default"

# 工程配置文件：第一行有效内容（# 开头是注释）
printf '# comment line\nthird_party/shellkit\n' >"$p1/.shellkit-vendor-dir"
assert_eq "third_party/shellkit" "$(vendor_dir_rel "$p1")" "the project config file sets the location"
assert_eq "file" "$(vendor_dir_source "$p1")" "the location comes from the config file"

# 环境变量优先于配置文件
out=$(SHELLKIT_VENDOR_DIR=env_dir/shellkit vendor_dir_rel "$p1")
assert_eq "env_dir/shellkit" "$out" "the environment variable wins over the config file"
out=$(SHELLKIT_VENDOR_DIR=env_dir/shellkit vendor_dir_source "$p1")
assert_eq "env" "$out" "the location comes from the environment"

# 越界取值一律拒绝：名字会变成路径，带 .. 的取值能写到工程之外（坑 7）
out=$(SHELLKIT_VENDOR_DIR=../outside vendor_dir_rel "$p1" 2>/dev/null) && rc=0 || rc=$?
assert_eq 3 "$rc" "a location with .. is rejected"
out=$(SHELLKIT_VENDOR_DIR=/tmp/elsewhere vendor_dir_rel "$p1" 2>/dev/null) && rc=0 || rc=$?
assert_eq 3 "$rc" "a location outside the project is rejected"
out=$(SHELLKIT_VENDOR_DIR=. vendor_dir_rel "$p1" 2>/dev/null) && rc=0 || rc=$?
assert_eq 3 "$rc" "the project directory itself is not a valid location"
out=$(vendor_dir_rel "$d2/does-not-exist" 2>/dev/null) && rc=0 || rc=$?
assert_eq 3 "$rc" "a missing project directory is rejected"

# 落在工程内的绝对路径是允许的
abs_in="$p1/third_party/shellkit"
out=$(SHELLKIT_VENDOR_DIR="$abs_in" vendor_dir_rel "$p1")
assert_eq "$abs_in" "$out" "an absolute location inside the project is accepted"

# 绝对路径解析成绝对落点
# 用一个干净的目录（p1 的配置已指向 third_party），期望值取规范化路径：
# macOS 上 TMPDIR 在 /var 后面，而 pwd -P 给的是 /private/var
p0="$d2/p0"
mkdir -p "$p0"
p0abs="$(cd "$p0" && pwd -P)"
out=$(vendor_dir "$p0")
assert_eq "$p0abs/vendor/shellkit" "$out" "vendor_dir resolves to an absolute path"

# 别处的副本：doctor / vendor 靠它给出「指过来」的提示
p2="$d2/p2"
mkdir -p "$p2/third_party/shellkit/lib"
printf '# bootstrap\n' >"$p2/third_party/shellkit/lib/bootstrap.sh"
assert_eq "third_party/shellkit" "$(vendor_dir_detect "$p2")" "a copy elsewhere is detected"
out=$(vendor_dir_detect "$d2" 2>/dev/null) && rc=0 || rc=$?
assert_eq 1 "$rc" "no copy elsewhere means nothing is detected"

# ---- 生成工程：副本落在配置的位置，工程自己也要记得住 ----
p3="$d2/p3"
SHELLKIT_VENDOR_DIR=third_party/shellkit "$TEST_ROOT/shellkit" new "$p3" >/dev/null 2>&1 ||
  _fail "shellkit new failed with a custom vendor location"
if [ ! -f "$p3/third_party/shellkit/lib/bootstrap.sh" ]; then
  _fail "the copy is installed at the configured location"
fi
if [ -d "$p3/vendor" ]; then
  _fail "no default vendor/ directory may be created (Go repos break on it)"
fi
assert_eq "third_party/shellkit" "$(cat "$p3/.shellkit-vendor-dir")" "the project records its own location"
if ! grep -q 'VENDOR_DIR := third_party/shellkit' "$p3/Makefile"; then
  _fail "the generated Makefile points at the configured location"
fi
if ! grep -q 'third_party/shellkit/lib/bootstrap.sh' "$p3/bin/"*; then
  _fail "the generated entry point loads the copy from the configured location"
fi
# 生成的工程照常能跑
assert_exit_code 0 bash "$p3/bin/"* --version

# doctor 必须认出配置过的落点（issue 的头号抱怨：副本在 third_party/shellkit，
# doctor 却说「没有副本」）
out=$("$TEST_ROOT/shellkit" doctor --dir "$p3" 2>&1) && rc=0 || rc=$?
assert_eq 0 "$rc" "doctor succeeds on a project with a configured location"
assert_contains "$out" "vendor copy matches the bundled library" "doctor finds the copy at the configured location"

# ---- 副本在别处、而没配置：必须拒绝，而不是静默新建一份 ----
p4="$d2/p4"
"$TEST_ROOT/shellkit" new "$p4" >/dev/null 2>&1 || _fail "shellkit new failed"
mkdir -p "$p4/third_party"
mv "$p4/vendor/shellkit" "$p4/third_party/shellkit"
rmdir "$p4/vendor" 2>/dev/null || true
out=$("$TEST_ROOT/shellkit" vendor "$p4" 2>&1) && rc=0 || rc=$?
assert_eq 3 "$rc" "vendor refuses to create a second copy somewhere else"
assert_contains "$out" "at a different location" "the refusal says where the copy actually is"
assert_contains "$out" "SHELLKIT_VENDOR_DIR=third_party/shellkit" "the refusal says how to point at it"
if [ -d "$p4/vendor" ]; then
  _fail "vendor must not create a default vendor/ directory when the copy is elsewhere"
fi
out=$("$TEST_ROOT/shellkit" upgrade "$p4" 2>&1) && rc=0 || rc=$?
if [ "$rc" = "0" ]; then
  _fail "upgrade must not silently create a second copy"
fi
if [ -d "$p4/vendor" ]; then
  _fail "upgrade must not create a default vendor/ directory when the copy is elsewhere"
fi
# doctor 对「副本在别处」要给可操作的提示，而不是一句「没找到」
# （必须在「指过去」之前查：指过去之后副本就落在配置的位置上了）
out=$("$TEST_ROOT/shellkit" doctor --dir "$p4" 2>&1) && rc=0 || rc=$?
assert_contains "$out" "third_party/shellkit" "doctor reports where the copy actually is"
assert_contains "$out" "SHELLKIT_VENDOR_DIR=third_party/shellkit" "doctor says how to point at it"
# 指过去之后就能正常干活
out=$(SHELLKIT_VENDOR_DIR=third_party/shellkit "$TEST_ROOT/shellkit" upgrade "$p4" 2>&1) && rc=0 || rc=$?
assert_eq 0 "$rc" "upgrade works once the location is pointed at"
if [ -d "$p4/vendor" ]; then
  _fail "upgrade must not create a default vendor/ directory even when pointed elsewhere"
fi

# ---- 非法落点配置：doctor 判 invalid，vendor 拒绝 ----
p5="$d2/p5"
mkdir -p "$p5"
printf '/etc/evil\n' >"$p5/.shellkit-vendor-dir"
out=$("$TEST_ROOT/shellkit" vendor "$p5" 2>&1) && rc=0 || rc=$?
assert_eq 3 "$rc" "vendor refuses an illegal location"
out=$("$TEST_ROOT/shellkit" doctor --dir "$p5" 2>&1) && rc=0 || rc=$?
assert_contains "$out" "the vendored library path is invalid" "doctor reports an illegal location"

# ---- repair.sh 必须认得新落点 ----
# 用 --prefix 指到临时目录：绝不碰本机真装了的那份
p6="$d2/p6"
SHELLKIT_VENDOR_DIR=third_party/shellkit "$TEST_ROOT/shellkit" new "$p6" >/dev/null 2>&1 ||
  _fail "shellkit new failed"
mkdir -p "$p6/third_party/.shellkit-new"
printf 'residue\n' >"$p6/third_party/.shellkit-new/leftover"
"$TEST_ROOT/repair.sh" --prefix "$d2/prefix" --project "$p6" >/dev/null 2>&1 ||
  _fail "repair.sh failed on a project with a configured location"
if [ -d "$p6/third_party/.shellkit-new" ]; then
  _fail "repair.sh cleans the residue at the configured location"
fi
# 非法落点 ⇒ fail-closed：什么都不删，并且明确报错
p7="$d2/p7"
mkdir -p "$p7"
printf '../outside\n' >"$p7/.shellkit-vendor-dir"
out=$("$TEST_ROOT/repair.sh" --prefix "$d2/prefix" --project "$p7" 2>&1) && rc=0 || rc=$?
assert_eq 1 "$rc" "repair.sh fails closed on an illegal location"
assert_contains "$out" "invalid library copy location" "repair.sh says why it refused"

# ---- 副本里少一个文件时，同步必须把它补上（#143 的回归）----
#
# 背景：上游新增了模块，旧副本里还没有 ⇒ 算摘要时 sha256sum 遇到缺失的
# 文件会退非零。**曾经把整张摘要表丢掉** ⇒ 每个文件都判成「用户改过」
# ⇒ 同步静默变成空操作：副本的 VERSION 永远停在旧版本，退出码还是 0。
#
# 判据要能承重，所以副本被做成两件事：
#   1. VERSION 伪装成旧版本（基线同步改掉 ⇒ 判成「还是我们装的原文」）；
#   2. 少一个文件（上游新增模块、旧副本没有）。
# 只断退出码不够 —— 那个缺陷的退出码一直是 0。
sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    openssl dgst -sha256 "$1" | awk '{print $NF}'
  fi
}
p8="$d2/p8"
"$TEST_ROOT/shellkit" new "$p8" >/dev/null 2>&1 || _fail "shellkit new failed"
printf '0.0.1\n' >"$p8/vendor/shellkit/VERSION"
mf="$p8/vendor/shellkit/.shellkit-vendor-manifest"
news="$(sha_of "$p8/vendor/shellkit/VERSION")"
awk -F'\t' -v OFS='\t' -v s="$news" '$1=="VERSION" && !d {print $1, s; d=1; next} {print}' \
  "$mf" >"$mf.new" || _fail "cannot rewrite the ownership manifest"
mv "$mf.new" "$mf"
rm -f "$p8/vendor/shellkit/lib/core/log.sh"
out=$("$TEST_ROOT/shellkit" vendor "$p8" 2>&1) && rc=0 || rc=$?
assert_eq 0 "$rc" "a copy with a missing file must still sync"
assert_true test -f "$p8/vendor/shellkit/lib/core/log.sh"
assert_eq "$(cat "$TEST_ROOT/VERSION")" "$(cat "$p8/vendor/shellkit/VERSION")" \
  "the copy must reach the current version even when a file was missing"
