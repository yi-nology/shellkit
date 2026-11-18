#!/bin/sh
# openEuler 容器里的真实环境：ps 的字段能力、/bin/sh 是什么、组杀能不能整组停。
# 门禁红了时不必再等一轮 CI 才有现场。
if ! command -v bash >/dev/null 2>&1; then
  dnf install -y -qq bash || true
fi
echo '=== os ==='
cat /etc/os-release 2>/dev/null | head -3
echo '=== tools ==='
command -v bash || echo 'no bash'
command -v sh
ls -l /bin/sh
command -v ps || echo 'no ps'
ps --version 2>&1 | head -2
echo '=== ps fields ==='
echo "stat=[$(ps -o stat= -p $$ 2>&1)]"
echo "pgid=[$(ps -o pgid= -p $$ 2>&1)]"
echo "A=[$(ps -A -o pid=,pgid= 2>&1 | head -2)]"
echo '=== group kill repro ==='
set -m
nohup sh -c 'sleep 20 & echo $! > /tmp/child.pid; wait' >/dev/null 2>&1 </dev/null &
pid=$!
sleep 1
child=$(cat /tmp/child.pid 2>/dev/null)
echo "pid=$pid child=$child"
echo "pid pgid=[$(ps -o pgid= -p $pid 2>&1)] child pgid=[$(ps -o pgid= -p $child 2>&1)] self pgid=[$(ps -o pgid= -p $$ 2>&1)]"
kill -TERM -- -$pid 2>&1
sleep 1
if kill -0 $child 2>/dev/null; then
  echo 'CHILD SURVIVED (kill -0 still succeeds)'
  echo "child state=[$(ps -o stat= -p $child 2>&1)]"
else
  echo 'child is gone'
fi
kill $child 2>/dev/null
echo '=== run the repo test ==='
cd /src && bash tests/test_proc.sh 2>&1 | tail -30
