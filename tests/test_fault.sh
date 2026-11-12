#!/usr/bin/env bash
# 故障注入辅助层（tests/lib/fault.sh）的自证用例。
#
# 判据能力是硬要求：**每条用例都要能证明「注入生效时被测路径真的失败了」**。
# 所以每条用例都断言三件事：
#   1) 注入确实发生了   —— 注入痕迹里有对应的那一条（不是「什么都没发生」）；
#   2) 被测路径真的失败 —— 命令退出码非 0（不是「恰好成功了」）；
#   3) 磁盘最终状态可预期 —— 走统一的观察契约 fault_snapshot：
#      目标文件是旧是新还是半截、清单完不完整、用户的数据还在不在。
#
# 只断一个单词是不够的：路径里带什么词都会让断言恒真。所以每条用例都同时
# 断「结构事实」（sha256、文件大小、目录里有没有残留），
# 断「完整文案」（如 "another instance is running"）。
#
# 快慢取舍：写路径上的注入（磁盘满、权限）直接打库里的真入口
# fs_atomic_copy —— 判据更准，也不用每次都跑一整轮升级。
# 清单提交、并发、信号这三件事只在真升级里才存在，才跑完整的 CLI。
#
# TEST_TIMEOUT: 300 —— 故障注入天然慢：真升级要渲染模板 + 同步 vendor 副本
# （上百个文件），本机实测一轮几十秒。默认上限 300 秒正好。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fault.sh"

work=$(tmpdir)
locks="$work/locks"
mkdir -p "$locks"
export SHELLKIT_LOCK_DIR="$locks"

# ---- 改过的模板：让升级真的有事可做 ----
#
# lib/app.sh 里没有任何占位符 ⇒ 渲染后的内容与模板逐字相同 ⇒
# 「旧版本」与「新版本」都是已知的字节，判据不靠猜。
tpl="$work/tpl"
cp -R "$TEST_ROOT/templates" "$tpl"
printf '#!/usr/bin/env bash\n# fault-test new content\n' >"$tpl/lib/app.sh"

owned="bin/tool lib/app.sh README.md AGENTS.md Makefile .shellcheckrc tests/test_helper.sh tests/run.sh"

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

# manifest_sum PROJECT REL —— 清单里记的基线
manifest_sum() {
  awk -v rel="$2" '$1 == "@file" && $2 == rel { print $3; exit }' "$1/.shellkit-manifest"
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

# trace_field LINE KEY —— 从痕迹行里取一个字段（纯 bash，不用管道）
trace_field() {
  local __line=$1 __key=$2 __rest
  case "$__line" in
    *"$__key="*) ;;
    *)
      return 1
      ;;
  esac
  __rest="${__line#*"$__key="}"
  printf '%s' "${__rest%% *}"
}

# run_atomic_copy SRC DST —— 用库里的真写文件入口跑一次原子写（带注入）
run_atomic_copy() {
  fault_run bash -c '. "$1/lib/bootstrap.sh"; fs_atomic_copy "$2" "$3"' \
    _ "$TEST_ROOT" "$1" "$2"
}

# ---- 基线工程：只造一次，后面每条用例拷一份 ----
#
# 每条用例都跑真升级，而一次真升级要同步 vendor 副本（上百个文件）——
# 现造一个工程是整轮测试里最贵的一步。造一次、拷贝复用，判据不变。
base="$work/base"
"$TEST_ROOT/shellkit" new "$base" --name tool --cmd run --yes >/dev/null 2>&1
# 基线工程必须是完整的：它不完整的话，后面每条用例的失败原因都会被带偏
# （工程缺文件 → 升级报「不像 shellkit 生成的工程」→ 看起来像注入生效了）。
if [ ! -f "$base/.shellkit-manifest" ] || [ ! -f "$base/lib/app.sh" ]; then
  _fail "the base project is incomplete: shellkit new did not finish"
fi
# 用户自己加的文件：升级不许动它
printf 'MINE\n' >"$base/user-note.txt"

# new_project NAME —— 造一个带用户自有文件的干净工程，返回工程目录
new_project() {
  local __p="$work/$1"
  cp -R "$base" "$__p"
  printf '%s\n' "$__p"
}

# =============================================================================
# CASE: 磁盘满（ENOSPC 替身）在写路径上真的失败，目标仍是旧的完整内容
# =============================================================================
# 机制：copy 替身写到一半就报 No space left on device（macOS 没有 cgroup 配额，
# 真造不出磁盘满）。被测路径是库里真正的写文件入口 fs_atomic_copy。
d="$work/atomic"
mkdir -p "$d"
printf 'OLD-CONTENT\n' >"$d/target.txt"
cp "$d/target.txt" "$d/old.txt"
head -c 4096 /dev/urandom >"$d/source.txt"

fault_reset
fault_enospc_scope "$d"
rc=0
run_atomic_copy "$d/source.txt" "$d/target.txt" >"$d/out.log" 2>&1 || rc=$?
assert_ne "0" "$rc" "the injected disk-full must make the write fail"

# 注入确实发生了，而且临时文件只写了一半
assert_true fault_trace_has "enospc wrote="
__line=$(fault_trace_line "enospc wrote=")
__wrote=$(trace_field "$__line" wrote)
__of=$(trace_field "$__line" of)
if [ "$__wrote" -le 0 ] || [ "$__wrote" -ge "$__of" ]; then
  _fail "the temp file must be half-written: wrote=$__wrote of=$__of"
fi

# rename 没发生 ⇒ 目标仍是旧的完整内容（不是半截）
assert_eq "old" "$(fault_file_state "$d/target.txt" "$d/old.txt" "$d/source.txt")" \
  "the target must keep the old complete content"
assert_eq "$(file_sum "$d/old.txt")" "$(file_sum "$d/target.txt")" \
  "the target must be byte-identical to the old content"
assert_eq "0" "$(fault_count_tmp "$d" "*.tmp.*")" \
  "the directory must not keep a half-written temp file"

# =============================================================================
# CASE: 磁盘满（内核 RLIMIT_FSIZE）真的被内核拒绝，目标仍是旧的完整内容
# =============================================================================
# 机制：ulimit -f（RLIMIT_FSIZE，单位 512 字节块）。它是**进程级**的，
# 所以只能靠 fault_run 把它限制在被测命令的子 shell 里 ——
# 测试脚本自己不受影响。忽略 SIGXFSZ 是关键：超限要变成「写失败」，
# 而不是把被测进程打死（那是信号注入，不是磁盘满）。
d2="$work/atomic2"
mkdir -p "$d2"
printf 'OLD-CONTENT\n' >"$d2/target.txt"
cp "$d2/target.txt" "$d2/old.txt"
head -c 4096 /dev/urandom >"$d2/source.txt"

fault_reset
fault_disk_full_limit 512
rc=0
run_atomic_copy "$d2/source.txt" "$d2/target.txt" >"$d2/out.log" 2>&1 || rc=$?
assert_ne "0" "$rc" "the kernel file-size limit must make the write fail"
assert_eq "old" "$(fault_file_state "$d2/target.txt" "$d2/old.txt" "$d2/source.txt")" \
  "the target must keep the old complete content"
assert_eq "$(file_sum "$d2/old.txt")" "$(file_sum "$d2/target.txt")" \
  "the target must be byte-identical to the old content"
assert_eq "0" "$(fault_count_tmp "$d2" "*.tmp.*")" \
  "the directory must not keep a half-written temp file"

# =============================================================================
# CASE: 磁盘满（ENOSPC 替身）在真实升级上：升级失败，工程里没有半截文件
# =============================================================================
proj=$(new_project enospc)
cp "$proj/bin/tool" "$work/enospc-bin.old"
cp "$proj/lib/app.sh" "$work/enospc-app.old"
usersum=$(file_sum "$proj/user-note.txt")

fault_reset
fault_scope "$proj"
fault_enospc_scope "$proj"
rc=0
fault_run "$TEST_ROOT/shellkit" upgrade "$proj" --template "$tpl" >"$work/enospc.log" 2>&1 || rc=$?
assert_ne "0" "$rc" "the injected disk-full must make the upgrade fail"
assert_true fault_trace_has "enospc wrote="

snap=$(fault_snapshot "$proj/lib/app.sh" "$work/enospc-app.old" "$tpl/lib/app.sh" \
  "$proj/.shellkit-manifest" "$proj/user-note.txt" "$usersum")
assert_eq "old" "$(snap_get "$snap" target.state)" \
  "the target must keep the old complete content"
assert_eq "0" "$(snap_get "$snap" target.leftovers)" \
  "the project must not keep a half-written temp file"
assert_eq "complete" "$(snap_get "$snap" manifest.state)" \
  "the manifest must stay complete"
assert_eq "intact" "$(snap_get "$snap" user.state)" \
  "the user's own file must survive"
# 第一个被写的文件也必须原封不动
assert_eq "$(file_sum "$work/enospc-bin.old")" "$(file_sum "$proj/bin/tool")" \
  "the first replaced file must be untouched"

# =============================================================================
# CASE: 权限拒绝（写前）：写真的失败，目标目录里没有留下半成品
# =============================================================================
# 机制：临时文件是靠「目录可写」建出来的 —— 目录不可写时连临时文件都建不出来。
# 注入是**一次性**的：拒绝这一次之后权限立刻恢复（否则连临时文件都删不掉，
# 测到的就不是「写失败」，而是「目录整个坏了」）。
d3="$work/permwrite"
mkdir -p "$d3"
printf 'OLD-CONTENT\n' >"$d3/target.txt"
cp "$d3/target.txt" "$d3/old.txt"
printf 'NEW-CONTENT\n' >"$d3/source.txt"

fault_reset
fault_perm_deny "$d3/target.txt" write
rc=0
run_atomic_copy "$d3/source.txt" "$d3/target.txt" >"$d3/out.log" 2>&1 || rc=$?
assert_ne "0" "$rc" "the injected permission denial must make the write fail"
assert_true fault_trace_has "perm stage=write"
assert_eq "old" "$(fault_file_state "$d3/target.txt" "$d3/old.txt" "$d3/source.txt")" \
  "the target must keep the old complete content"
assert_eq "0" "$(fault_count_tmp "$d3" "*.tmp.*")" \
  "the directory must not keep a half-written temp file"

# =============================================================================
# CASE: 权限拒绝（rename 前）：写真的失败，目标仍是旧的完整内容
# =============================================================================
# 机制：临时文件已经写好、正要 rename 落到目标时，目录被改成不可写 ——
# rename 换不了名（macOS 与 Linux 语义一致：换名要的是目录的写权限）。
d4="$work/permrename"
mkdir -p "$d4"
printf 'OLD-CONTENT\n' >"$d4/target.txt"
cp "$d4/target.txt" "$d4/old.txt"
printf 'NEW-CONTENT\n' >"$d4/source.txt"

fault_reset
fault_perm_deny "$d4/target.txt" rename
rc=0
run_atomic_copy "$d4/source.txt" "$d4/target.txt" >"$d4/out.log" 2>&1 || rc=$?
assert_ne "0" "$rc" "the injected permission denial must make the write fail"
assert_true fault_trace_has "perm stage=rename"
assert_eq "old" "$(fault_file_state "$d4/target.txt" "$d4/old.txt" "$d4/source.txt")" \
  "the target must keep the old complete content"
assert_eq "0" "$(fault_count_tmp "$d4" "*.tmp.*")" \
  "the directory must not keep a half-written temp file"

# =============================================================================
# CASE: 权限拒绝持续存在：目标仍是完整的，但临时文件删不掉
# =============================================================================
# 与上面两条的区别：权限不恢复（真实的「磁盘只读 / 权限被改错」现场）。
# 目标文件仍然是旧的完整内容（rename 没发生），但目录不可写 ⇒ 连临时文件
# 都删不掉，磁盘上会留下残骸。这条把「一次性注入」与「持续故障」的差别
# 钉在用例里，免得以后只测前者就以为后者也干净。
d5="$work/permsticky"
mkdir -p "$d5"
printf 'OLD-CONTENT\n' >"$d5/target.txt"
cp "$d5/target.txt" "$d5/old.txt"
printf 'NEW-CONTENT\n' >"$d5/source.txt"

fault_reset
fault_perm_deny_sticky "$d5/target.txt" rename
rc=0
run_atomic_copy "$d5/source.txt" "$d5/target.txt" >"$d5/out.log" 2>&1 || rc=$?
assert_ne "0" "$rc" "the injected permission denial must make the write fail"
assert_true fault_trace_has "perm stage=rename"
assert_eq "old" "$(fault_file_state "$d5/target.txt" "$d5/old.txt" "$d5/source.txt")" \
  "the target must keep the old complete content"
assert_eq "1" "$(fault_count_tmp "$d5" "*.tmp.*")" \
  "the temp file cannot be removed while the directory stays unwritable"
chmod 700 "$d5"

# =============================================================================
# CASE: 权限拒绝（清单提交前）：文件换了新，清单还是旧的完整内容
# =============================================================================
proj=$(new_project permmanifest)
cp "$proj/lib/app.sh" "$work/permmanifest-app.old"
cp "$proj/.shellkit-manifest" "$work/permmanifest-manifest.old"
usersum=$(file_sum "$proj/user-note.txt")

fault_reset
fault_scope "$proj"
fault_perm_deny "$proj/.shellkit-manifest" manifest
rc=0
fault_run "$TEST_ROOT/shellkit" upgrade "$proj" --template "$tpl" >"$work/permmanifest.log" 2>&1 || rc=$?
assert_ne "0" "$rc" "the injected permission denial must make the upgrade fail"
assert_true fault_trace_has "perm stage=manifest"

snap=$(fault_snapshot "$proj/lib/app.sh" "$work/permmanifest-app.old" "$tpl/lib/app.sh" \
  "$proj/.shellkit-manifest" "$proj/user-note.txt" "$usersum")
# 文件已经整体换成新内容（不是半截）
assert_eq "new" "$(snap_get "$snap" target.state)" \
  "the file must be replaced as a whole before the manifest commit"
# 清单提交失败 ⇒ 还是旧的那份，而且完整
assert_eq "complete" "$(snap_get "$snap" manifest.state)" \
  "the manifest must stay complete"
assert_eq "$(file_sum "$work/permmanifest-manifest.old")" "$(file_sum "$proj/.shellkit-manifest")" \
  "the manifest must still be the old one"
assert_eq "0" "$(snap_get "$snap" manifest.leftovers)" \
  "the manifest must not leave a half-written temp file"
assert_eq "intact" "$(snap_get "$snap" user.state)" \
  "the user's own file must survive"
# 这一轮的账没结清 ⇒ 升级日志必须留着（下次恢复的唯一依据）
assert_true test -f "$proj/.shellkit-upgrade-journal"

# =============================================================================
# CASE: 并发：第二个实例明确失败，清单内容完整
# =============================================================================
proj=$(new_project concurrent)
cp "$proj/lib/app.sh" "$work/concurrent-app.old"
usersum=$(file_sum "$proj/user-note.txt")

fault_reset
fault_scope "$proj"
fault_gate_arm rename
fault_concurrent_start "$TEST_ROOT/shellkit" upgrade "$proj" --template "$tpl"
if ! fault_gate_wait 60; then
  _fail "the first instance must reach the blocked rename"
fi

# 第一个实例此刻持着工程锁 ⇒ 第二个实例必须明确失败，而不是两份清单互相覆盖
rc=0
out=$(fault_run "$TEST_ROOT/shellkit" upgrade "$proj" --template "$tpl" 2>&1) || rc=$?
assert_ne "0" "$rc" "the second instance must not report success"
assert_contains "$out" "another instance is running"

# 放行第一个实例：它必须把这一轮做完
fault_gate_open
rc=0
fault_concurrent_wait || rc=$?
assert_eq "0" "$rc" "the first instance must finish once the gate opens"

snap=$(fault_snapshot "$proj/lib/app.sh" "$work/concurrent-app.old" "$tpl/lib/app.sh" \
  "$proj/.shellkit-manifest" "$proj/user-note.txt" "$usersum")
assert_eq "complete" "$(snap_get "$snap" manifest.state)" \
  "the manifest must stay complete"
assert_eq "0" "$(snap_get "$snap" manifest.leftovers)" \
  "the manifest must not leave a half-written temp file"
assert_eq "intact" "$(snap_get "$snap" user.state)" \
  "the user's own file must survive"

# =============================================================================
# CASE: 信号：在指定时机被杀，重跑后能恢复
# =============================================================================
proj=$(new_project signal)

fault_reset
fault_scope "$proj"
fault_signal_kill rename after 1
rc=0
fault_run "$TEST_ROOT/shellkit" upgrade "$proj" --template "$tpl" >"$work/signal.log" 2>&1 || rc=$?
assert_ne "0" "$rc" "the killed upgrade must not report success"
assert_true fault_trace_has "sig when=after stage=rename"

# 崩在「文件已换新、清单还没提交」的窗口：升级日志必须在
assert_true test -f "$proj/.shellkit-upgrade-journal"
# 恰好一个文件在清单前面
ahead=0
for rel in $owned; do
  if [ -f "$proj/$rel" ]; then
    want=$(file_sum "$proj/$rel")
    got=$(manifest_sum "$proj" "$rel")
    if [ "$want" != "$got" ]; then
      ahead=$((ahead + 1))
    fi
  fi
done
assert_eq "1" "$ahead" "exactly one file must be ahead of the manifest after the kill"

# 重跑：必须恢复，且没有任何文件被冻结（清单基线必须与磁盘一致）
fault_reset
out=$(fault_run "$TEST_ROOT/shellkit" upgrade "$proj" --template "$tpl" 2>&1)
assert_contains "$out" "upgrade finished"
assert_false test -e "$proj/.shellkit-upgrade-journal"
for rel in $owned; do
  want=$(file_sum "$proj/$rel")
  got=$(manifest_sum "$proj" "$rel")
  assert_eq "$want" "$got" "no file may stay frozen after the recovery: $rel"
done

exit 0
