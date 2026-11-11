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
. "$TEST_ROOT/lib/bootstrap.sh"

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
# 断**完整文案**，不只断 "symlink" 这个词 —— 输出里的路径也算输出：
# 工程路径里带 "symlink" 时（比如 /home/x/symlink-demo/），单词断言会被路径
# 白送，恒真 ⇒ 这条守卫就失去了判据能力，而且不会报错。
assert_contains "$out" "the target is a symlink" "a symlinked target must be reported, not silently written"
# 再断结构事实：链接没被换成普通文件、还指着原来那个地方
assert_true [ -L "$p3/README.md" ]
assert_eq "$outside3" "$(readlink "$p3/README.md")" "the symlink must still point where it did"
assert_not_exists "$outside3" "the upgrade must not create a file outside the project directory"

# ---------------------------------------------------------------- 目标指向工程外的既有文件
p4="$work/keepout"
mk_project "$p4" "tool"
outside4="$work/keepme"
printf 'ORIGINAL CONTENT\n' >"$outside4"
ln -s "$outside4" "$p4/README.md"
out=$("$TEST_ROOT/shellkit" upgrade --force "$p4" --template "$tpl" 2>&1)
assert_contains "$out" "the target is a symlink" "even --force must not write through a symlink"
assert_true [ -L "$p4/README.md" ]
assert_eq "$outside4" "$(readlink "$p4/README.md")" "even --force must not replace the symlink itself"
assert_eq "ORIGINAL CONTENT" "$(cat "$outside4")" "the file outside the project must stay untouched"

# ---------------------------------------------------------------- vendor 目录是符号链接
p6="$work/vendorsym"
mk_project "$p6" "tool"
mkdir -p "$work/outside-vendor"
ln -s "$work/outside-vendor" "$p6/vendor"
rc=0
out=$("$TEST_ROOT/shellkit" vendor "$p6" 2>&1) || rc=$?
assert_ne "0" "$rc" "a symlinked vendor directory must be refused"
assert_contains "$out" "the vendor directory is a symlink" "the refusal must say what is wrong"
assert_not_exists "$work/outside-vendor/shellkit" "the vendor install must not write outside the project directory"

# ---------------------------------------------------------------- vendor/shellkit 是符号链接
p7="$work/vendorsym2"
mk_project "$p7" "tool"
mkdir -p "$p7/vendor" "$work/outside-vendor2"
# 软链必须指向一个「看起来像 vendor」的目录 —— 否则会被更早的一道通用守卫
# （「这个目录不是 shellkit 的 vendor」）先拦掉，压根走不到符号链接那一支，
# 这条用例就测不到它想测的那个保护了（它防的是 rm -rf 顺着链接删到工程外）。
printf '0.12.0\n' >"$work/outside-vendor2/VERSION"
printf 'MARKER\n' >"$work/outside-vendor2/marker.txt"
ln -s "$work/outside-vendor2" "$p7/vendor/shellkit"
rc=0
out=$("$TEST_ROOT/shellkit" vendor "$p7" 2>&1) || rc=$?
assert_ne "0" "$rc" "a symlinked vendored library must be refused"
assert_contains "$out" "the vendored library is a symlink" "the refusal must say what is wrong"
assert_eq "MARKER" "$(cat "$work/outside-vendor2/marker.txt")" "the directory the symlink points at must stay untouched"
assert_not_exists "$work/outside-vendor2/lib" "the vendor install must not write outside the project directory"

# ---------------------------------------------------------------- 正常工程不受影响
p5="$work/normal"
mk_project "$p5" "tool"
out=$("$TEST_ROOT/shellkit" upgrade "$p5" --template "$tpl" 2>&1)
assert_contains "$out" "upgrade finished" "a normal project must still upgrade"
assert_exists "$p5/README.md" "a normal project must still get its files"

# ---------------------------------------------------------------- 工程里已经有子目录
# _sk_upgrade_in_dir 的「目标在工程子目录」分支（"$base"/*）平时走不到：
# 守卫工程是「只有清单」的空壳，目标文件的父目录都不存在，判定停在上一层的
# 「父目录正好等于工程目录」分支上。给工程放一个已存在的子目录，判定才会落到
# 子目录这一支 —— 这一支一旦被变异（return 0 变 return 1），升级会误判成
# 「要写到工程外」而整个失败。
p8="$work/withsub"
mk_project "$p8" "tool"
mkdir -p "$p8/tests"
printf 'MINE\n' >"$p8/tests/keep.txt"
out=$("$TEST_ROOT/shellkit" upgrade "$p8" --template "$tpl" 2>&1)
assert_contains "$out" "upgrade finished" "a project that already has a subdirectory must still upgrade"
assert_true test -f "$p8/tests/keep.txt"
assert_exists "$p8/tests/run.sh" "the files under the existing subdirectory must still be written"

# ---------------------------------------------------------------- 相对路径里的 .. 组件
# _sk_upgrade_rel_safe 的 */../* 分支是防御纵深：名字校验先拦掉了 name 带 .. / 的
# 情况，文件列表又只来自模板自有清单 —— CLI 路径当前到不了这一支。但它是
# 「清单不可信」的最后一道闸，必须有判据（变异测试发现这里一打就活）。
# 函数在 shellkit 里、不在库里，从源码抽出直接钉住：
eval "$(sed -n '/^_sk_upgrade_rel_safe()/,/^}/p' "$TEST_ROOT/shellkit")"
assert_false _sk_upgrade_rel_safe "../evil"
assert_false _sk_upgrade_rel_safe "a/../../evil"
assert_false _sk_upgrade_rel_safe "a/../b"
assert_false _sk_upgrade_rel_safe "/etc/passwd"
assert_false _sk_upgrade_rel_safe ""
assert_true _sk_upgrade_rel_safe "bin/tool"
assert_true _sk_upgrade_rel_safe "x..y/file"

# ---------------------------------------------------------------- _sk_upgrade_in_dir 的空参数防御
# 同一个手法抽函数出来直接钉住：两个参数任一为空都必须判「不在目录内」。
# 这一支的判定是 [ -z "$__base" ] || [ -z "$__tgt" ] —— 把 || 变异成 && 之后，
# 「base 为空、target 非空」就会漏过空参数检查，一路走到 case 分支，
# 最终把空 base 拼成的模式当通配符放行。
eval "$(sed -n '/^_sk_upgrade_in_dir()/,/^}/p' "$TEST_ROOT/shellkit")"
# 基准目录要用物理路径：函数内部比的是 `pwd -P` 的结果，
# macOS 上 /var 是 /private/var 的软链，拿逻辑路径去比会永远判「不在目录内」。
phys=$(cd "$work" && pwd -P)
assert_false _sk_upgrade_in_dir "" "$phys/x"
assert_false _sk_upgrade_in_dir "$phys" ""
assert_true _sk_upgrade_in_dir "$phys" "$phys/x"
assert_true _sk_upgrade_in_dir "$phys" "$phys/x/y"

exit 0
