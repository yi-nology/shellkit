#!/usr/bin/env bash
# 错误上下文（issue #63）：绝对路径、软链指向、跨模块传递、自动脱敏。
#
# 四条判据（issue 里的验收项）：
#   1. 错误信息包含目标绝对路径
#   2. 软链错误包含链接指向
#   3. 底层失败的上下文出现在顶层输出里
#   4. 上下文自动脱敏
#
# 还有一条不能破的：既有文案不推翻 —— 上下文栈为空时，
# log_error / die 的输出与以前**逐字相同**。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"

work=$(tmpdir)
# 规范化的工作目录：mktemp 给的路径可能带双斜杠，而报出来的绝对路径走 pwd -P 是规范化的
workabs=$(cd "$work" && pwd -P)

# ---------------------------------------------------------------------------
# 上下文栈本身
# ---------------------------------------------------------------------------

assert_eq "" "$(_sk_err_ctx_render)" "an empty context stack renders as nothing"

_sk_err_ctx_push "first"
assert_eq "first" "$(_sk_err_ctx_render)" "one frame renders as the operation name"

_sk_err_ctx_push "second" "dir=/tmp/x"
assert_eq "first > second (dir=/tmp/x)" "$(_sk_err_ctx_render)" \
  "two frames render as a chain, innermost last"

_sk_err_ctx_pop
assert_eq "first" "$(_sk_err_ctx_render)" "pop removes the innermost frame"

_sk_err_ctx_pop
assert_eq "" "$(_sk_err_ctx_render)" "the stack is empty again"

# 弹不存在的层要报错，而不是把栈搞坏
assert_false _sk_err_ctx_pop
assert_eq "" "$(_sk_err_ctx_render)" "popping an empty stack must not corrupt it"

# ---------------------------------------------------------------------------
# 按深度回收（unwind）：分发层在命令结束时把栈收回到进入时的深度
#
# 只有 pop 是不够的：嵌套调用失败时各个 return 不会逐层 pop，
# 栈里会留下面包屑，而 pop 是 LIFO 的 —— 留下的帧会让下一次 pop 弹错层。
# ---------------------------------------------------------------------------

assert_eq "0" "$(_sk_err_ctx_depth)" "the stack starts empty"
_sk_err_ctx_push "outer" "dir=/o"
_sk_err_ctx_push "inner" "dir=/i"
assert_eq "2" "$(_sk_err_ctx_depth)" "each push grows the depth"

_sk_err_ctx_unwind 1
assert_eq "1" "$(_sk_err_ctx_depth)" "unwind to 1 keeps exactly one frame"
assert_eq "outer (dir=/o)" "$(_sk_err_ctx_render)" "unwind drops the frames above DEPTH, not below it"

_sk_err_ctx_unwind 0
assert_eq "0" "$(_sk_err_ctx_depth)" "unwind to 0 empties the stack"
assert_eq "" "$(_sk_err_ctx_render)" "an unwound stack renders as nothing"

# 收得比当前更深 = 不做什么；栈更浅时也不该被破坏
_sk_err_ctx_push "only"
_sk_err_ctx_unwind 99
assert_eq "1" "$(_sk_err_ctx_depth)" "unwinding past the top must not touch the stack"
assert_eq "only" "$(_sk_err_ctx_render)" "the surviving frame still renders"

# 非法的深度要拒绝，而不是把栈搞坏
assert_false _sk_err_ctx_unwind not-a-number
assert_eq "only" "$(_sk_err_ctx_render)" "a rejected unwind must leave the stack intact"
assert_false _sk_err_ctx_unwind ""
assert_eq "only" "$(_sk_err_ctx_render)" "an empty depth is rejected too"

_sk_err_ctx_unwind 0
assert_eq "0" "$(_sk_err_ctx_depth)"

# ---------------------------------------------------------------------------
# 分发层的回收：命令留下几层，cli_run 返回时就该收干净
#
# 这是这条判据的要害 —— 少了它，上一条失败命令的操作名会挂到下一条的报错上。
# ---------------------------------------------------------------------------

cmd_probe_leak() {
  # 模拟「压了上下文又失败、但没自己 pop」的命令（真实命令里 cmd_upgrade 就这样）
  _sk_err_ctx_push "probing" "dir=/x" "password=hunter2"
  log_error "probe failed"
  return 7
}
cli_cmd probe-leak "probe command that leaves a context frame behind" "probe-leak"

rc=0
cli_run probe-leak >/dev/null 2>&1 || rc=$?
assert_eq "7" "$rc" "cli_run must pass the command's exit code through unchanged"
assert_eq "0" "$(_sk_err_ctx_depth)" "cli_run must unwind the frames the command left behind"
assert_eq "" "$(_sk_err_ctx_render)" "the stack is empty again after the command returns"

# 判据能力自检：如果分发层不回收，这里 depth 必须是 1（即上面那条会红）
rc=0
_probe_out=$(cli_run probe-leak 2>&1) || rc=$?
assert_eq "7" "$rc" "the second dispatch still returns the command's exit code"
assert_eq "0" "$(_sk_err_ctx_depth)" "repeated dispatches do not accumulate stale frames"
assert_contains "$_probe_out" "[context:" "the failing command's own error still carries its context"

# ---------------------------------------------------------------------------
# 脱敏：上下文里的口令不能出现在任何输出里
# ---------------------------------------------------------------------------

_sk_err_ctx_push "syncing" "dir=/tmp/x" "password=hunter2" "api_token=abc123"
rendered=$(_sk_err_ctx_render)
assert_contains "$rendered" "password=***" "a password parameter is masked"
assert_contains "$rendered" "api_token=***" "an api token parameter is masked"
assert_not_contains "$rendered" "hunter2" "the secret value must not survive in the context"
assert_not_contains "$rendered" "abc123" "the token value must not survive in the context"
assert_contains "$rendered" "dir=/tmp/x" "a harmless parameter is kept as is"

_sk_err_ctx_pop

# ---------------------------------------------------------------------------
# 路径信息：绝对路径 + 软链指向
# ---------------------------------------------------------------------------

plain="$work/plain.txt"
printf 'hello\n' >"$plain"
info=$(_sk_err_path_info "$plain")
assert_contains "$info" "path=" "the path info carries a path field"
assert_contains "$info" "$workabs/plain.txt" "the path info carries the absolute path"
assert_not_contains "$info" "symlink=" "a regular file has no symlink field"

# 软链指向另一个绝对路径
target="$workabs/target.txt"
printf 'hello\n' >"$target"
link="$work/link.txt"
ln -s "$target" "$link"
info=$(_sk_err_path_info "$link")
assert_contains "$info" "symlink=" "a symlink gets a symlink field"
assert_contains "$info" "symlink=$workabs/target.txt" "the symlink field names the link target"

# 相对指向的软链：原样打印「相对谁」对排障没用，要解析成绝对路径
rel="$workabs/rel"
mkdir -p "$rel"
printf 'hello\n' >"$rel/inner.txt"
ln -s "inner.txt" "$rel/rel-link.txt"
info=$(_sk_err_path_info "$rel/rel-link.txt")
assert_contains "$info" "symlink=$workabs/rel/inner.txt" "a relative link target is resolved to an absolute path"

# 相对路径输入也要得到绝对路径
cd "$work" || exit 1
info=$(_sk_err_path_info "plain.txt")
assert_contains "$info" "path=$workabs/plain.txt" "a relative input resolves to an absolute path"
cd "$TEST_ROOT" || exit 1

# ---------------------------------------------------------------------------
# log_error / die 带上下文；栈空时逐字不变
# ---------------------------------------------------------------------------

out=$(log_error "boom" 2>&1)
assert_eq "[ERROR] boom" "$out" "without a context the error text is byte for byte the same"

out=$(log_error "boom" 2>&1)
assert_not_contains "$out" "[context:" "no context marker without a context stack"

_sk_err_ctx_push "syncing" "dir=/tmp/x"
out=$(log_error "boom" 2>&1)
assert_contains "$out" "boom" "the original message survives the context suffix"
assert_contains "$out" "[context:" "the error carries a context marker"
assert_contains "$out" "syncing" "the error names the operation that was running"
assert_contains "$out" "dir=/tmp/x" "the error carries the operation parameters"

# SK_ERRMSG 是「最后一条错误」，也要带上下文 —— 调用方按它拼报告。
# 这里必须直接调用：$(...) 是子 shell，改的是子 shell 的 SK_ERRMSG。
log_error "boom" >/dev/null 2>&1
assert_contains "$SK_ERRMSG" "[context:" "SK_ERRMSG carries the context too"
_sk_err_ctx_pop

# die 走的是 log_error，所以同样带上下文；退出码不受影响
err=$(bash -c '. "$1/lib/bootstrap.sh"; _sk_err_ctx_push "upgrading" "dir=/tmp/p"; die 4 boom' _ "$TEST_ROOT" 2>&1 >/dev/null)
assert_contains "$err" "[context:" "die carries the context"
assert_contains "$err" "upgrading" "die names the running operation"
assert_exit_code 4 bash -c '. "$1/lib/bootstrap.sh"; _sk_err_ctx_push "upgrading"; die 4 boom' _ "$TEST_ROOT" 2>/dev/null

# ---------------------------------------------------------------------------
# CLI 级：vendor 同步
# ---------------------------------------------------------------------------

# 副本里的自有文件被换成了软链 —— 告警必须说清「哪个文件、绝对路径、指向哪里」
proj="$work/proj"
mkdir -p "$proj/vendor/shellkit/lib/core"
# 副本得像真的：CLI 会先看「这是不是一份 shellkit 副本」，不像就直接拒绝
printf '0.0.0\n' >"$proj/vendor/shellkit/VERSION"
printf '# bootstrap\n' >"$proj/vendor/shellkit/lib/bootstrap.sh"
printf '# outside\n' >"$work/outside.sh"
ln -s "$workabs/outside.sh" "$proj/vendor/shellkit/lib/core/log.sh"

out=$("$TEST_ROOT/shellkit" vendor "$proj" 2>&1)
assert_contains "$out" "the target is a symlink, left alone" "the symlink is still reported"
assert_contains "$out" "lib/core/log.sh" "the report names the file"
assert_contains "$out" "$workabs/proj/vendor/shellkit/lib/core/log.sh" \
  "the report carries the absolute path of the target"
assert_contains "$out" "symlink=$workabs/outside.sh" "the report carries the link target"

# 软链没被动过（判据不能只看输出）
assert_true test -L "$proj/vendor/shellkit/lib/core/log.sh"

# vendor 目录本身是软链 —— 拒绝安装的报错要带上下文与链接指向
proj2="$work/proj2"
mkdir -p "$proj2"
ln -s "$workabs/outside.sh" "$proj2/vendor"
out=$("$TEST_ROOT/shellkit" vendor "$proj2" 2>&1)
assert_contains "$out" "the vendor directory is a symlink, refusing to install" "the symlinked vendor dir is refused"
assert_contains "$out" "symlink=$workabs/outside.sh" "the refusal names the link target"
assert_contains "$out" "[context:" "the refusal carries the operation context"

# ---------------------------------------------------------------------------
# CLI 级：upgrade（issue 里的原例）
# ---------------------------------------------------------------------------

up="$work/upgrade-proj"
"$TEST_ROOT/shellkit" new "$up" --name demo --cmd start --yes >/dev/null 2>&1 ||
  _fail "shellkit new failed"
rm -f "$up/lib/app.sh"
ln -s "$workabs/outside.sh" "$up/lib/app.sh"

out=$("$TEST_ROOT/shellkit" upgrade "$up" 2>&1)
assert_contains "$out" "the target is a symlink, left alone" "the symlink is reported during upgrade"
assert_contains "$out" "$workabs/upgrade-proj/lib/app.sh" "the upgrade report carries the absolute path"
assert_contains "$out" "symlink=$workabs/outside.sh" "the upgrade report carries the link target"
assert_true test -L "$up/lib/app.sh"
