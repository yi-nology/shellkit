#!/usr/bin/env bash
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"

d=$(tmpdir)
export SHELLKIT_PROC_DIR="$d/run"
mkdir -p "$SHELLKIT_PROC_DIR"

# 这一层要 ps 的两个字段：状态（stat=）与进程组（pgid=）。
# 精简环境（busybox / 没装 procps 的容器）没有 ⇒ 相关的用例跳过，其余照跑。
# 判据要在所有支持它的环境里都成立，而不是只在装了 procps 的机器上成立。
have_stat=0
have_pgid=0
# 真状态是 S / Ss / R / Z+ 这种形状：首字母大写，后面的修饰符是小写或符号。
# busybox 的 ps 不认 `stat=`，它会打一行表头 STAT ⇒ 表头不是状态，不能当真
# （表头 STAT 的第二个字母是大写 T，真状态的第二个字母一定是小写或符号 ⇒ 据此分辨）。
#
# ⚠ 判据里不能出现 < 或 >：那是 shell 的重定向元字符，词法器会把 case 模式
# 从中间切开 ⇒ bash 报 "case patterns must be separated with `|'"，3.2 上必炸。
sk_stat_is_real() {
  case "${1:-}" in
    [RSZTWDI] | [RSZTWDI][a-z]* | [RSZTWDI]+*) return 0 ;;
  esac
  return 1
}
# 取输出的最后一行（busybox 的表头在第一行），再抹掉空白。
sk_stat_of() {
  ps -o stat= -p "$1" 2>/dev/null | tail -n 1 | tr -d '[:space:]'
}
# 假 ps：一个**桩**，不是转发。
# 转发（把请求转给环境里真实的 ps）会把判据绑死在环境上：macOS 的 CI 上真实 ps
# 的 stat= 行为与本地不同 ⇒ 同一条判据时绿时红 ⇒ 判据没有判据能力。
# 桩的行为是确定的：busybox 风格 —— 不认 `stat=` 的表头抑制，先打一行表头（STAT）
# 再打真状态；哪个 pid 是「假僵尸」由环境变量 SK_FAKE_ZOMBIE 决定。
fakebin="$d/fakebin"
mkdir -p "$fakebin"
cat >"$fakebin/ps" <<'EOF'
#!/bin/sh
for a in "$@"; do
  case "$a" in
    stat=)
      echo STAT
      pid=""
      prev=""
      for b in "$@"; do
        case "$prev" in
          -p) pid="$b" ;;
        esac
        prev="$b"
      done
      if [ -n "$pid" ] && [ "$pid" = "$SK_FAKE_ZOMBIE" ]; then
        echo Z+
      else
        echo Ss
      fi
      exit 0
      ;;
  esac
done
exit 0
EOF
chmod +x "$fakebin/ps"
# 「取最后一行」这条判据也要有承重：取全部输出 ⇒ 表头被拼在状态前面（STATSs）
# ⇒ 白名单认不出来 ⇒ 精简环境里用例以为能看状态、实际看不到。
_fake_st=$(PATH="$fakebin:$PATH" sk_stat_of $$)
if ! sk_stat_is_real "$_fake_st"; then
  _fail "the process state is taken from the last line of ps (the header comes first): got '$_fake_st'"
fi
# 这条判据自己也要有承重：把白名单放宽成「首字母大写」就会把表头 STAT 当成状态
# ⇒ 精简环境里用例以为能看状态、实际什么都看不到 ⇒ 假红。
if sk_stat_is_real STAT; then
  _fail "a ps header is not a process state"
fi
if ! sk_stat_is_real Ss; then
  _fail "a sleeping process state is recognized"
fi
if ! sk_stat_is_real Z+; then
  _fail "a zombie process state is recognized"
fi
if sk_stat_is_real ""; then
  _fail "an empty ps output is not a process state"
fi
if sk_stat_is_real "$(sk_stat_of $$)"; then
  have_stat=1
fi
_pg=$(ps -o pgid= -p $$ 2>/dev/null | tr -d '[:space:]')
case "$_pg" in
  '' | *[!0-9]*) have_pgid=0 ;;
  *) have_pgid=1 ;;
esac

# ---- 后台引导：拉起来、探活、停掉 ----
assert_exit_code 0 proc_start demo sleep 30
assert_exit_code 0 proc_is_running demo
pid=$(cat "$SHELLKIT_PROC_DIR/demo.pid")
if ! kill -0 "$pid" 2>/dev/null; then
  _fail "the pid in the pid file is alive"
fi
# 日志文件要有（追加，不截断）
if [ ! -f "$SHELLKIT_PROC_DIR/demo.log" ]; then
  _fail "the process log file exists"
fi
assert_exit_code 0 proc_stop demo
assert_exit_code 1 proc_is_running demo
if [ -f "$SHELLKIT_PROC_DIR/demo.pid" ]; then
  _fail "the pid file is removed after stop"
fi

# ---- 整组停止：子进程不能残留（只 kill 主进程 ⇒ 端口还占着）----
# 「还活着」不等于 kill -0 成功：僵尸也还在进程表里（kill -0 对僵尸也成功）。
# 容器里 PID 1 常常不是 init（GitHub 的容器 job 用 `tail -f /dev/null` 占着 PID 1）
# ⇒ 没人回收 ⇒ 被组杀掉的子进程永远停在 Z 态 ⇒ 只看 kill -0 会把「已经死了」
# 误判成「还活着」（openEuler 的 compat job 就是这样红的：组杀其实生效了，
# 子进程确实死了，只是没人收尸）。判据要和库里的「活着」是同一个意思。
sk_alive() {
  local __p="${1:-}" __st
  [ -n "$__p" ] || return 1
  kill -0 "$__p" 2>/dev/null || return 1
  __st=$(sk_stat_of "$__p")
  case "$__st" in
    Z*) return 1 ;;
  esac
  return 0
}
if [ "$have_pgid" != "1" ] || [ "$have_stat" != "1" ]; then
  printf 'SKIP: this environment cannot report the ps process group or the process state\n' >&2
else
  assert_exit_code 0 proc_start grp sh -c 'sleep 30 & echo $! > "'"$d"'/child.pid"; wait'
  # 等子进程起来
  i=0
  while [ "$i" -lt 50 ]; do
    [ -s "$d/child.pid" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  child=$(cat "$d/child.pid" 2>/dev/null || true)
  if [ -z "$child" ]; then
    _fail "the grandchild process was started"
  fi
  assert_exit_code 0 proc_stop grp
  i=0
  while [ "$i" -lt 50 ]; do
    sk_alive "$child" || break
    sleep 0.1
    i=$((i + 1))
  done
  if sk_alive "$child"; then
    _fail "the whole process group is stopped (the child survived)"
  fi
fi

# ---- 已经在了就不再来一份 ----
assert_exit_code 0 proc_start twice sleep 30
assert_exit_code 3 proc_start twice sleep 30
assert_exit_code 0 proc_stop twice

# ---- 命令不存在 ⇒ 前置条件不满足（不是「成功」）----
assert_exit_code 3 proc_start broken no-such-command-here-xyz
if [ -f "$SHELLKIT_PROC_DIR/broken.pid" ]; then
  _fail "a failed start leaves no pid file behind"
fi

# ---- 名字非法 ⇒ 用法错（名字会变成路径）----
assert_exit_code 2 proc_start "../evil" sleep 30
assert_exit_code 2 proc_stop "../evil"
assert_exit_code 2 proc_is_running "../evil"

# ---- 僵尸 pid 文件要清掉 ----
printf '999999\n' >"$SHELLKIT_PROC_DIR/stale.pid"
assert_exit_code 1 proc_is_running stale
if [ -f "$SHELLKIT_PROC_DIR/stale.pid" ]; then
  _fail "a stale pid file is cleaned up"
fi

# ---- 表头在前（busybox 风格的 ps）：僵尸仍然要判得出来、pid 文件仍然要清掉 ----
# 判据承重的点：_sk_proc_alive 取 ps 输出的**最后一行**（真状态）。
# 取全部输出 ⇒ 表头被拼在状态前面（STATZ+）⇒ 僵尸被当成活进程 ⇒ pid 文件清不掉
# —— 而「僵尸 pid 文件清不掉」正是这一层要根治的坑。
# 去掉库里那一行修复（取全部输出）后，这一条必须变红。
#
# 这里用桩 ps 而不是真僵尸：这条判据要验的是「表头在前时怎么读状态」，
# 与环境能不能造出真僵尸无关 ⇒ 不该被环境能力牵着走。
sleep 30 &
fakez=$!
printf '%s\n' "$fakez" >"$SHELLKIT_PROC_DIR/fakez.pid"
SK_FAKE_ZOMBIE="$fakez" PATH="$fakebin:$PATH" assert_exit_code 1 proc_is_running fakez
if [ -f "$SHELLKIT_PROC_DIR/fakez.pid" ]; then
  _fail "a zombie pid file is cleaned up even when ps prints a header first"
fi
kill "$fakez" 2>/dev/null || true

# 判据「僵尸不算活着」自己也要有承重：桩 ps 报告 Z+ ⇒ 这个进程必须判成「没活着」。
# 去掉 Z 分支 ⇒ 判成活着 ⇒ 这一条变红。
sleep 30 &
fakez2=$!
if SK_FAKE_ZOMBIE="$fakez2" PATH="$fakebin:$PATH" sk_alive "$fakez2"; then
  kill "$fakez2" 2>/dev/null || true
  _fail "a zombie process is not alive"
fi
kill "$fakez2" 2>/dev/null || true

# 反方向也要有承重：桩 ps 报 Ss（普通进程）⇒ 必须判成「还活着」。
# 把 Z 分支写成 * （一律判成没活着）⇒ 这一条变红。
sleep 30 &
alivez=$!
if ! SK_FAKE_ZOMBIE='' PATH="$fakebin:$PATH" sk_alive "$alivez"; then
  kill "$alivez" 2>/dev/null || true
  _fail "a running process is alive"
fi
kill "$alivez" 2>/dev/null || true

# ---- 停一个没在跑的 ⇒ 成功（幂等）----
assert_exit_code 0 proc_stop never-started

# ---- 看门狗：拉不起来就连放弃（退出码非 0，不是静默重试到天荒地老）----
assert_exit_code 1 proc_watchdog --interval 1 --max-restarts 1 wd no-such-command-here-xyz

# ---- 看门狗：进程挂了要能拉起来 ----
# 第一就死掉的命令：看门狗要重启它（--max-restarts 2 ⇒ 两次都起不来才放弃）
out=$(proc_watchdog --interval 1 --max-backoff 1 --max-restarts 2 wd2 sh -c 'exit 1' 2>&1) && rc=0 || rc=$?
if [ "$rc" = "0" ]; then
  _fail "the watchdog gives up when the process cannot stay alive"
fi
assert_contains "$out" "gave up" "the watchdog says why it gave up"

# ---- 看门狗：连续失败要有退避（没有退避的重启是风暴，把机器打满）----
# 退避必须「看得见」才判得出来：断言两次拉起之间确实等过。
out=$(proc_watchdog --interval 1 --max-backoff 4 --max-restarts 3 wd3 sh -c 'exit 1' 2>&1) && rc=0 || rc=$?
if [ "$rc" = "0" ]; then
  _fail "the watchdog gives up when the process cannot stay alive (backoff case)"
fi
assert_contains "$out" "waiting" "the watchdog says it is waiting before the next restart"
# 等待时长必须**增长**：恒定 1 秒等于没有退避（还是风暴）。
# 判据：日志里出现过的最大等待秒数 > 1。
maxwait=0
while IFS= read -r line; do
  case "$line" in
    *"waiting before the next restart"*) ;;
    *) continue ;;
  esac
  # 取「: <数字> s」里的数字（纯 bash，不接管道：坑 5）
  num=${line##*: }
  num=${num%% s*}
  case "$num" in
    '' | *[!0-9]*) continue ;;
  esac
  [ "$num" -gt "$maxwait" ] && maxwait=$num
done <<EOF
$out
EOF
if [ "$maxwait" -le 1 ]; then
  _fail "the watchdog backs off longer between restarts (max wait: ${maxwait}s)"
fi

# ---- 僵尸进程不算活着（kill -0 对僵尸也成功）----
# 造一个**真僵尸**：子进程退出、父亲还活着且不回收 ⇒ 进程表里留着 Z 态。
# exec 是关键：exec 把那个 shell 换掉，换掉的进程才是僵尸原来的父亲 ——
# 于是没人回收它。pid 不存在（999999）那种只测到「没了」，测不到 Z 分支。
# sleep 1 而不是 0.05：子进程必须活得比 shell 走到 exec 更久，否则它先退出、
# 被 shell 在下一个命令边界回收掉，僵尸根本没形成（慢机器上会偶发）。
if [ "$have_stat" != "1" ]; then
  printf 'SKIP: this environment has no usable ps state field\n' >&2
else
  zpidfile="$d/zombie.pid"
  sh -c 'sleep 1 & echo $! > '"$zpidfile"'; exec sleep 10' &
  zparent=$!
  zpid=""
  zstate=""
  i=0
  while [ "$i" -lt 60 ]; do
    zpid=$(cat "$zpidfile" 2>/dev/null || true)
    if [ -n "$zpid" ]; then
      zstate=$(sk_stat_of "$zpid")
      case "$zstate" in
        Z*) break ;;
      esac
    fi
    sleep 0.1
    i=$((i + 1))
  done
  if [ -z "$zpid" ] || [ "$zstate" = "${zstate#Z}" ]; then
    _fail "the test could not create a real zombie process (state: ${zstate:-none})"
  fi
  printf '%s\n' "$zpid" >"$SHELLKIT_PROC_DIR/zombie.pid"
  assert_exit_code 1 proc_is_running zombie
  if [ -f "$SHELLKIT_PROC_DIR/zombie.pid" ]; then
    _fail "a zombie pid file is cleaned up"
  fi
  kill "$zparent" 2>/dev/null || true
fi

# ---- 整组停：目标那个组**就是调用方自己的组** ⇒ 不能整组杀（否则自杀）----
if [ "$have_pgid" != "1" ]; then
  printf 'SKIP: this environment has no usable ps process-group field\n' >&2
else
  #
  # 场景：调用方是组长的子进程（同一个组）。组杀会把调用方一起带走 ——
  # 退出码 143，看起来像「被信号停掉」，其实是我们自己动的手。
  # 判据承重：把「排除自己那个组」的判断去掉，调用方会被自己组的 SIGTERM 打死，
  # 下面的 SURVIVED 永远不会打印。
  mkdir -p "$d/selfgrp"
  cat >"$d/selfgrp/outer.sh" <<'EOS'
#!/usr/bin/env bash
export SK_LEADER_PID=$$
bash "$SK_TEST_SELF/inner.sh"
EOS
  cat >"$d/selfgrp/inner.sh" <<'EOS'
#!/usr/bin/env bash
. "$SK_TEST_ROOT/lib/bootstrap.sh"
export SHELLKIT_PROC_DIR="$SK_TEST_PROC_DIR"
mkdir -p "$SHELLKIT_PROC_DIR"
printf '%s\n' "$SK_LEADER_PID" >"$SHELLKIT_PROC_DIR/self.pid"
proc_stop self
printf 'SURVIVED rc=%s\n' "$?"
EOS
  # 作业控制：让 outer.sh 自成进程组（组长 = 它自己），inner.sh 是它的子进程
  # ⇒ 两者同组，但 inner.sh 的 pid 不是组长
  had_m=0
  case "$-" in
    *m*) had_m=1 ;;
  esac
  set -m
  SK_TEST_ROOT="$TEST_ROOT" SK_TEST_SELF="$d/selfgrp" SK_TEST_PROC_DIR="$d/selfgrp/run" \
    bash "$d/selfgrp/outer.sh" >"$d/selfgrp/out.txt" 2>&1 &
  selfpid=$!
  if [ "$had_m" = "0" ]; then
    set +m
  fi
  i=0
  while [ "$i" -lt 100 ]; do
    case "$(cat "$d/selfgrp/out.txt" 2>/dev/null || true)" in
      *SURVIVED*) break ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  out=$(cat "$d/selfgrp/out.txt" 2>/dev/null || true)
  case "$out" in
    *SURVIVED*) ;;
    *) _fail "stopping a group that contains the caller does not kill the caller (out: ${out:-none})" ;;
  esac
  kill "$selfpid" 2>/dev/null || true
fi

# ---- 看门狗：进程挂了要能真的拉起来（这是看门狗存在的唯一理由）----
# 命令每次起来都往文件里追加一行；进程只活 2 秒 ⇒ 看门狗必须重启它。
# 判据承重：把「拉起」这一步去掉，文件里永远只有 0 行 ⇒ 断言会红。
counter="$d/restarts.txt"
: >"$counter"
proc_watchdog --interval 1 --max-backoff 1 --max-restarts 0 wd4 \
  sh -c 'echo x >> '"$counter"'; sleep 2' >"$d/wd4.log" 2>&1 &
wdpid=$!
restarts=0
i=0
while [ "$i" -lt 200 ]; do
  restarts=$(wc -l <"$counter" 2>/dev/null | tr -d '[:space:]')
  case "$restarts" in
    '' | *[!0-9]*) restarts=0 ;;
  esac
  [ "$restarts" -ge 2 ] && break
  sleep 0.1
  i=$((i + 1))
done
kill "$wdpid" 2>/dev/null || true
wait "$wdpid" 2>/dev/null || true
if [ "$restarts" -lt 2 ]; then
  _fail "the watchdog restarts a process that keeps dying (restarts: $restarts)"
fi

# ---- 看门狗：0 秒间隔是热循环、0 秒退避是重启风暴 ⇒ 用法错 ----
assert_exit_code 2 proc_watchdog --interval 0 wd5 sleep 30
assert_exit_code 2 proc_watchdog --max-backoff 0 wd5 sleep 30
