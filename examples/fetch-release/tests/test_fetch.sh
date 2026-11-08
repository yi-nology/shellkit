#!/usr/bin/env bash
# 示例工程的测试：全程走真实二进制，上游用 file:// 指向本地目录，所以离线可跑。
set -u
SK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
. "$SK_ROOT/tests/test_helper.sh"

BIN="$TEST_ROOT/examples/fetch-release/bin/fetch-release"
d=$(mktemp -d "$TEST_TMP_ROOT/fr.XXXXXX") || _fail "mktemp failed"
base="$d/upstream"
root="$d/root"
mkdir -p "$base"
export RELEASE_BASE="file://$base"
export RELEASE_ROOT="$root"
# 锁也落在用例目录里，免得和别的测试共用 /tmp 下的同名锁
export SHELLKIT_LOCK_DIR="$d/locks"
mkdir -p "$d/locks"
SHELLKIT_RETRY_DELAY=0
export SHELLKIT_RETRY_DELAY

_digest() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

printf "payload 1.0.0\n" >"$base/payload-1.0.0.txt"
printf "payload 1.1.0\n" >"$base/payload-1.1.0.txt"
{
  for __f in payload-1.0.0.txt payload-1.1.0.txt; do
    printf '%s  %s\n' "$(_digest "$base/$__f")" "$__f"
  done
} >"$base/SHA256SUMS"

# 什么都没装的时候 current 报 none，退出码 1
assert_exit_code 1 "$BIN" current

# 1. 下载 + 校验 + 切换。日志全部走 stderr，所以 fetch 的 stdout 是空的
assert_stdout_empty "$BIN" fetch 1.0.0
assert_eq "1.0.0" "$("$BIN" current 2>/dev/null)" "current should be 1.0.0"
assert_contains "$(cat "$root/versions/1.0.0/payload")" "payload 1.0.0"

# 2. 重复跑不重复下载：把上游文件删掉，缓存命中就必须还能成功
rm -f "$base/payload-1.0.0.txt"
assert_exit_code 0 "$BIN" fetch 1.0.0

# 3. 切版本，旧版本还在 —— 回滚就是再指一次链接
assert_exit_code 0 "$BIN" fetch 1.1.0
assert_eq "1.1.0" "$("$BIN" current 2>/dev/null)" "current should be 1.1.0"
assert_eq "1.0.0
1.1.0" "$("$BIN" versions 2>/dev/null)" "versions should list both"

# 4. 上游文件被改而清单没变 ⇒ 校验失败是 5，不是一般错误 1
printf "tampered\n" >"$base/payload-1.1.0.txt"
rm -f "$root/versions/1.1.0/payload"
assert_exit_code 5 "$BIN" fetch --refresh 1.1.0

# 5. 清单里没有的版本是 5（根本不该开始下载）
assert_exit_code 5 "$BIN" fetch 2.0.0

# 6. 清单里有但文件不存在 ⇒ 网络失败 4
printf '%s  %s\n' "$(_digest "$base/payload-1.1.0.txt")" payload-3.0.0.txt >>"$base/SHA256SUMS"
assert_exit_code 4 "$BIN" fetch --refresh 3.0.0

# 7. 参数错是 2，不是 1
assert_exit_code 2 "$BIN" fetch
assert_exit_code 2 "$BIN" fetch not-a-version
