#!/usr/bin/env bash
# upgrade 的路径安全回归。
#
# 这里守的是一条底线：**升级不写工程目录之外的任何地方**。
#
# 两条越界路径都是真踩过的：
#   1) 清单里的 name 带着 ../ —— 名字会被拼进 bin/<name>，直接落到工程外
#   2) 目标文件是符号链接 —— cp 会顺着链接写穿，把内容写到工程外
#
# 两条都是静默的：退出码 0，日志里看不出来。所以只能靠断言盯住。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

work=$(tmpdir)
tpl="$work/tpl"
cp -R "$TEST_ROOT/templates" "$tpl"

# assert_exists / assert_not_exists —— 带提示文案的存在性断言
#
# 不用 assert_true test -f ...：那个把提示文案也当成 test 的参数传进去，
# test 会拿它当二元运算符而报错。
assert_exists() {
  if [ ! -e "$1" ]; then
    _fail "$2: <$1> does not exist"
  fi
  return 0
}

assert_not_exists() {
  if [ -e "$1" ]; then
    _fail "$2: <$1> exists"
  fi
  return 0
}

# mk_project DIR NAME —— 造一个只有清单的工程（够升级用，不必跑 new）
mk_project() {
  local d=$1 name=$2
  mkdir -p "$d" || _fail "mkdir failed: $d"
  cat >"$d/.shellkit-manifest" <<EOF
# shellkit manifest v1
manifest_version=2
version=0.11.0
template_version=0.11.0
name=$name
commands=run
EOF
}

# ---------------------------------------------------------------- 清单里的名字带 ../
p1="$work/badname"
mk_project "$p1" "../../escape"
rc=0
out=$("$TEST_ROOT/shellkit" upgrade "$p1" --template "$tpl" 2>&1) || rc=$?
assert_ne "0" "$rc" "a project name that escapes the directory must be rejected"
assert_contains "$out" "not a valid name" "the rejection must say what is wrong"
assert_not_exists "$work/escape" "the upgrade must not write outside the project directory"

# 名字里带路径分隔符同样不行
p2="$work/slashname"
mk_project "$p2" "sub/tool"
rc=0
out=$("$TEST_ROOT/shellkit" upgrade "$p2" --template "$tpl" 2>&1) || rc=$?
assert_ne "0" "$rc" "a project name with a path separator must be rejected"
assert_not_exists "$p2/sub" "the upgrade must not create directories outside the template layout"

# ---------------------------------------------------------------- 目标是悬空的符号链接
p3="$work/dangling"
mk_project "$p3" "tool"
outside3="$work/created-outside"
ln -s "$outside3" "$p3/README.md"
out=$("$TEST_ROOT/shellkit" upgrade "$p3" --template "$tpl" 2>&1)
assert_contains "$out" "symlink" "a symlinked target must be reported, not silently written"
assert_not_exists "$outside3" "the upgrade must not create a file outside the project directory"

# ---------------------------------------------------------------- 目标指向工程外的既有文件
p4="$work/keepout"
mk_project "$p4" "tool"
outside4="$work/keepme"
printf 'ORIGINAL CONTENT\n' >"$outside4"
ln -s "$outside4" "$p4/README.md"
out=$("$TEST_ROOT/shellkit" upgrade --force "$p4" --template "$tpl" 2>&1)
assert_contains "$out" "symlink" "even --force must not write through a symlink"
assert_eq "ORIGINAL CONTENT" "$(cat "$outside4")" "the file outside the project must stay untouched"

# ---------------------------------------------------------------- vendor 目录是符号链接
p6="$work/vendorsym"
mk_project "$p6" "tool"
mkdir -p "$work/outside-vendor"
ln -s "$work/outside-vendor" "$p6/vendor"
rc=0
out=$("$TEST_ROOT/shellkit" vendor "$p6" 2>&1) || rc=$?
assert_ne "0" "$rc" "a symlinked vendor directory must be refused"
assert_not_exists "$work/outside-vendor/shellkit" "the vendor install must not write outside the project directory"

# ---------------------------------------------------------------- vendor/shellkit 是符号链接
p7="$work/vendorsym2"
mk_project "$p7" "tool"
mkdir -p "$p7/vendor" "$work/outside-vendor2"
ln -s "$work/outside-vendor2" "$p7/vendor/shellkit"
rc=0
out=$("$TEST_ROOT/shellkit" vendor "$p7" 2>&1) || rc=$?
assert_ne "0" "$rc" "a symlinked vendored library must be refused"
assert_not_exists "$work/outside-vendor2/lib" "the vendor install must not write outside the project directory"

# ---------------------------------------------------------------- 正常工程不受影响
p5="$work/normal"
mk_project "$p5" "tool"
out=$("$TEST_ROOT/shellkit" upgrade "$p5" --template "$tpl" 2>&1)
assert_contains "$out" "upgrade finished" "a normal project must still upgrade"
assert_exists "$p5/README.md" "a normal project must still get its files"

exit 0
