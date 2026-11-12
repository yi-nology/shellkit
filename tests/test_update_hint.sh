#!/usr/bin/env bash
# 升级提示（issue #67）：已装副本能查、非交互不打扰、无网静默跳过。
#
# 分两层测：
#   1. 逻辑层（直接调 _sk_update_hint）—— 缓存、离线、版本比较、逃生舱
#   2. 闸门层（跑真 CLI）—— 非交互一个字都不出；真给了 tty 就必须出
# 闸门那条正控制靠 python3 的 pty 分配一个真终端；机器上没有 python3 就跳过
# （net_json 本来就要求 jq 或 python3 有其一，正常环境不会缺）。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"

work=$(tmpdir)
export XDG_CACHE_HOME="$work/cache"
export HOME="$work"
CACHE="$XDG_CACHE_HOME/shellkit/version-check"
CUR=$SK_VERSION
# 打不通的地址：本机 1 端口没人监听，连接立刻失败，不用等外网
export SHELLKIT_RELEASE_API="http://127.0.0.1:1/nope"
mkdir -p "$XDG_CACHE_HOME/shellkit"

# seed VERSION —— 往缓存里写「上次检查时间 + 最新版本」
seed() {
  printf '%s\t%s' "$(date +%s)" "$1" >"$CACHE"
}

# CASE: 缓存里有更新的版本 -> 提示里必须带版本号
seed 9.9.9
out=$(_sk_update_hint "$work/prefix" 2>&1)
assert_eq "0" "$?" "the hint must never fail the caller"
assert_contains "$out" "9.9.9" "a newer version must be announced"

# CASE: 缓存里就是当前版本 -> 一个字都不出
seed "$CUR"
out=$(_sk_update_hint "$work/prefix" 2>&1)
assert_eq "0" "$?" "an up-to-date hint must not fail"
assert_eq "" "$out" "being up to date must print nothing"

# CASE: 不是已装副本（前缀为空）-> 不提示
seed 9.9.9
out=$(_sk_update_hint "" 2>&1)
assert_eq "" "$out" "a git checkout must not be told to run update"

# CASE: 逃生舱 -> 永不出声
out=$(SHELLKIT_NO_UPDATE_HINT=1 _sk_update_hint "$work/prefix" 2>&1)
assert_eq "" "$out" "SHELLKIT_NO_UPDATE_HINT must silence the hint"

# CASE: 无缓存 + 打不通的 API -> 静默、不报错，但要把「这次查过」记下来
rm -f "$CACHE"
rc=0
out=$(_sk_update_hint "$work/prefix" 2>&1) || rc=$?
assert_eq "0" "$rc" "an offline check must not turn into an error"
assert_eq "" "$out" "an offline check must print nothing"
assert_true test -f "$CACHE"
assert_eq "" "$(awk -F'\t' '{print $2}' "$CACHE")" "a failed check must record an empty latest version"

# CASE: 失败缓存在 TTL 内不重试 —— 否则没网的机器每次调用都白等一次超时
before=$(cat "$CACHE")
sleep 1
_sk_update_hint "$work/prefix" >/dev/null 2>&1 || true
assert_eq "$before" "$(cat "$CACHE")" "a fresh failure cache must not be re-fetched"

# CASE: 缓存过期后才重查（把时间往前拨 8 天）
printf '%s\t%s' "$(($(date +%s) - 691200))" "" >"$CACHE"
before=$(cat "$CACHE")
_sk_update_hint "$work/prefix" >/dev/null 2>&1 || true
assert_ne "$before" "$(cat "$CACHE")" "an expired cache must be re-fetched"

# CASE: 缓存目录是软链就不写 —— 不顺着软链把缓存写到别处（坑 8）
# 前面的用例已经建出了真实的 $XDG_CACHE_HOME/shellkit：必须先清掉，
# 否则 ln -s 会把链接塞进那个目录里，测的根本不是软链。
rm -f "$CACHE"
rm -rf "$XDG_CACHE_HOME/shellkit"
mkdir -p "$XDG_CACHE_HOME/real"
ln -s "$XDG_CACHE_HOME/real" "$XDG_CACHE_HOME/shellkit"
_sk_update_hint "$work/prefix" >/dev/null 2>&1 || true
assert_false test -e "$XDG_CACHE_HOME/real/version-check"
rm -f "$XDG_CACHE_HOME/shellkit"
mkdir -p "$XDG_CACHE_HOME/shellkit"

# ---------------------------------------------------------------------------
# 闸门层：跑真 CLI
# ---------------------------------------------------------------------------

# mk_installed PREFIX —— 造一个最小的已装副本（布局与 install-self 一致）
mk_installed() {
  local __p=$1
  mkdir -p "$__p/share/shellkit"
  cp -R "$TEST_ROOT/lib" "$TEST_ROOT/locale" "$__p/share/shellkit/" || return 1
  cp "$TEST_ROOT/shellkit" "$TEST_ROOT/VERSION" "$__p/share/shellkit/" || return 1
}

installed=$work/prefix
mk_installed "$installed" || _fail "cannot build an installed copy"

# CASE: 非交互（管道）跑已装副本 -> 一个字都不出（CI 不许有升级广告）
seed 9.9.9
out=$("$installed/share/shellkit/shellkit" --version 2>&1)
assert_eq "0" "$?" "the installed copy must still run"
assert_contains "$out" "$CUR" "the command's own output must survive"
assert_not_contains "$out" "9.9.9" "a non-interactive run must not carry the hint"

# CASE: 同样的场景给了真终端 -> 提示必须出现（否则上面那条永远绿，闸门没有判据能力）
if command -v python3 >/dev/null 2>&1; then
  out=$(python3 -c 'import pty, sys; pty.spawn(sys.argv[1:])' \
    "$installed/share/shellkit/shellkit" --version 2>&1)
  assert_contains "$out" "9.9.9" "on a real tty the hint must be shown"
else
  printf '%s\n' "SKIP: python3 unavailable, tty positive control not run" >&2
fi

# CASE: git 检出（没装过）-> 就算缓存说有新版也不提示
seed 9.9.9
out=$("$TEST_ROOT/shellkit" --version 2>&1)
assert_eq "0" "$?" "the git checkout must still run"
assert_not_contains "$out" "9.9.9" "a git checkout must not be told to run update"
