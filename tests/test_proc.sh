#!/usr/bin/env bash
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"

d=$(tmpdir)
export SHELLKIT_PROC_DIR="$d/run"
mkdir -p "$SHELLKIT_PROC_DIR"

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
