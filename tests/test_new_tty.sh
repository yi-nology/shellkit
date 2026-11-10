#!/usr/bin/env bash
#
# shellkit new 的交互提问必须真的发生（真 pty 回归测试）。
#
# 提问循环曾经挂在 heredoc 上：heredoc 抢走 fd 0，循环体内的 ask 判定非交互，
# 「值为空时问一次」在真终端里也永不发生 —— 变量静默留空、manifest 缺值、
# 命令照常 rc=0（issue #31）。管道测试看不到这个缺陷（管道本来就是非交互），
# 必须借 pty：机制与 test_prompt_tty.sh 相同，依赖系统自带的 script(1)，
# 没有就打印一行提示并跳过，不让测试红。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

if ! command -v script >/dev/null 2>&1; then
  printf 'SKIP: script(1) is not available; the pty tests are skipped\n'
  exit 0
fi

work=$(tmpdir)
tpl="$work/tpl"
cp -R "$TEST_ROOT/templates" "$tpl" || _fail "cannot copy the templates"
# 声明一个默认值为空的变量 + 一处引用：这正是「生成时问一次」的触发条件
printf 'GREETING=\n' >>"$tpl/template.config"
printf 'Hello {{GREETING}}\n' >"$tpl/README.md"

RUNNER="$TEST_TMP_ROOT/new_tty_runner.sh"
cat >"$RUNNER" <<EOF
#!/usr/bin/env bash
set -u
cd "$work" || exit 9
"$TEST_ROOT/shellkit" new ./proj --template "$tpl" --cmd start
printf '\nNEWRC=%s\n' "\$?"
EOF
chmod 755 "$RUNNER"

_script_run() {
  case "$(uname -s)" in
    Darwin | *BSD) script -q /dev/null "$@" ;;
    *) script -q -c "'$*'" /dev/null ;;
  esac
}

# 在 pty 里跑 RUNNER；提示语「value for GREETING」出现后再送输入 ——
# 送的时候 ask 已经停在 read 上，不靠 sleep 猜时机。
outf="$TEST_TMP_ROOT/new-pty.out"
: >"$outf"
(
  __waited=0
  while [ "$__waited" -lt 400 ]; do
    if grep -F -q -- 'value for GREETING' "$outf" 2>/dev/null; then
      break
    fi
    sleep 0.05
    __waited=$((__waited + 1))
  done
  printf 'world\n'
  sleep 1
) | _script_run "$RUNNER" >"$outf" 2>&1
raw=$(tr -d '\r' <"$outf")

# pty 自检：这台机器的 script 给不出 tty（或 CLI 没跑到提问）时跳过而不是红
case "$raw" in
  *'value for GREETING'*) ;;
  *)
    printf 'SKIP: script(1) cannot provide a pty here; the pty test is skipped\n'
    exit 0
    ;;
esac

# 提问发生了，用户的回答进了生成物与 manifest，命令成功
assert_contains "$raw" "NEWRC=0" "new must succeed after asking"
assert_contains "$(cat "$work/proj/README.md")" "Hello world" \
  "the answer typed in the pty must be rendered into the project"
assert_contains "$(cat "$work/proj/.shellkit-manifest")" "@var GREETING=world" \
  "the answer typed in the pty must be recorded in the manifest"

# 非交互（--yes）时同样的模板不提问、不卡读：留空继续，仍要成功
rm -rf "$work/proj2"
"$TEST_ROOT/shellkit" new "$work/proj2" --template "$tpl" --cmd start --yes >/dev/null 2>&1 || _fail "--yes must not wait for input"
assert_contains "$(cat "$work/proj2/README.md")" "Hello " \
  "non-interactive generation still renders the (empty) variable"
