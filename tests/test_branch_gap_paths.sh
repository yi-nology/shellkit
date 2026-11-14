#!/usr/bin/env bash
# 分支覆盖缺口的场景补测（路线图 v0.23.0「分支覆盖缺口收敛」）。
#
# 每组场景对应 tools/coverage_branch_baseline.txt 里真实未覆盖的分支臂 ——
# 判据看行为与输出，不看臂号（臂号会被无关改动挤跑）；臂号只用来选场景。
# 覆盖率选场景的自证：bash tools/coverage.sh --branch（CI 的 branch coverage 步骤）。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fault.sh"

work=$(tmpdir)
sk="$TEST_ROOT/shellkit"
locks="$work/locks"
mkdir -p "$locks"
export SHELLKIT_LOCK_DIR="$locks"

# assert_exists FILE MSG —— 文件/目录必须在（assert_true 只能接命令、不能接说明）
assert_exists() {
  local __f=${1:-} __msg=${2:-file is missing}
  if [ ! -e "$__f" ] && [ ! -L "$__f" ]; then
    _fail "$__msg: <$__f>"
  fi
  return 0
}

# assert_missing FILE MSG —— 文件必须已经不在
assert_missing() {
  local __f=${1:-} __msg=${2:-file should be gone}
  if [ -e "$__f" ] || [ -L "$__f" ]; then
    _fail "$__msg: <$__f>"
  fi
  return 0
}

# _sha FILE —— 文件的 sha256（与 test_install 同口径：macOS 没有 sha256sum）
_sha() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# _mkmin DIR —— 一棵最小可运行的 shellkit 树（不含 repair.sh / templates / skills）
_mkmin() {
  mkdir -p "$1"
  cp -f "$TEST_ROOT/shellkit" "$1/shellkit"
  cp -f "$TEST_ROOT/VERSION" "$1/VERSION"
  cp -R "$TEST_ROOT/lib" "$1/lib"
}

# ---------- CASE: update 带 sha256 —— 解析、带校验更新、校验失败三段都走到 ----------
# 校验在解包与版本比较**之前**：和不匹配就以 5 退出，一个字节都不落地。
printf 'not-a-tarball\n' >"$work/u1.tgz"
rc=0
err=$("$sk" update --from "$work/u1.tgz" --sha256 00 --prefix "$work/u1px" 2>&1) || rc=$?
assert_eq "5" "$rc" "a wrong checksum must fail verification with SK_VERIFY"
assert_missing "$work/u1px/share/shellkit" "nothing must land when verification fails"

# ---------- CASE: release_gate --help ----------
rc=0
out=$(bash "$TEST_ROOT/tools/release_gate.sh" --help 2>&1) || rc=$?
assert_eq "0" "$rc" "--help must exit 0"
assert_contains "$out" "release_gate" "the help must name the tool"

# ---------- CASE: release_gate 必需检查清单里的空项要被跳过（不计数也不报错） ----------
ghbin="$work/ghbin"
mkdir -p "$ghbin"
printf '#!/bin/sh\nprintf "completed/success\\n"\n' >"$ghbin/gh"
chmod +x "$ghbin/gh"
rc=0
out=$(PATH="$ghbin:$PATH" GITHUB_REPOSITORY=yi-nology/shellkit SHELLKIT_GATE_CHECKS='a||b' \
  bash "$TEST_ROOT/tools/release_gate.sh" 0123456789abcdef0123456789abcdef01234567 2>&1) || rc=$?
assert_eq "0" "$rc" "two healthy checks must pass the gate"
assert_contains "$out" "required checks: 2" "the empty list item must be skipped in the count"

# ---------- CASE: completion --install 目标目录不可写 ⇒ 原子写失败要报错 ----------
ro="$work/ro"
mkdir -p "$ro/bash-completion/completions"
chmod 555 "$ro" "$ro/bash-completion" "$ro/bash-completion/completions"
rc=0
err=$(XDG_DATA_HOME="$ro" "$sk" completion bash --install 2>&1) || rc=$?
chmod 755 "$ro" "$ro/bash-completion" "$ro/bash-completion/completions"
assert_ne "0" "$rc" "an unwritable completion destination must fail"
assert_contains "$err" "cannot write the completion file" "the failure must say what could not be written"

# ---------- CASE: upgrade 未知选项 ----------
rc=0
err=$("$sk" upgrade --bogus 2>&1) || rc=$?
assert_eq "2" "$rc" "an unknown upgrade option must be a usage error"
assert_contains "$err" "unknown option" "the error must name the problem"

# ---------- CASE: upgrade 目标目录不存在 ----------
rc=0
err=$("$sk" upgrade "$work/absent-proj" 2>&1) || rc=$?
assert_eq "3" "$rc" "a missing project directory must be a precondition failure"
assert_contains "$err" "target directory does not exist" "the error must name the problem"

# ---------- CASE: upgrade 模板目录不存在 ----------
mkdir -p "$work/updir"
rc=0
err=$("$sk" upgrade "$work/updir" --template "$work/no-such-tpl" 2>&1) || rc=$?
assert_eq "3" "$rc" "a missing template directory must be a precondition failure"
assert_contains "$err" "template directory does not exist" "the error must name the problem"

# ---------- CASE: upgrade 目录进不去（cd 失败要有明确降级，不许拿空路径继续） ----------
mkdir -p "$work/np"
chmod 000 "$work/np"
rc=0
"$sk" upgrade "$work/np" >/dev/null 2>&1 || rc=$?
chmod 755 "$work/np"
assert_ne "0" "$rc" "a directory that cannot be entered must fail, not proceed with an empty path"

# ---------- CASE: new 到已存在的**空**目录 —— 点条目（. / ..）必须被跳过 ----------
mkdir -p "$work/newempty"
rc=0
"$sk" new "$work/newempty" --name newempty --cmd run --yes >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "an existing empty directory must be allowed"
assert_exists "$work/newempty/README.md" "generation must have produced the project"

# ---------- CASE: skill 安装 —— 已装文件是软链 ⇒ 保留不替换 ----------
k1="$work/k1"
mkdir -p "$k1/shellkit"
ln -s "$k1/somewhere-else" "$k1/shellkit/SKILL.md"
rc=0
out=$("$sk" skill install --dir "$k1" 2>&1) || rc=$?
assert_eq "0" "$rc" "installing over a symlinked file must succeed (kept)"
assert_contains "$out" "the target is a symlink" "the kept symlink must be announced"
assert_exists "$k1/shellkit/SKILL.md" "the symlink must survive"

# ---------- CASE: skill 安装 —— 正常残骸清理（.old / 死 pid .new 都收掉） ----------
k2="$work/k2"
mkdir -p "$k2/shellkit" "$k2/.shellkit-skill-old.123456" "$k2/.shellkit-skill-new.4194303"
printf 'stale\n' >"$k2/.shellkit-skill-old.123456/junk"
rc=0
"$sk" skill install --dir "$k2" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "install must succeed despite stale remnants"
assert_missing "$k2/.shellkit-skill-old.123456" "the stale old remnant must be cleaned"
assert_missing "$k2/.shellkit-skill-new.4194303" "the dead-pid stage must be recycled"

# ---------- CASE: skill 安装 —— 残骸清理失败必须吞掉错误继续（rm || true 的失败臂） ----------
# 父目录只读时 rm -rf 必然失败：清理是尽力而为，安装随后在建阶段目录时
# 明确失败（而不是被清理错误带偏）。
k3="$work/k3"
mkdir -p "$k3/shellkit" "$k3/.shellkit-skill-old.123456" "$k3/.shellkit-skill-new.4194303" \
  "$k3/.shellkit-skill-new.not-a-pid"
printf 'stale\n' >"$k3/.shellkit-skill-old.123456/junk"
chmod 555 "$k3"
rc=0
"$sk" skill install --dir "$k3" >/dev/null 2>&1 || rc=$?
chmod 755 "$k3"
assert_ne "0" "$rc" "install must fail when the stage directory cannot be created"
# 只读目录下 rm -rf 能删掉残骸的**内容**、但删不掉残骸目录本身（父目录不可写）
assert_exists "$k3/.shellkit-skill-old.123456" "a failed cleanup must leave the remnant directory in place"
assert_exists "$k3/.shellkit-skill-new.4194303" "the dead-pid stage must survive a failed cleanup too"
assert_exists "$k3/.shellkit-skill-new.not-a-pid" "the non-pid-named stage must survive a failed cleanup too"

# ---------- CASE: skill 安装 —— 磁盘内容与基线一致 ⇒ 走升级通道覆盖（基线=磁盘） ----------
k4="$work/k4"
rc=0
"$sk" skill install --dir "$k4" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "the first install must succeed"
printf '\n# user edit\n' >>"$k4/shellkit/SKILL.md"
m="$k4/shellkit/.shellkit-skill-manifest"
u=$(_sha "$k4/shellkit/SKILL.md")
awk -F'\t' -v OFS='\t' -v u="$u" '$1=="SKILL.md"{$2=u} {print}' "$m" >"$m.tmp" && mv "$m.tmp" "$m"
rc=0
"$sk" skill install --dir "$k4" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "the upgrade-channel install must succeed"
cmp -s "$k4/shellkit/SKILL.md" "$TEST_ROOT/skills/shellkit/SKILL.md" ||
  _fail "a file matching its baseline must be upgraded to the package content"

# ---------- CASE: skill 安装 —— 包里带 VERSION 时从包取版本（否则走 SELF_DIR 兜底） ----------
k5src="$work/k5src"
mkdir -p "$k5src/skills/shellkit"
cp -f "$TEST_ROOT/shellkit" "$k5src/shellkit"
cp -f "$TEST_ROOT/VERSION" "$k5src/VERSION"
cp -R "$TEST_ROOT/lib" "$k5src/lib"
cp -f "$TEST_ROOT/skills/shellkit/SKILL.md" "$k5src/skills/shellkit/SKILL.md"
printf '9.9.9\n' >"$k5src/skills/shellkit/VERSION"
rc=0
"$k5src/shellkit" skill install --dir "$work/k5" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "install from a package carrying VERSION must succeed"
assert_eq "9.9.9" "$(cat "$work/k5/shellkit/VERSION")" "the package VERSION must be installed"

# ---------- CASE: skill 卸载 —— references 里只剩点文件 ⇒ rmdir 必须失败而不是假装清空 ----------
u1a="$work/u1a"
rc=0
"$sk" skill install --dir "$u1a" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "the first install must succeed"
printf 'keep\n' >"$u1a/shellkit/references/.keep"
rc=0
"$sk" skill uninstall --dir "$u1a" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "an uninstall with a dotfile left must still finish"
assert_exists "$u1a/shellkit/references" "the directory with a dotfile must stay (rmdir failed honestly)"

# ---------- CASE: skill 卸载 —— 父目录不可写 ⇒ dstabs 的 rmdir 失败不许谎报成功删除目录 ----------
u1b="$work/u1b"
rc=0
"$sk" skill install --dir "$u1b" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "the first install must succeed"
chmod 555 "$u1b"
rc=0
"$sk" skill uninstall --dir "$u1b" >/dev/null 2>&1 || rc=$?
chmod 755 "$u1b"
assert_eq "0" "$rc" "the uninstall itself must succeed (files inside are removable)"
assert_exists "$u1b/shellkit" "the un-removable directory must stay instead of lying"

# ---------- CASE: skill 卸载（退化判据）—— 包不可用 ⇒ 明说无法验证、一个文件都不删 ----------
d5="$work/d5"
mkdir -p "$d5/shellkit"
printf 'x\n' >"$d5/shellkit/SKILL.md"
min1="$work/min1"
_mkmin "$min1"
rc=0
out=$("$min1/shellkit" skill uninstall --dir "$d5" 2>&1) || rc=$?
assert_eq "0" "$rc" "an uninstall without a package must not fail"
assert_contains "$out" "cannot verify" "the refusal must explain why nothing was removed"
assert_exists "$d5/shellkit/SKILL.md" "nothing must be removed without proof"

# ---------- CASE: skill 卸载（退化判据）—— 包与副本都没有 VERSION ⇒ 该条跳过 ----------
d6="$work/d6"
mkdir -p "$d6/shellkit"
printf 'x\n' >"$d6/shellkit/SKILL.md"
min2="$work/min2"
mkdir -p "$min2/skills/shellkit"
cp -f "$TEST_ROOT/shellkit" "$min2/shellkit"
cp -R "$TEST_ROOT/lib" "$min2/lib"
cp -f "$TEST_ROOT/skills/shellkit/SKILL.md" "$min2/skills/shellkit/SKILL.md"
rc=0
out=$("$min2/shellkit" skill uninstall --dir "$d6" 2>&1) || rc=$?
assert_eq "0" "$rc" "the degraded uninstall must finish without a VERSION anywhere"
assert_contains "$out" "modified locally" "the changed SKILL.md must be reported as kept"
assert_exists "$d6/shellkit/SKILL.md" "the kept file must survive"

# ---------- CASE: 恢复判据 —— 主副本缺 VERSION ⇒ 恢复旧副本 ----------
px="$work/rpx"
rc=0
"$sk" install-self --prefix "$px" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "the baseline install must succeed"
cp -R "$px/share/shellkit" "$px/share/shellkit.old"
rm -f "$px/share/shellkit/VERSION"
rc=0
out=$("$sk" install-self --prefix "$px" 2>&1) || rc=$?
assert_eq "0" "$rc" "a main copy missing VERSION must be recovered"
assert_contains "$out" "recovering the installed copy" "the recovery must be announced"
assert_exists "$px/share/shellkit/VERSION" "the recovered copy must carry VERSION again"

# ---------- CASE: 恢复判据 —— 主副本 CLI 不可执行 ⇒ 同样恢复 ----------
cp -R "$px/share/shellkit" "$px/share/shellkit.old"
chmod -x "$px/share/shellkit/shellkit"
rc=0
out=$("$sk" install-self --prefix "$px" 2>&1) || rc=$?
assert_eq "0" "$rc" "a main copy with a non-executable CLI must be recovered"
assert_contains "$out" "recovering the installed copy" "the recovery must be announced"
assert_true test -x "$px/share/shellkit/shellkit"

# ---------- CASE: install-self 源树没有 repair.sh（修复入口缺失时安装照常完成） ----------
min3="$work/min3"
_mkmin "$min3"
rc=0
"$min3/shellkit" install-self --prefix "$work/i1px" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "installing from a tree without repair.sh must succeed"
assert_exists "$work/i1px/share/shellkit/lib/bootstrap.sh" "the copy must be installed"

# ---------- CASE: _t 收到 - 开头的 msgid（gettext 必须用 -- 隔离，别当选项吃掉） ----------
rc=0
out=$(env -u SHELLKIT_LANG SK_GETTEXT=gettext LC_ALL=en_US.UTF-8 \
  "$sk" new "$work/t1x" --set noequals --cmd run --yes 2>&1) || rc=$?
assert_eq "2" "$rc" "--set without KEY=VALUE must be a usage error"
assert_contains "$out" "expects KEY=VALUE" "the error must come from the dash-leading msgid"

# ---------- CASE: _t 的 gettext 目录列表里有空段 ⇒ 跳过而不是拿空路径去调 gettext ----------
# SHELLKIT_LANG 非空 ⇒ 顶部「默认配置」分支被跳过；目录表从 TEXTDOMAINDIR 加载
# （那里没有 .mo）⇒ 查表不中 ⇒ 落进 gettext 分支 ⇒ 空段在这里被跳过。
mkdir -p "$work/td" "$work/td2"
rc=0
out=$(SK_GETTEXT=gettext TEXTDOMAINDIR="$work/td::$work/td2" \
  "$sk" new "$work/t2x" --set noequals --cmd run --yes 2>&1) || rc=$?
assert_eq "2" "$rc" "behavior must be unchanged with a malformed domain dir list"
assert_contains "$out" "expects KEY=VALUE" "the same error must come out"

# ---------- CASE: install-self —— repair 入口链接失败不拖垮安装（ln 的 else 臂） ----------
# 用 ln 替身只拒绝 repair 相关的链接：主链接照常，修复入口静默缺席。
lnbin="$work/lnbin"
mkdir -p "$lnbin"
real_ln=$(command -v ln)
{
  printf '%s\n' '#!/bin/sh'
  printf '%s\n' 'for a in "$@"; do'
  printf '%s\n' '  case "$a" in *repair*) exit 1 ;; esac'
  printf '%s\n' 'done'
  printf 'exec %s "$@"\n' "$real_ln"
} >"$lnbin/ln"
chmod +x "$lnbin/ln"
rc=0
PATH="$lnbin:$PATH" "$sk" install-self --prefix "$work/l41px" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "a failed repair link must not fail the install"
assert_exists "$work/l41px/share/shellkit/lib/bootstrap.sh" "the copy must be installed"
assert_missing "$work/l41px/bin/shellkit-repair" "the repair link must not pretend to exist"

# ---------- CASE: doctor —— 可选工具缺失时明说并保持 0 ----------
# 收窄 PATH 隐藏可选工具（gettext / po tools / shellcheck / shfmt 都在 PATH 外），
# 必需工具（bash / sha256 / curl）留在 /usr/bin 里 ⇒ 缺的只是可选的。
rc=0
out=$(env -u SK_GETTEXT PATH=/usr/bin:/bin:/sbin "$sk" doctor 2>&1) || rc=$?
assert_eq "0" "$rc" "optional tooling missing must not fail doctor"
assert_contains "$out" "optional tooling is missing" "the warning must say what is missing"

# ---------- CASE: update —— 载荷缺 bootstrap ⇒ 安装子进程失败要报错（不静默） ----------
bdir="$work/broken/shellkit-9.9.9"
mkdir -p "$bdir/lib"
cp -f "$TEST_ROOT/shellkit" "$bdir/shellkit"
printf '9.9.9\n' >"$bdir/VERSION"
tar -czf "$work/broken.tgz" -C "$work/broken" "shellkit-9.9.9"
rc=0
"$sk" install-self --prefix "$work/b2px" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "the baseline install must succeed"
rc=0
out=$("$sk" update --from "$work/broken.tgz" --prefix "$work/b2px" 2>&1) || rc=$?
assert_ne "0" "$rc" "installing a payload without a bootstrap must fail"
assert_contains "$out" "no checksum provided" "the skipped verification must be announced"

# ---------- CASE: skill 安装 —— 提交换名被拒 ⇒ 明确失败、已装副本一个字节不变 ----------
if fault_perm_usable; then
  k7="$work/k7"
  rc=0
  "$sk" skill install --dir "$k7" >/dev/null 2>&1 || rc=$?
  assert_eq "0" "$rc" "the baseline skill install must succeed"
  printf '\n# forced edit\n' >>"$k7/shellkit/SKILL.md"
  before=$(_sha "$k7/shellkit/SKILL.md")
  k7abs=$(cd "$k7" && pwd -P)
  # 拒绝「新的换入」（第二次 rename 的目标是 shellkit，可精确指定）⇒ 旧副本停在 .old。
  # 第一次 rename 的目标带未知 pid、替身只做精确匹配 —— 那条失败臂不在此场景覆盖。
  fault_reset
  fault_scope "$k7abs"
  fault_perm_deny "$k7abs/shellkit" rename
  rc=0
  fault_run "$sk" skill install --dir "$k7" --force >"$k7/perm2.log" 2>&1 || rc=$?
  assert_ne "0" "$rc" "denying the second rename must fail the install"
  oldd=$(ls -d "$k7"/.shellkit-skill-old.* 2>/dev/null)
  oldd=${oldd%%$'\n'*}
  assert_ne "" "$oldd" "the pre-commit copy must be parked as .old"
  assert_eq "$before" "$(_sha "$oldd/SKILL.md")" \
    "the parked copy must be byte-identical"
  fault_reset
  # 恢复：故障撤掉后重试必须自愈
  fault_reset
  rc=0
  fault_run "$sk" skill install --dir "$k7" --force >/dev/null 2>&1 || rc=$?
  assert_eq "0" "$rc" "the retry must succeed once the fault is gone"
else
  printf '%s\n' 'NA skill-rename|permission: running as root, chmod cannot deny uid 0'
fi

# ---------- CASE: skill 卸载 —— 清单重写被拒 ⇒ 明确失败（manifest 时机注入） ----------
if fault_perm_usable; then
  d8="$work/d8"
  rc=0
  "$sk" skill install --dir "$d8" >/dev/null 2>&1 || rc=$?
  assert_eq "0" "$rc" "the baseline skill install must succeed"
  printf '\nlocal edit\n' >>"$d8/shellkit/references/reference.md"
  d8abs=$(cd "$d8" && pwd -P)
  fault_reset
  fault_scope "$d8abs"
  fault_perm_deny "$d8abs/shellkit/.shellkit-skill-manifest" manifest
  rc=0
  fault_run "$sk" skill uninstall --dir "$d8" >"$d8/perm.log" 2>&1 || rc=$?
  assert_ne "0" "$rc" "the injected manifest denial must fail the uninstall"
  assert_true fault_trace_has "perm stage=manifest"
  assert_exists "$d8/shellkit/references/reference.md" "the kept file must survive the failed rewrite"
  fault_reset
else
  printf '%s\n' 'NA skill-manifest|permission: running as root, chmod cannot deny uid 0'
fi

# ---------- CASE: upgrade —— 模板里少一个工程清单点名的文件 ⇒ 跳过而不是炸 ----------
e5="$work/e5proj"
rc=0
"$sk" new "$e5" --name e5 --cmd run --yes >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "the base project must be generated"
e5tpl="$work/e5tpl"
cp -R "$TEST_ROOT/templates" "$e5tpl"
rm -f "$e5tpl/commands/__CMD__.sh"
rc=0
"$sk" upgrade "$e5" --template "$e5tpl" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "an upgrade with a file missing from the template must not fail"
assert_exists "$e5/commands/run.sh" "the project file must not be deleted because the template lacks it"

# 同一模板再升级一次，但工程文件也没了 —— 「两边都没有」时保持现状而不是报错
rm -f "$e5/commands/run.sh"
rc=0
"$sk" upgrade "$e5" --template "$e5tpl" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "an upgrade with neither side having the file must not fail"
assert_missing "$e5/commands/run.sh" "nothing may appear out of nowhere"

# ---------- CASE: skill 卸载 —— 清单目标本身是软链 ⇒ 保留（不跟随） ----------
h1="$work/h1"
mkdir -p "$h1/shellkit"
ln -s "$h1/somewhere-else" "$h1/shellkit/SKILL.md"
printf 'manifest_version=1\nSKILL.md\t%s\n' "$(printf '%056d' 0 | tr 0 a)" \
  >"$h1/shellkit/.shellkit-skill-manifest"
rc=0
out=$("$sk" skill uninstall --dir "$h1" 2>&1) || rc=$?
assert_eq "0" "$rc" "an uninstall with a symlinked target must finish"
assert_contains "$out" "the target is a symlink" "the kept symlink must be announced"
assert_exists "$h1/shellkit/SKILL.md" "the symlink must survive"

# ---------- CASE: 上游删除时的目标级检查（软链 / 目录 / 已不在） ----------
# 所有权同步的删除循环对「清单里有、源里没有」的条目直接调安全接口 —— 目标级
# 三连：软链保留并告警、目录拒绝递归、已不在算删除成功。条目手工登记进 vendor
# 清单：docs/ 不在 vendor 的整树清单里（源里天然没有）⇒ 必走删除循环；
# docs/ 也不被整树替换 ⇒ 保留下来的软链与目录不会被后续同步抹掉。
vproj="$work/vproj"
mkdir -p "$vproj"
rc=0
"$sk" vendor "$vproj" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "the baseline vendor sync must succeed"
vdest="$vproj/vendor/shellkit"
mkdir -p "$vdest/docs"
printf 'target\n' >"$work/vlink-target"
ln -s "$work/vlink-target" "$vdest/docs/link"
mkdir -p "$vdest/docs/dir"
printf 'inner\n' >"$vdest/docs/dir/inner"
fake=$(printf '%056d' 0 | tr 0 a)
# 清单末行可能没有换行符：先补一个空行（读取时会被跳过），否则第一条会拼进上一行
{
  printf '\n'
  printf 'docs/link\t%s\n' "$fake"
  printf 'docs/dir\t%s\n' "$fake"
  printf 'docs/gone\t%s\n' "$fake"
} >>"$vdest/.shellkit-vendor-manifest"
rc=0
out=$("$sk" vendor "$vproj" 2>&1) || rc=$?
assert_eq "0" "$rc" "the sync must succeed while keeping unsafe targets"
assert_contains "$out" "the target is a symlink" "the symlinked target must be announced"
assert_contains "$out" "not a regular file" "the directory target must be announced"
assert_exists "$vdest/docs/link" "the symlink must survive the sync"
assert_exists "$vdest/docs/dir" "the directory must survive the sync"
assert_missing "$vdest/docs/gone" "an already-gone upstream file must stay gone"

# ---------- CASE: skill 卸载 —— 清单目标不存在 ⇒ 算删除、条目清掉 ----------
h3="$work/h3"
mkdir -p "$h3/shellkit"
printf 'manifest_version=1\nghost.txt\t%s\n' "$(printf '%056d' 0 | tr 0 a)" \
  >"$h3/shellkit/.shellkit-skill-manifest"
rc=0
"$sk" skill uninstall --dir "$h3" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "an absent target is a no-op, not a failure"
assert_not_contains "$(cat "$h3/shellkit/.shellkit-skill-manifest" 2>/dev/null || true)" \
  "ghost.txt" "the already-gone entry must be dropped from the manifest"

# ---------- CASE: skill 卸载（退化判据）—— 目标是软链 ⇒ 保留并告警 ----------
h4="$work/h4"
mkdir -p "$h4/shellkit"
ln -s "$h4/somewhere-else" "$h4/shellkit/SKILL.md"
rc=0
out=$("$sk" skill uninstall --dir "$h4" 2>&1) || rc=$?
assert_eq "0" "$rc" "a degraded uninstall with a symlinked target must finish"
assert_contains "$out" "the target is a symlink" "the kept symlink must be announced"
assert_exists "$h4/shellkit/SKILL.md" "the symlink must survive"

printf 'test_branch_gap_paths: all cases passed\n'
