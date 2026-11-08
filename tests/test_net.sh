#!/usr/bin/env bash
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"

d=$(tmpdir)
src="$d/src.txt"
printf 'shellkit net test\n' >"$src"
sum=$(net_sha256 "$src")
assert_eq "$(os_sha256 "$src")" "$sum" "net_sha256 matches os_sha256"

dst="$d/dst.txt"
net_download "file://$src" "$dst" "$sum" 2>/dev/null
assert_eq "shellkit net test" "$(cat "$dst")" "net_download content"

net_download "file://$src" "$dst" "$sum" 2>/dev/null
assert_eq "shellkit net test" "$(cat "$dst")" "net_download reuses cache"

bad="$d/bad.txt"
assert_exit_code 5 net_download "file://$src" "$bad" "0000000000000000000000000000000000000000000000000000000000000000"
assert_false test -f "$bad"

assert_true net_verify "$src" "$sum"
assert_exit_code 5 net_verify "$src" "deadbeef"

assert_exit_code 4 net_wait_port 127.0.0.1 1 1

# ---------------------------------------------------------------------------
# 用 stub 覆盖真实网络下无法稳定复现的分支：下载失败、镜像回退、校验失败。
# 这是引入 stub 的理由本身 —— 0.1.0 里这三条分支一条都测不到。
# ---------------------------------------------------------------------------

# 1) 下载失败 -> SK_NET，且不留下目标文件
stub curl --exit 22
assert_exit_code 4 net_download "https://example.invalid/x" "$d/fail1"
assert_false test -f "$d/fail1"
assert_stub_called curl 1
assert_stub_args curl "-fsSL"
unstub curl

# 2) 镜像回退：源站失败、镜像成功
stub curl --body '
case "$*" in
  *origin.example*) return 22 ;;
esac
prev=""
for a in "$@"; do
  if [ "$prev" = "-o" ]; then printf "mirror-ok" >"$a"; fi
  prev=$a
done
return 0
'
export SHELLKIT_MIRROR_FROM="https://origin.example"
export SHELLKIT_MIRROR_TO="https://mirror.example"
net_download "https://origin.example/pkg" "$d/mirror1"
assert_eq "mirror-ok" "$(cat "$d/mirror1")" "mirror fallback writes the file"
assert_stub_called curl 2 "mirror fallback tries source then mirror"
unset SHELLKIT_MIRROR_FROM SHELLKIT_MIRROR_TO
unstub curl

# 3) 校验不匹配 -> SK_VERIFY，且不留下目标文件
stub curl --body '
prev=""
for a in "$@"; do
  if [ "$prev" = "-o" ]; then printf "tampered" >"$a"; fi
  prev=$a
done
return 0
'
assert_exit_code 5 net_download "https://example.invalid/f" "$d/bad1" "0000000000000000000000000000000000000000000000000000000000000000"
assert_false test -f "$d/bad1"
unstub curl

# net_wait_port 探测成功后不能去关 fd 3 —— 那个 3 是调用方开的，不是我们的
if command -v python3 >/dev/null 2>&1; then
  portf="$d/port"
  python3 - "$portf" >/dev/null 2>&1 <<'PY' &
import socket, sys, time
s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen(1)
with open(sys.argv[1], "w") as fh:
    fh.write(str(s.getsockname()[1]))
time.sleep(30)
PY
  listener=$!
  tries=0
  while [ ! -s "$portf" ] && [ "$tries" -lt 50 ]; do
    sleep 0.1
    tries=$((tries + 1))
  done
  port=$(cat "$portf" 2>/dev/null || true)
  if [ -n "$port" ]; then
    exec 3>"$d/fd3.log"
    assert_exit_code 0 net_wait_port 127.0.0.1 "$port" 5
    _fd3_ok=0
    printf 'still-open\n' >&3 || _fd3_ok=1
    exec 3>&-
    assert_eq "0" "$_fd3_ok" "net_wait_port leaves the caller's fd 3 usable"
    # exec 的重定向是永久的：以前那行还会把调用方的 stderr 丢进 /dev/null
    _err_seen=$({ printf 'err-alive\n' >&2; } 2>&1)
    assert_eq "err-alive" "$_err_seen" "net_wait_port leaves stderr usable"
    assert_contains "$(cat "$d/fd3.log")" "still-open"
  fi
  kill "$listener" 2>/dev/null || true
  wait "$listener" 2>/dev/null || true
fi
