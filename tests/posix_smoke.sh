#!/bin/sh
#
# POSIX 子集的冒烟判据：设备侧那一层（进程与看门狗）。
#
# 为什么单独一份、而且只用 POSIX sh 语法：
#   tests/test_posix.sh 用 bash 驱动（_posix '...'），只能在本机的 dash 上跑；
#   这一份**自己就是 POSIX sh 脚本** ⇒ 同一份判据能在 busybox ash 上原样跑
#   （CI 的 "posix subset on busybox ash" job 就是这么跑的）
#   ⇒ 设备侧的真环境被真判据验到，而不是「在 macOS 的 bash 上假装是 ash」。
#
# 判据必须有承重：最后一节把缺陷造回去（变异自证），场景必须变红 ——
# 否则这些断言只是在测「文件存在」，测不出「设备侧能不能用」。
#
# shellcheck disable=SC2016
# 下面几处单引号里的 $ 是**要原样传给 sed/grep 的模式**（它们要匹配
# 源码里的 $_sp_go_pgid 这类字面量），不是当前 shell 的变量。
set -u

LIB="${SK_POSIX_LIB:-}"
if [ -z "$LIB" ]; then
  LIB="$(cd "$(dirname "$0")/.." && pwd)/lib/posix/shellkit-posix.sh"
fi
if [ ! -f "$LIB" ]; then
  printf 'FAIL: the POSIX subset is missing: %s
' "$LIB" >&2
  exit 1
fi

TMP="${TMPDIR:-/tmp}/sk-posix-smoke.$$"
rm -rf "$TMP"
mkdir -p "$TMP" || exit 1
trap 'rm -rf "$TMP"' 0 1 2 15

FAILS=0
# 名字叫 smoke_fail 而不是 fail：POSIX 子集自己有一个公开的 fail()
# （库里的 die/fail 那一对）⇒ 这里再定义一个 fail 会**顶掉库里的那个**
# （后定义覆盖先定义）⇒ 失败会被记成「库报了一条错误」，计数不上去 ⇒
# 整份判据变成假绿。这正是 dup-functions 门禁要防的那类事故。
smoke_fail() {
  printf 'FAIL: %s
' "$1" >&2
  FAILS=$((FAILS + 1))
}

# ---- 被测库 ----
# shellcheck disable=SC1090
. "$LIB" || exit 1

PROCDIR="$TMP/proc"
mkdir -p "$PROCDIR"
SHELLKIT_PROC_DIR="$PROCDIR"
export SHELLKIT_PROC_DIR

# 探针：变异自证要用「另一份库」跑同一个判定 ⇒ 判定与库要能分开跑。
# 写成独立文件（而不是把代码塞进 sh -c 的引号里）—— 嵌套引号太脆，
# 一旦引号写错，报的是「语法错误」而不是「判定不成立」。
cat >"$TMP/probe_running.sh" <<'PROBE'
#!/bin/sh
# $1 = 库, $2 = 名字, $3 = pid 文件
. "$1" || exit 99
SHELLKIT_PROC_DIR="$(dirname "$3")" || exit 98
proc_is_running "$2"
PROBE
cat >"$TMP/probe_group.sh" <<'PROBE'
#!/bin/sh
# $1 = 库, $2 = 目标 pid
. "$1" || exit 99
_sk_posix_proc_group_of "$2"
PROBE

# _alive PID —— 这个 pid 上还有**活**进程吗（僵尸不算）
#   用库里那个判据（它把僵尸算死）⇒ 验的是「整组停之后子进程真的没了」，
#   不是「进程表里还有那个条目」。
_alive() {
  _sk_posix_proc_alive "$1"
}

# ---- CASE 1：拉起来、探活、pid 文件 ----
if proc_start demo sh -c 'sleep 300'; then
  :
else
  smoke_fail "proc_start must start the process"
fi
if [ -s "$PROCDIR/demo.pid" ]; then
  :
else
  smoke_fail "proc_start must write the pid file"
fi
DEMO_PID=$(cat "$PROCDIR/demo.pid" 2>/dev/null || true)
if proc_is_running demo; then
  :
else
  smoke_fail "proc_is_running must report the process as running"
fi
if [ -n "$DEMO_PID" ] && _alive "$DEMO_PID"; then
  :
else
  smoke_fail "the pid file must point at a live process"
fi

# ---- CASE 2：已经在跑 ⇒ 不再来一份 ----
proc_start demo sh -c 'sleep 300'
RC=$?
if [ "$RC" != "3" ]; then
  smoke_fail "starting an already running process must exit 3 (got $RC)"
fi

# ---- CASE 3：日志是**追加**，不截断（上次的现场不能被抹掉）----
printf 'marker-from-the-last-run
' >"$PROCDIR/demo.log"
proc_stop demo
if proc_start demo sh -c 'sleep 300'; then
  :
else
  smoke_fail "proc_start must work again after the process was stopped"
fi
if grep -q 'marker-from-the-last-run' "$PROCDIR/demo.log" 2>/dev/null; then
  :
else
  smoke_fail "the log file must be appended to, not truncated"
fi

# ---- CASE 4：停掉 ⇒ pid 文件清掉、进程真的没了 ----
DEMO_PID=$(cat "$PROCDIR/demo.pid" 2>/dev/null || true)
proc_stop demo
RC=$?
if [ "$RC" != "0" ]; then
  smoke_fail "proc_stop must exit 0 (got $RC)"
fi
if [ -f "$PROCDIR/demo.pid" ]; then
  smoke_fail "proc_stop must remove the pid file"
fi
if [ -n "$DEMO_PID" ] && _alive "$DEMO_PID"; then
  smoke_fail "proc_stop must actually stop the process"
fi
# 停一个没在跑的东西是成功，不是错误
proc_stop demo
RC=$?
if [ "$RC" != "0" ]; then
  smoke_fail "stopping a process that is not running must exit 0 (got $RC)"
fi

# ---- CASE 5：名字非法 ⇒ 用法错（名字会变成路径）----
proc_start "../evil" sh -c 'sleep 300' 2>/dev/null
RC=$?
if [ "$RC" != "2" ]; then
  smoke_fail "an invalid process name must exit 2 (got $RC)"
fi
proc_stop "../evil" 2>/dev/null
RC=$?
if [ "$RC" != "2" ]; then
  smoke_fail "an invalid process name must exit 2 on stop (got $RC)"
fi

# ---- CASE 6：命令不存在 ⇒ 前置条件不满足 ----
proc_start missing no-such-command-xyz 2>/dev/null
RC=$?
if [ "$RC" != "3" ]; then
  smoke_fail "a missing command must exit 3 (got $RC)"
fi

# ---- CASE 6b：命令起来就退出 ⇒ 明确报错（不是「成功」）----
#   拉起来就崩（命令不存在、参数错、立刻退出）必须报出来，
#   否则调用方会以为「已经在跑了」⇒ 后面所有步骤都建立在假事实上。
proc_start boom sh -c 'exit 3' 2>/dev/null
RC=$?
if [ "$RC" != "1" ]; then
  smoke_fail "a command that exits immediately must exit 1 (got $RC)"
fi
if [ -f "$PROCDIR/boom.pid" ]; then
  smoke_fail "a command that exited immediately must not leave a pid file behind"
fi

# ---- CASE 7：僵尸 pid 文件（进程早没了）⇒ 判成没在跑并清掉 ----
printf '999999
' >"$PROCDIR/stale.pid"
proc_is_running stale
RC=$?
if [ "$RC" != "1" ]; then
  smoke_fail "a stale pid file must be reported as not running (got $RC)"
fi
if [ -f "$PROCDIR/stale.pid" ]; then
  smoke_fail "a stale pid file must be cleaned up"
fi

# ---- CASE 8：真僵尸（进程已退出但还占着进程表）⇒ 判成「没在跑」----
# 这是 issue 点名的负对照：kill -0 对僵尸仍然成功 ⇒ 只用 kill -0 判活
# ⇒ 僵尸 pid 文件永远清不掉、看门狗永远以为进程还在。
#
# 造法（与主库 tests/test_proc.sh 同一套）：子进程退出、父亲还活着且不回收
# ⇒ 进程表里留着 Z 态。exec 是关键：exec 把那个 shell 换掉，
# 换掉的进程才是僵尸原来的父亲 ⇒ 没人回收它。
#
# ⚠ 那个「不回收」的父亲要活到**变异自证跑完**（僵尸必须还在）⇒
#   它的清理放在最后（cleanup 段），不是这里。
ZPIDFILE="$PROCDIR/zombie.pid"
rm -f "$ZPIDFILE"
sh -c 'sleep 1 & echo $! > "$1"; exec sleep 60' sk "$ZPIDFILE" &
ZPARENT=$!
ZI=0
ZPID=""
ZSTATE=""
while [ "$ZI" -lt 60 ]; do
  if [ -s "$ZPIDFILE" ]; then
    ZPID=$(cat "$ZPIDFILE" 2>/dev/null || true)
    if [ -n "$ZPID" ]; then
      ZSTATE=$(_sk_posix_proc_state "$ZPID" 2>/dev/null || true)
      case "$ZSTATE" in
        Z*) break ;;
      esac
    fi
  fi
  sleep 0.1
  ZI=$((ZI + 1))
done
if [ -z "$ZPID" ] || [ "$ZSTATE" = "${ZSTATE#Z}" ]; then
  smoke_fail "the test could not create a real zombie process (state: ${ZSTATE:-none})"
else
  proc_is_running zombie
  RC=$?
  if [ "$RC" != "1" ]; then
    smoke_fail "a zombie process must be reported as not running (got $RC)"
  fi
  if [ -f "$ZPIDFILE" ]; then
    smoke_fail "a zombie pid file must be cleaned up"
  fi
fi

# ---- CASE 9：整组停止（只停主进程 ⇒ 子进程残留、端口还占着）----
#
# 整组停要**拿得到进程组**：进程组来自 setsid（新建一个会话）。
# 没有 setsid 的机器（macOS 没有这个命令）⇒ 这一层按设计退化成
# 「只停主进程」⇒ 子进程会残留 ⇒ 那不是缺陷，是**说好的降级**。
# ⇒ 有 setsid 才断言「子进程也没了」，没有就断言「主进程没了」+ 明说跳过。
CHILDPID="$TMP/child.pid"
rm -f "$CHILDPID"
if proc_start grp sh -c "sleep 300 & echo \$! > '$CHILDPID'; wait" 2>/dev/null; then
  :
else
  smoke_fail "proc_start must start a process with a child"
fi
CI=0
CPID=""
while [ "$CI" -lt 40 ]; do
  if [ -s "$CHILDPID" ]; then
    CPID=$(cat "$CHILDPID" 2>/dev/null || true)
    if [ -n "$CPID" ]; then
      break
    fi
  fi
  sleep 0.1
  CI=$((CI + 1))
done
GRPPID=$(cat "$PROCDIR/grp.pid" 2>/dev/null || true)
proc_stop grp
RC=$?
if [ "$RC" != "0" ]; then
  smoke_fail "proc_stop must exit 0 (got $RC)"
fi
if [ -n "$GRPPID" ] && _alive "$GRPPID"; then
  smoke_fail "proc_stop must actually stop the main process"
fi
if [ -n "$CPID" ]; then
  if command -v setsid >/dev/null 2>&1; then
    if _alive "$CPID"; then
      smoke_fail "the whole process group must be stopped (the child survived)"
    fi
  else
    printf 'SKIP: no setsid on this machine, the group stop degrades to stopping the main process only
' >&2
    kill "$CPID" 2>/dev/null || true
  fi
else
  printf 'SKIP: the child pid was never reported, the group stop was not verified
' >&2
fi

# ---- CASE 10：绝不自杀（整组停不能打到自己所在的组）----
# 判据用**自己所在组的组长**当目标：它的 pgid == 它的 pid（是组长），
# 而那个组就是我们自己的组 ⇒ 必须被拒绝。
# 少了这条守卫 ⇒ kill -TERM -PGID 会把调用方一起打死（静默自杀，退出码 143）。
OURPGID=$(_sk_posix_proc_self_pgid 2>/dev/null || true)
if [ -n "$OURPGID" ]; then
  if _sk_posix_proc_group_of "$OURPGID" >/dev/null 2>&1; then
    smoke_fail "the group stop must refuse to target our own process group (it would be a suicide)"
  fi
else
  printf 'SKIP: cannot read our own process group
' >&2
fi

# ---- CASE 11：看门狗放弃 ⇒ 非 0（无人值守设备上「放弃了」必须有人看得见）----
proc_watchdog --interval 1 --max-backoff 1 --max-restarts 1 wd no-such-command-xyz 2>/dev/null
RC=$?
if [ "$RC" != "1" ]; then
  smoke_fail "the watchdog must give up with exit 1 when the command cannot be started (got $RC)"
fi

# ---- CASE 12：看门狗把挂掉的进程拉起来 ----
proc_watchdog --interval 1 --max-backoff 1 wd2 sh -c 'sleep 300' >/dev/null 2>&1 &
WDPID=$!
WI=0
while [ "$WI" -lt 40 ]; do
  if proc_is_running wd2; then
    break
  fi
  sleep 0.1
  WI=$((WI + 1))
done
if ! proc_is_running wd2; then
  smoke_fail "the watchdog must start the process"
else
  WDPID2=$(cat "$PROCDIR/wd2.pid" 2>/dev/null || true)
  kill "$WDPID2" 2>/dev/null || true
  WJ=0
  BACK=""
  while [ "$WJ" -lt 80 ]; do
    sleep 0.1
    BACK=$(cat "$PROCDIR/wd2.pid" 2>/dev/null || true)
    if [ -n "$BACK" ] && [ "$BACK" != "$WDPID2" ] && _alive "$BACK"; then
      break
    fi
    BACK=""
    WJ=$((WJ + 1))
  done
  if [ -z "$BACK" ]; then
    smoke_fail "the watchdog must restart a process that died"
  fi
fi
kill "$WDPID" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 变异自证：把缺陷造回去，场景必须变红
#
# 做法：复制一份库 → 改坏一处 → 用改坏的库跑同一个判定 ⇒ 判定结果必须变。
# 每处都带**形状守卫**（改动必须真的落到源码上）：变异没生效时
# 这一节会假通过 —— 「断言没变」与「缺陷没造回去」必须分得开。
# ---------------------------------------------------------------------------

# _mutate SRC DST SED_EXPR —— 复制并改坏
_mutate() {
  cp "$1" "$2" || return 1
  sed "$3" "$2" >"$2.new" 2>/dev/null || return 1
  mv "$2.new" "$2" || return 1
  return 0
}

# _running_verdict LIB —— 用 LIB 判「那个真僵尸算不算在跑」
#   stdout: running | stopped
_running_verdict() {
  _rv_lib="$1"
  printf '%s
' "$ZPID" >"$PROCDIR/zv.pid"
  _rv_rc=0
  sh "$TMP/probe_running.sh" "$_rv_lib" zv "$PROCDIR/zv.pid" >/dev/null 2>&1 || _rv_rc=$?
  if [ "$_rv_rc" = "0" ]; then
    printf 'running'
  else
    printf 'stopped'
  fi
}

# _group_verdict LIB PID —— 用 LIB 判「这个 pid 能不能整组停」
#   stdout: allowed | refused
_group_verdict() {
  _gv_lib="$1"
  _gv_pid="$2"
  _gv_out=$(sh "$TMP/probe_group.sh" "$_gv_lib" "$_gv_pid" 2>/dev/null || true)
  if [ -n "$_gv_out" ]; then
    printf 'allowed'
  else
    printf 'refused'
  fi
}

# M1：去掉「僵尸算死」这一支 ⇒ 僵尸会被判成活着
M1="$TMP/mutant1.sh"
if _mutate "$LIB" "$M1" 's/Z | X) return 0 ;;/Z | X) return 1 ;;/'; then
  if ! grep -q 'Z | X) return 1 ;;' "$M1"; then
    smoke_fail "M1: the mutation did not apply (the shape guard caught it)"
  elif [ "$(_running_verdict "$M1")" != "running" ]; then
    smoke_fail "M1: a zombie must be judged as running once the dead-state branch is broken"
  fi
else
  smoke_fail "M1: cannot build the mutant"
fi

# M2：去掉「那个组不是我们自己的组」这条守卫 ⇒ 会打到自己的组（自杀）
M2="$TMP/mutant2.sh"
if _mutate "$LIB" "$M2" 's/\[ "$_sp_go_pgid" != "$_sp_go_self" \] || return 1//'; then
  if grep -q '_sp_go_pgid" != "$_sp_go_self' "$M2"; then
    smoke_fail "M2: the mutation did not apply (the shape guard caught it)"
  elif [ -z "$OURPGID" ]; then
    printf 'SKIP: M2 cannot be checked without our own process group
' >&2
  elif [ "$(_group_verdict "$M2" "$OURPGID")" != "allowed" ]; then
    smoke_fail "M2: the mutated library must allow our own group once the suicide guard is gone"
  fi
else
  smoke_fail "M2: cannot build the mutant"
fi

# M3：去掉「目标自己就是组长」这条守卫 ⇒ 别人组里的成员也认
#
# 造一个「在别的组里、但自己不是组长」的进程（组长的子进程）：
# 少了组长守卫 ⇒ 会去停**别人**那个组 ⇒ 停错了目标。
NLFILE="$TMP/nonleader.pid"
NLEADER=""
NPARENT=""
if command -v setsid >/dev/null 2>&1; then
  rm -f "$NLFILE"
  setsid sh -c 'sleep 60 & echo $! > "$1"; exec sleep 60' sk "$NLFILE" &
  NPARENT=$!
  NI=0
  while [ "$NI" -lt 40 ]; do
    if [ -s "$NLFILE" ]; then
      NLEADER=$(cat "$NLFILE" 2>/dev/null || true)
      if [ -n "$NLEADER" ]; then
        break
      fi
    fi
    sleep 0.1
    NI=$((NI + 1))
  done
  if [ -z "$NLEADER" ]; then
    printf 'SKIP: M3 cannot create a non-leader process
' >&2
  elif [ "$(_group_verdict "$LIB" "$NLEADER")" != "refused" ]; then
    smoke_fail "the group stop must refuse a target that is not the leader of its group"
  fi
  M3="$TMP/mutant3.sh"
  if _mutate "$LIB" "$M3" 's/\[ "$_sp_go_pgid" = "$_sp_go_pid" \] || return 1//'; then
    if grep -q '_sp_go_pgid" = "$_sp_go_pid' "$M3"; then
      smoke_fail "M3: the mutation did not apply (the shape guard caught it)"
    elif [ -n "$NLEADER" ] && [ "$(_group_verdict "$M3" "$NLEADER")" != "allowed" ]; then
      smoke_fail "M3: the mutated library must allow a non-leader target once the leader guard is gone"
    fi
  else
    smoke_fail "M3: cannot build the mutant"
  fi
else
  printf 'SKIP: M3 needs setsid (a foreign process group)
' >&2
fi

# ---- 清理 ----
# 僵尸的那个「不回收」的父亲到这里才杀：僵尸必须活到变异自证跑完。
kill "$ZPARENT" 2>/dev/null || true
kill "$NPARENT" 2>/dev/null || true
kill "$NLEADER" 2>/dev/null || true

# ---- 收尾 ----
if [ "$FAILS" -gt 0 ]; then
  printf '%s failing
' "$FAILS" >&2
  exit 1
fi
printf 'ok
'
exit 0
