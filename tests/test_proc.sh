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
_st=$(ps -o stat= -p $$ 2>/dev/null | tr -d '[:space:]')
case "$_st" in
  [A-Z]*) have_stat=1 ;;
esac
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
if [ "$have_pgid" != "1" ]; then
  printf 'SKIP: this environment has no usable ps process-group field\n' >&2
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
    kill -0 "$child" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$child" 2>/dev/null; then
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
      zstate=$(ps -o stat= -p "$zpid" 2>/dev/null | tr -d '[:space:]')
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
