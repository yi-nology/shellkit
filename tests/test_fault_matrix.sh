#!/usr/bin/env bash
# 故障注入用例矩阵（issue #57）：4 条路径 × 4 类故障。
#
# 每格回答同一个问题：磁盘最终状态是什么，用户数据还在不在？
# 判据不止退出码：每格都断「注入确实发生」（痕迹）+「磁盘终态」
# （fault_snapshot / sha256 / 结构）+「用户数据还在」。
#
# 全部走 tests/lib/fault.sh 的共享注入点（不各写各的）。格子分三类：
#   CASE  —— 本文件新写的用例；
#   CELL  —— 交叉引用既有用例（套件绿即该格存在且有效）；
#   NA    —— 显式「不适用」记录 + 理由（打印到 stdout）。
#
# 与既有用例的分工（不重复造用例）：
#   upgrade 行四格由 tests/test_fault.sh 覆盖（ENOSPC/权限(含清单提交前)/
#   并发互斥/信号），N=1..8 的崩溃恢复在 tests/test_upgrade_crash.sh；
#   install-self/vendor 的 .old 恢复在 tests/test_vendor_recovery.sh；
#   repair 的状态机与重入在 tests/test_repair.sh（按状态构造，非注入）。
#   本文件补的是矩阵点名、但还没有共享注入用例的格子，以及验收判据点名的
#   「两个升级并发后清单条目不丢」。
#
# TEST_TIMEOUT: 900 —— 多个格子要跑真升级/真 vendor（每个几十秒）。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fault.sh"

SK="$TEST_ROOT/shellkit"

REPAIR="$TEST_ROOT/repair.sh"
PACK="$TEST_ROOT/skills/shellkit"

work=$(tmpdir)
locks="$work/locks"
mkdir -p "$locks"
export SHELLKIT_LOCK_DIR="$locks"

# ---- 改过的模板：让升级真的有事可做 ----
tpl="$work/tpl"
cp -R "$TEST_ROOT/templates" "$tpl"
printf '# matrix-test marker\n' >>"$tpl/README.md"

# file_sum FILE —— 文件的 sha256
file_sum() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    openssl dgst -sha256 "$1" | awk '{print $NF}'
  fi
}

# snap_get SNAPSHOT KEY —— 从快照里取一个值
snap_get() {
  local __line
  while IFS= read -r __line; do
    case "$__line" in
      "$2="*)
        printf '%s' "${__line#*=}"
        return 0
        ;;
    esac
  done <<EOF
$1
EOF
  return 1
}

# manifest_entries PROJECT —— 清单里 @file 条目的相对路径集合（排序）
manifest_entries() {
  awk '$1 == "@file" { print $2 }' "$1/.shellkit-manifest" | LC_ALL=C sort
}

# new_project NAME —— 带用户自有文件的干净工程
base="$work/base"
"$SK" new "$base" --name tool --cmd run --yes >/dev/null 2>&1
if [ ! -f "$base/.shellkit-manifest" ]; then
  _fail "the base project is incomplete: shellkit new did not finish"
fi
printf 'MINE\n' >"$base/user-note.txt"

new_project() {
  local __p="$work/$1"
  cp -R "$base" "$__p"
  printf '%s\n' "$__p"
}

# new_prefix NAME —— 真装一次 install-self，返回 prefix；再把主副本挪成
# 「主副本缺失、旧副本完整」的断点现场（repair 行的共用前置）
new_prefix() {
  local __p="$work/$1"
  mkdir -p "$__p" || return 1
  "$SK" install-self --prefix "$__p" >/dev/null 2>&1 || return 1
  [ -f "$__p/share/shellkit/lib/bootstrap.sh" ] || return 1
  mv "$__p/share/shellkit" "$__p/share/shellkit.old" || return 1
  printf 'USER-MARK\n' >"$__p/share/shellkit.old/USER.txt"
  printf '%s\n' "$__p"
}

# ===========================================================================
# upgrade 行 —— 交叉引用（tests/test_fault.sh 已有四格 + crash 套件）
# ===========================================================================
printf '%s\n' 'CELL upgrade|diskfull -> tests/test_fault.sh CASE 磁盘满（ENOSPC 替身）在真实升级上'
printf '%s\n' 'CELL upgrade|permission -> tests/test_fault.sh CASE 权限拒绝（清单提交前）+ CASE 权限拒绝（写前/rename 前）'
printf '%s\n' 'CELL upgrade|signal -> tests/test_upgrade_crash.sh N=1..8（N=8 即「提交前」窗口）+ tests/test_fault.sh CASE 信号'

# CASE: upgrade|concurrent —— 两个升级并发后 .shellkit-manifest 条目不丢
#（验收判据点名：结构完整之外还要「条目集合不变」）
proj=$(new_project uconc)
entries_before=$(manifest_entries "$proj")
usersum=$(file_sum "$proj/user-note.txt")

fault_reset
fault_scope "$proj"
fault_gate_arm rename
fault_concurrent_start "$SK" upgrade "$proj" --template "$tpl"
if ! fault_gate_wait 60; then
  _fail "the first upgrade must reach the blocked rename"
fi

# 第二个实例此刻持着工程锁 ⇒ 必须明确失败，而不是两份清单互相覆盖
rc=0
out=$(fault_run "$SK" upgrade "$proj" --template "$tpl" 2>&1) || rc=$?
assert_ne "0" "$rc" "the second upgrade must not report success"
assert_contains "$out" "another instance is running" "the refusal must name the cause"

fault_gate_open
rc=0
fault_concurrent_wait || rc=$?
assert_eq "0" "$rc" "the first upgrade must finish once the gate opens"

snap=$(fault_snapshot "$proj/lib/app.sh" "" "" "$proj/.shellkit-manifest" "$proj/user-note.txt" "$usersum")
assert_eq "complete" "$(snap_get "$snap" manifest.state)" "the manifest must stay complete"
assert_eq "0" "$(snap_get "$snap" manifest.leftovers)" "the manifest must not leave a temp file"
assert_eq "intact" "$(snap_get "$snap" user.state)" "the user's own file must survive"
entries_after=$(manifest_entries "$proj")
assert_eq "$entries_before" "$entries_after" "no manifest entry may be lost when two upgrades race"
printf '%s\n' 'CELL upgrade|concurrent -> tests/test_fault.sh CASE 并发（互斥）+ 本用例（条目集合不丢）'

# ===========================================================================
# skill 行
# ===========================================================================

# CASE: skill|diskfull —— 原子写失败无损：用户编辑过的文件原封不动
d=$(tmpdir)
mkdir -p "$d/1"
"$SK" skill install --dir "$d/1" >/dev/null 2>&1 || _fail "skill install must succeed"
printf 'USER EDIT MUST SURVIVE\n' >"$d/1/shellkit/SKILL.md"
before_skill=$(file_sum "$d/1/shellkit/SKILL.md")
before_manifest=$(file_sum "$d/1/shellkit/.shellkit-skill-manifest")
usersum=$(file_sum "$d/1/shellkit/references/reference.md")

# skill 的目标路径会经 pwd -P 归一（/var/folders 是 /private/var/folders 的
# 软链）—— 注入 scope 必须用同一个口径，否则替身永远匹配不上。
client1=$(cd "$d/1" && pwd -P)
fault_reset
fault_scope "$client1"
fault_enospc_scope "$client1"
rc=0
fault_run "$SK" skill install --dir "$d/1" --force >"$d/enospc.log" 2>&1 || rc=$?
assert_ne "0" "$rc" "the injected disk-full must make the skill install fail"
assert_true fault_trace_has "enospc wrote="
assert_eq "$before_skill" "$(file_sum "$d/1/shellkit/SKILL.md")" \
  "the user-edited file must stay byte-identical after the failed write"
assert_eq "$before_manifest" "$(file_sum "$d/1/shellkit/.shellkit-skill-manifest")" \
  "the skill manifest must stay byte-identical after the failed write"
assert_eq "0" "$(fault_count_tmp "$d/1/shellkit" "*.tmp.*")" \
  "no half-written temp file may be left behind"
assert_eq "$usersum" "$(file_sum "$d/1/shellkit/references/reference.md")" \
  "an untouched reference file must stay intact"

# 恢复：不注入再装一次必须收敛到 pack 内容
fault_reset
rc=0
fault_run "$SK" skill install --dir "$d/1" --force >"$d/recover.log" 2>&1 || rc=$?
assert_eq "0" "$rc" "the retry must succeed once the fault is gone"
assert_exit_code 0 cmp "$PACK/SKILL.md" "$d/1/shellkit/SKILL.md"

# CASE: skill|concurrent —— 双装交错：终态必须完整，用户自加文件不丢
d=$(tmpdir)
mkdir -p "$d/2"
"$SK" skill install --dir "$d/2" >/dev/null 2>&1 || _fail "skill install must succeed"
printf 'MY OWN NOTES\n' >"$d/2/shellkit/references/custom.md"
printf 'DRIFT\n' >"$d/2/shellkit/SKILL.md"

client2=$(cd "$d/2" && pwd -P)
fault_reset
fault_scope "$client2"
fault_gate_arm rename
fault_concurrent_start "$SK" skill install --dir "$d/2" --force
if ! fault_gate_wait 60; then
  _fail "the first skill install must reach the blocked rename"
fi
# 第二个实例：skill 没有工程锁，必须靠原子写收敛到完整终态（清掉闸门配置，
# 否则第二个实例自己也会被拦住）
# export：这个值是给 fault_run 里的子进程用的，shellcheck 只看本文件时会判它「未使用」
export FAULT_GATE_STAGE=""
rc=0
fault_run "$SK" skill install --dir "$d/2" --force >"$d/b.log" 2>&1 || rc=$?
assert_eq "0" "$rc" "the second install must converge on its own"
fault_gate_open
rc=0
fault_concurrent_wait || rc=$?
assert_eq "0" "$rc" "the first install must finish once the gate opens"

assert_exit_code 0 cmp "$PACK/SKILL.md" "$d/2/shellkit/SKILL.md"
assert_eq "MY OWN NOTES" "$(cat "$d/2/shellkit/references/custom.md")" \
  "a user-added reference file must survive both installs"
assert_eq "0" "$(fault_count_tmp "$d/2/shellkit" "*.tmp.*")" \
  "no half-written temp file may be left behind"
# 清单与磁盘自洽：再装一次必须报 up to date
out=$("$SK" skill install --dir "$d/2" 2>&1)
assert_contains "$out" "up to date" "the manifest must agree with the disk after the race"

# CASE: skill|permission —— 写前拒绝：零字节改动
if fault_perm_usable; then
  d=$(tmpdir)
  mkdir -p "$d/3"
  "$SK" skill install --dir "$d/3" >/dev/null 2>&1 || _fail "skill install must succeed"
  printf 'USER EDIT MUST SURVIVE\n' >"$d/3/shellkit/SKILL.md"
  before_skill=$(file_sum "$d/3/shellkit/SKILL.md")
  before_manifest=$(file_sum "$d/3/shellkit/.shellkit-skill-manifest")

  client3=$(cd "$d/3" && pwd -P)
  fault_reset
  fault_scope "$client3"
  # 写目标在阶段目录里（整组事务提交，issue #86），目录名带 pid 点不到名 ——
  # 用 glob 点：第一次对 SKILL.md 的 mktemp（写前时机）被拒绝
  fault_perm_deny "$client3/.shellkit-skill-new.*/SKILL.md" write
  rc=0
  fault_run "$SK" skill install --dir "$d/3" --force >"$d/perm.log" 2>&1 || rc=$?
  assert_ne "0" "$rc" "the injected permission denial must make the install fail"
  assert_true fault_trace_has "perm stage=write"
  assert_eq "$before_skill" "$(file_sum "$d/3/shellkit/SKILL.md")" \
    "not a single byte may change when the write is refused"
  assert_eq "$before_manifest" "$(file_sum "$d/3/shellkit/.shellkit-skill-manifest")" \
    "the skill manifest must not change either"
  assert_eq "0" "$(fault_count_tmp "$d/3/shellkit" "*.tmp.*")" \
    "no temp file may be left behind"
  assert_true test -w "$d/3/shellkit"

  fault_reset
  rc=0
  fault_run "$SK" skill install --dir "$d/3" --force >"$d/perm2.log" 2>&1 || rc=$?
  assert_eq "0" "$rc" "the retry must succeed once the fault is gone"
  assert_exit_code 0 cmp "$PACK/SKILL.md" "$d/3/shellkit/SKILL.md"

else
  printf '%s\n' 'NA skill|permission: running as root, chmod cannot deny uid 0 (issue #76)'
fi

printf '%s\n' 'NA skill|signal: 每次写都是「同目录临时文件 + rename」的原子替换，单文件被杀只留 .tmp 残骸、目标永远是完整旧/新内容；信号窗口与本行磁盘满/权限格同构，P0 两段式提交风险在 upgrade 行（crash 套件覆盖），故本格不适用'

# ===========================================================================
# install-self / vendor 行
# ===========================================================================

# CASE: vendor|diskfull —— stage 不完整时旧副本完好（RLIMIT_FSIZE 内核层）
proj=$(new_project vdisk)
printf 'MINE\n' >"$proj/vendor/shellkit/user-note.txt"
rm -f "$proj/vendor/shellkit/VERSION" # 制造差异：没有差异就不会换名
old_bootstrap=$(file_sum "$proj/vendor/shellkit/lib/bootstrap.sh")

fault_reset
fault_disk_full_limit 1024
rc=0
fault_run "$SK" vendor "$proj" >"$work/vdisk.log" 2>&1 || rc=$?
assert_ne "0" "$rc" "the kernel file-size limit must make the vendor sync fail"
assert_eq "$old_bootstrap" "$(file_sum "$proj/vendor/shellkit/lib/bootstrap.sh")" \
  "the old vendored copy must stay byte-identical when the stage write fails"
assert_eq "MINE" "$(cat "$proj/vendor/shellkit/user-note.txt")" \
  "the user's own file inside the vendored copy must survive"

fault_reset
rc=0
fault_run "$SK" vendor "$proj" >"$work/vdisk2.log" 2>&1 || rc=$?
assert_eq "0" "$rc" "the retry must succeed once the fault is gone"
assert_true test -f "$proj/vendor/shellkit/lib/bootstrap.sh"
assert_false test -e "$proj/vendor/.shellkit-new"
assert_false test -e "$proj/vendor/.shellkit-old"
assert_eq "MINE" "$(cat "$proj/vendor/shellkit/user-note.txt")" \
  "the user's own file must survive the recovery too"

# CASE: vendor|keep-fail —— 用户改过的文件搬不进暂存区时，必须整轮失败，而不是静默丢掉修改
#
# 以前「把用户改过的文件挪到一边」失败是 `|| true` 吞掉的。吞掉的后果不是「少挪一个
# 文件」：整树复制随后会把候选目录里那份旧内容覆盖成上游内容，恢复阶段又找不到暂存的
# 那份，于是用户的编辑消失，而命令返回 0。
#
# 注入点选 TMPDIR：__keep 是 `mktemp -d "$TMPDIR/shellkit-own-keep.XXXXXX"`，把 TMPDIR
# 放进 ENOSPC 作用域后，只有「搬进暂存区」这一步失败 —— 工程目录、暂存目录与整树复制
# 都不受影响，判据因此能精确指向那一步。
file_mode() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null
}

proj=$(new_project vkeep)
target="$proj/vendor/shellkit/shellkit"
printf '\n# user edit must survive\n' >>"$target"
usum=$(file_sum "$target")
umode=$(file_mode "$target")
bsum=$(file_sum "$proj/vendor/shellkit/lib/bootstrap.sh")
msum=$(file_sum "$proj/vendor/shellkit/.shellkit-vendor-manifest")

kscope="$work/keep-scope"
mkdir -p "$kscope"
kdrv="$work/keep-driver.sh"
cat >"$kdrv" <<'KDRV'
#!/usr/bin/env bash
# TMPDIR 指到注入作用域：__keep 建在里面，于是只有「搬进暂存区」这一步会失败
export TMPDIR="$1"
exec "$2" vendor "$3"
KDRV

fault_reset
fault_scope "$proj"
fault_enospc_scope "$kscope"
rc=0
fault_run bash "$kdrv" "$kscope" "$SK" "$proj" >"$work/vkeep.log" 2>&1 || rc=$?
assert_ne "0" "$rc" "a failure to stage the user's file must fail the whole sync"
assert_true fault_trace_has "enospc wrote="
assert_eq "$usum" "$(file_sum "$target")" \
  "the user's edited file must stay byte-identical after the refused sync"
assert_eq "$umode" "$(file_mode "$target")" \
  "the user's edited file must keep its permission bits"
assert_eq "$bsum" "$(file_sum "$proj/vendor/shellkit/lib/bootstrap.sh")" \
  "the vendored library must stay byte-identical (no half swap)"
assert_eq "$msum" "$(file_sum "$proj/vendor/shellkit/.shellkit-vendor-manifest")" \
  "the ownership manifest must not be rewritten by a refused sync"
assert_false test -e "$proj/vendor/.shellkit-new"
assert_false test -e "$proj/vendor/.shellkit-old"

fault_reset
rc=0
fault_run "$SK" vendor "$proj" >"$work/vkeep2.log" 2>&1 || rc=$?
assert_eq "0" "$rc" "the retry must succeed once the fault is gone"
assert_contains "$(cat "$target")" "user edit must survive" \
  "the user's edit must be back after the retry"

# CASE: vendor|concurrent —— 换名互斥：双跑后旧副本与用户文件完好、无残骸
proj=$(new_project vconc)
printf 'MINE\n' >"$proj/vendor/shellkit/user-note.txt"
rm -f "$proj/vendor/shellkit/VERSION"

fault_reset
fault_scope "$proj"
# 拦 recover 而不是 rename：vendor 的换名被替身的 */vendor/* 排除规则清掉了 stage
# （那条规则的本意是「vendor 文件不算工程自己的文件」，别让权限/信号注入打到它），
# 所以 rename 永远等不到。而换名互斥要卡的正是这一步 —— vendor 同步先 mv 当前副本
# 到 .shellkit-old，命中的就是 recover 阶段。
fault_gate_arm recover
fault_concurrent_start "$SK" vendor "$proj"
if ! fault_gate_wait 60; then
  _fail "the first vendor sync must reach the blocked rename"
fi
# export：同上 —— 这个值要传给 fault_run 的子进程
export FAULT_GATE_STAGE=""
rc=0
out=$(fault_run "$SK" vendor "$proj" 2>&1) || rc=$?
if [ "$rc" -ne 0 ]; then
  # 拒绝必须明说被别的实例占着（互斥），而不是悄悄写坏
  assert_contains "$out" "another instance is running" \
    "a concurrent vendor must either serialize or refuse by name"
fi
fault_gate_open
rc=0
fault_concurrent_wait || rc=$?
assert_eq "0" "$rc" "the first vendor sync must finish once the gate opens"
assert_true test -f "$proj/vendor/shellkit/lib/bootstrap.sh"
assert_eq "MINE" "$(cat "$proj/vendor/shellkit/user-note.txt")" \
  "the user's own file must survive the race"
assert_false test -e "$proj/vendor/.shellkit-new"
assert_false test -e "$proj/vendor/.shellkit-old"

# CASE: install-self|permission —— 换入被拒：旧副本完好、可恢复
if fault_perm_usable; then
  prefix=$(new_prefix pperm) || _fail "install-self setup failed"
  old_sum=$(file_sum "$prefix/share/shellkit.old/lib/bootstrap.sh")

  fault_reset
  fault_scope "$prefix"
  fault_perm_deny "$prefix/share/shellkit" rename
  rc=0
  fault_run "$SK" install-self --prefix "$prefix" >"$work/pperm.log" 2>&1 || rc=$?
  assert_ne "0" "$rc" "the injected permission denial must make install-self fail"
  assert_true fault_trace_has "perm stage=rename"
  assert_true test -f "$prefix/share/shellkit.old/lib/bootstrap.sh"
  assert_eq "$old_sum" "$(file_sum "$prefix/share/shellkit.old/lib/bootstrap.sh")" \
    "the old copy must stay byte-identical"
  assert_true test -w "$prefix/share"

  fault_reset
  rc=0
  fault_run "$SK" install-self --prefix "$prefix" >"$work/pperm2.log" 2>&1 || rc=$?
  assert_eq "0" "$rc" "the retry must recover once the fault is gone"
  assert_true test -f "$prefix/share/shellkit/lib/bootstrap.sh"
  assert_eq "USER-MARK" "$(cat "$prefix/share/shellkit/USER.txt")" "the user file must survive the recovery"
  assert_false test -e "$prefix/share/shellkit.old"
  assert_false test -e "$prefix/share/shellkit.new"

else
  printf '%s\n' 'NA install-self|permission: running as root, chmod cannot deny uid 0 (issue #76)'
fi

# CASE: install-self|signal —— 提交前（stage 还在铺）被杀 ⇒ 旧副本无损、重跑收敛
#
# 第一次 rename 是铺 stage 的逐文件拷贝（fs_atomic_copy 每次都是一次 rename），
# 所以 after 1 稳定落在「提交之前」—— 这个点与文件个数无关，比数到换入那一次可靠。
prefix=$(new_prefix psig) || _fail "install-self setup failed"
rm -f "$prefix/share/shellkit.old/VERSION" # 制造差异：没有差异就不会换名

fault_reset
fault_scope "$prefix"
fault_signal_kill rename after 1
rc=0
fault_run "$SK" install-self --prefix "$prefix" >"$work/psig.log" 2>&1 || rc=$?
assert_ne "0" "$rc" "the killed install-self must not report success"
assert_true fault_trace_has "sig when=after stage=rename"
# 换入还没开始：旧副本已被恢复回主位、.old 已按 setup 清掉 —— 主副本一个字节没动
assert_true test -f "$prefix/share/shellkit/lib/bootstrap.sh"
assert_false test -e "$prefix/share/shellkit.old"

fault_reset
rc=0
fault_run "$SK" install-self --prefix "$prefix" >"$work/psig2.log" 2>&1 || rc=$?
assert_eq "0" "$rc" "the retry must converge"
assert_true test -f "$prefix/share/shellkit/lib/bootstrap.sh"
assert_false test -e "$prefix/share/shellkit.old"
assert_false test -e "$prefix/share/shellkit.new"

printf '%s\n' 'CELL install-self/vendor|signal -> tests/test_vendor_recovery.sh CASE 两次 rename 之间被杀（vendor 与 install-self 各一格）+ 本用例（提交前/清理窗口）'

# ===========================================================================
# repair 行
# ===========================================================================

# CASE: repair|concurrent —— 双修交错：完整副本必须存活，重跑收敛
prefix=$(new_prefix rconc) || _fail "repair setup failed"

fault_reset
fault_scope "$prefix"
fault_gate_arm rename
fault_concurrent_start bash "$REPAIR" --prefix "$prefix"
if ! fault_gate_wait 60; then
  _fail "the first repair must reach the blocked rename"
fi
# 第二个修复没有闸门配置：直接跑（repair 没有锁，双修是真实风险）
rc=0
out=$(bash "$REPAIR" --prefix "$prefix" 2>&1) || rc=$?
assert_eq "0" "$rc" "the second repair must restore the copy"
fault_gate_open
rc=0
fault_concurrent_wait || rc=$?
# 第一个实例晚了一步：旧副本已被第二个实例挪走 ⇒ 必须明说失败，不许假装成功
assert_ne "0" "$rc" "the first repair must not pretend to succeed after losing the race"
err=$(cat "$FAULT_DIR/bg.err" 2>/dev/null || true)
assert_contains "$err" "failed to move the old copy back" "the loser must name what failed"

# 终态：完整副本在主槽位，用户数据还在
assert_true test -f "$prefix/share/shellkit/lib/bootstrap.sh"
assert_eq "USER-MARK" "$(cat "$prefix/share/shellkit/USER.txt")" \
  "the user file inside the restored copy must survive"
fault_reset
rc=0
fault_run bash "$REPAIR" --prefix "$prefix" >"$work/rconc2.log" 2>&1 || rc=$?
assert_eq "0" "$rc" "a final repair pass must be clean"

# CASE: repair|permission —— 只读时明确失败，什么都不删
if fault_perm_usable; then
  prefix=$(new_prefix rperm) || _fail "repair setup failed"

  fault_reset
  fault_scope "$prefix"
  fault_perm_deny_sticky "$prefix/share/shellkit" rename
  rc=0
  out=$(fault_run bash "$REPAIR" --prefix "$prefix" 2>&1) || rc=$?
  assert_ne "0" "$rc" "a read-only slot must make repair fail explicitly"
  assert_contains "$out" "failed to move the old copy back" "the failure must be named"
  assert_true fault_trace_has "perm stage=rename"
  # 什么都不删：旧副本原封不动，用户数据还在
  assert_true test -f "$prefix/share/shellkit.old/lib/bootstrap.sh"
  assert_eq "USER-MARK" "$(cat "$prefix/share/shellkit.old/USER.txt")" \
    "the user file must survive the refused repair"
  assert_false test -e "$prefix/share/shellkit"
  assert_file_mode "$prefix/share" "500" "the sticky denial must still be in place"

  chmod 755 "$prefix/share"
  fault_reset
  rc=0
  fault_run bash "$REPAIR" --prefix "$prefix" >"$work/rperm2.log" 2>&1 || rc=$?
  assert_eq "0" "$rc" "the repair must succeed once the directory is writable"
  assert_true test -f "$prefix/share/shellkit/lib/bootstrap.sh"
  assert_eq "USER-MARK" "$(cat "$prefix/share/shellkit/USER.txt")" "the user file must be restored"

else
  printf '%s\n' 'NA repair|permission: running as root, chmod cannot deny uid 0 (issue #76)'
fi

# CASE: repair|signal —— 恢复中（旧副本正在挪回）被杀 ⇒ 重跑接上
prefix=$(new_prefix rsig) || _fail "repair setup failed"

fault_reset
fault_scope "$prefix"
fault_signal_kill rename after 1
rc=0
fault_run bash "$REPAIR" --prefix "$prefix" >"$work/rsig.log" 2>&1 || rc=$?
assert_ne "0" "$rc" "the killed repair must not report success"
assert_true fault_trace_has "sig when=after stage=rename"
# 挪回这一步已落地：主副本完整，用户数据在
assert_true test -f "$prefix/share/shellkit/lib/bootstrap.sh"
assert_eq "USER-MARK" "$(cat "$prefix/share/shellkit/USER.txt")" \
  "the user file must survive the kill"

fault_reset
rc=0
fault_run bash "$REPAIR" --prefix "$prefix" >"$work/rsig2.log" 2>&1 || rc=$?
assert_eq "0" "$rc" "the rerun must converge after the interruption"
assert_true test -f "$prefix/share/shellkit/lib/bootstrap.sh"

printf '%s\n' 'NA repair|diskfull: repair 只做整目录 rename 与 rm、不写文件内容；同文件系统 rename 不消耗目标目录空间，ENOSPC 不改变状态机可达的终态，故本格不适用'

# ---------------------------------------------------------------- config 行
#
# 配置层的写入是「同目录临时文件 + mv」：临时文件写不完（磁盘满 / 配额）时，
# 如果把写失败的状态丢掉，mv 会把**半截**配置换上去，调用方还拿到 0 ——
# 用户数据静默损坏，而且没有任何提示。这一行钉的就是这件事。
cdir="$work/config"
mkdir -p "$cdir"

# config_driver DIR —— 只做一次配置写操作的小驱动
# 必须是被 fault_run 拉起的独立进程：ulimit -f 是进程级的，
# 在测试脚本自己身上生效会把后面的用例一起限死。
# 第三个参数选操作：set（默认）/ unset / disable —— 三个入口共用同一套
# 「临时文件 + mv」，漏掉任何一个都会静默损坏配置，所以三个都要钉。
config_driver() {
  local __dir=$1
  local __drv="$__dir/drive.sh"
  cat >"$__drv" <<'DRV'
#!/usr/bin/env bash
set -u
. "$1/lib/bootstrap.sh" log fs config >/dev/null 2>&1
export SK_CONF_FILE="$2"
conf_init "$2" >/dev/null 2>&1
case "${3:-set}" in
  unset) conf_unset KEY_010 ;;
  disable) conf_disable KEY_010 ;;
  *) conf_set NEW_KEY "a-very-long-value-that-cannot-fit-into-the-size-limit" ;;
esac
DRV
  printf '%s' "$__drv"
}

# config_fixture PATH —— 200 行的既有配置（约 3KB）
#
# 为什么要这么大：上限是「一个 ulimit -f 块」（512 字节），但 macOS 实测
# RLIMIT_FSIZE=1 块时实际能写到 1KB（页粒度）—— 配置比 1KB 小的时候注入
# 根本不发生，这一格会**恒绿**（假通过）。文件连同新键明显超过 1KB，
# 两种粒度下都必然写不完。
config_fixture() {
  local __f=$1 __i=0
  : >"$__f"
  while [ "$__i" -lt 200 ]; do
    printf 'KEY_%03d=value-%03d\n' "$__i" "$__i" >>"$__f"
    __i=$((__i + 1))
  done
}

# CASE: config|diskfull —— 临时文件写不完 ⇒ 三个写入口都必须失败，配置一个字节都不变
drv=$(config_driver "$cdir")
fault_reset
fault_scope "$cdir"
fault_disk_full_limit 512
for op in set unset disable; do
  cfg="$cdir/app.$op.env"
  config_fixture "$cfg"
  sum_before=$(file_sum "$cfg")
  rc=0
  fault_run bash "$drv" "$TEST_ROOT" "$cfg" "$op" >"$work/cfgfull.$op.log" 2>&1 || rc=$?
  assert_ne "0" "$rc" "conf_$op must report failure when the temp file cannot be written"
  assert_eq "$sum_before" "$(file_sum "$cfg")" \
    "conf_$op must keep the exact old content (a half-written temp must never be renamed in)"
  assert_eq "KEY_199=value-199" "$(tail -n 1 "$cfg")" \
    "conf_$op must keep the last line of the old configuration"
  # 残骸计数用 glob，不用 ls|grep（SC2010：ls 的输出本来就不该被解析）
  leftover=0
  for __res in "$cdir/app.$op.env.tmp."*; do
    [ -e "$__res" ] || continue
    leftover=$((leftover + 1))
  done
  assert_eq "0" "$leftover" "conf_$op must not leave temp residue behind"
done

# CASE: config|permission —— 建不了临时文件 ⇒ 明确失败，配置不动
if fault_perm_usable; then
  pcdir="$work/config-perm"
  mkdir -p "$pcdir"
  pcfg="$pcdir/app.set.env"
  config_fixture "$pcfg"
  psum=$(file_sum "$pcfg")
  pdrv=$(config_driver "$pcdir")
  chmod 500 "$pcdir" || _fail "cannot make the config directory read-only"
  rc=0
  fault_run bash "$pdrv" "$TEST_ROOT" "$pcfg" >"$work/cfgperm.log" 2>&1 || rc=$?
  chmod 700 "$pcdir" 2>/dev/null || true
  assert_ne "0" "$rc" "conf_set must fail when the temp file cannot be created"
  assert_eq "$psum" "$(file_sum "$pcfg")" "a refused write must leave the configuration untouched"
else
  printf '%s\n' 'NA config|permission: running as root, chmod cannot deny uid 0 (issue #76)'
fi

printf '%s\n' 'NA config|signal: 每次写都是「同目录临时文件 + rename」的原子替换，目标永远是完整的旧值或新值；被杀只会留下 .tmp 残骸 —— 与本行磁盘满格同构，且 conf_set 没有两阶段提交'
printf '%s\n' 'NA config|concurrent: 配置层不承诺并发合并（没有锁也没有三方合并），两个 conf_set 并发是 last-writer-wins，且每次改名都完整；要的是「不半截」而不是「都留下」，那一半由上面两格覆盖'

# ---------------------------------------------------------------- backup 行
#
# fs_backup 是「改之前留一份旧的」。它以前是 cp -p 直接写最终名字：写到一半被
# 打断（磁盘满 / 配额 / 断电 / 被杀）会留下**半截备份** —— 既不是旧内容也不是
# 新内容，而轮转按名字计数，那份半截文件会顶掉一份完好的旧备份。
# 这一格钉的是「失败时不产出备份」，不是「产出一份坏的」。
bdir="$work/backup"
mkdir -p "$bdir"

# backup_driver DIR —— 只做一次 fs_backup 的小驱动
# 与 config_driver 同理：ulimit -f 是进程级的，必须在 fault_run 拉起的独立进程里生效。
backup_driver() {
  local __dir=$1
  local __drv="$__dir/drive.sh"
  cat >"$__drv" <<'DRV'
#!/usr/bin/env bash
set -u
. "$1/lib/bootstrap.sh" log fs >/dev/null 2>&1
fs_backup "$2" 3
DRV
  printf '%s' "$__drv"
}

# CASE: backup|diskfull —— 备份写不完 ⇒ 明确失败，源文件与旧备份都不受损
bdrv=$(backup_driver "$bdir")
bsrc="$bdir/app.conf"
# 复用 config 行的 200 行夹具（约 3KB）：必须明显超过 macOS 的 1KB 页粒度上限，
# 否则 ulimit 注入根本不发生，这一格会恒绿（假通过）。
config_fixture "$bsrc"
bsum=$(file_sum "$bsrc")
fault_reset
fault_scope "$bdir"
fault_disk_full_limit 512
rc=0
fault_run bash "$bdrv" "$TEST_ROOT" "$bsrc" >"$work/bkfull.log" 2>&1 || rc=$?
assert_ne "0" "$rc" "fs_backup must report failure when the copy cannot be written"
assert_eq "$bsum" "$(file_sum "$bsrc")" "a failed backup must not touch the source file"
leftover=0
for __bk in "$bsrc".bak.*; do
  [ -e "$__bk" ] || continue
  leftover=$((leftover + 1))
done
assert_eq "0" "$leftover" "a failed backup must not leave a half-written .bak file behind"
fault_reset
printf '%s\n' 'CELL backup|diskfull -> 本节 CASE（RLIMIT_FSIZE 内核层，判据：非 0 退出 + 无 .bak 残骸 + 源不变）'

printf '%s\n' 'NA backup|permission: 备份只读源、只新增文件，建不了临时文件时 mktemp 直接失败、源文件不在写入路径上；这条与 config|permission 同一套 mktemp 口径，不重复注入'
printf '%s\n' 'NA backup|signal: 备份是「同目录临时文件 + rename」，目标只可能是完整旧值或完整新值，被杀只留 .tmp 残骸（轮转按名计数时已跳过 *.tmp.*）—— 与 config|signal 同构'
printf '%s\n' 'NA backup|concurrent: 两个并发备份各拿各的名字（pid + 序号），轮转是 last-writer-wins：并发下可能多删一份最旧的，但不会出现半截文件 —— 本行要的是「不半截」而不是「都留下」'

printf '%s\n' 'matrix: 25 cells - 15 new cases, 3 cross-referenced (upgrade row), 7 not-applicable'
exit 0
