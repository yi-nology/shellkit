#!/usr/bin/env bash
#
# 交互问答（ask / ask_yn / ask_choice / confirm）的真 pty 回归测试。
#
# 为什么必须借 pty：这几个函数在「非交互」时（SHELLKIT_NONINTERACTIVE=1 或
# stdin 不是 tty）直接返回默认值，根本不读输入。用管道喂 stdin 恰好就落进
# 非交互分支 ⇒ 测不到「读输入」那段代码，于是曾经「用户输入被静默丢弃、永远
# 返回默认值」的 bug 在管道测试里是看不见的。
# 唯一能同时满足「stdin 是 tty」和「输入可控」的办法是借一个伪终端：
# macOS/BSD 的 script 是 script -q /dev/null CMD...，Linux/GNU 的是
# script -q -c "CMD" /dev/null，这里按 uname 分支。
#
# 依赖系统自带的 script(1)。没有 script、或这台机器的 script 给不出 tty 时，
# 打印一行提示并跳过 —— 不让测试红。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"

if ! command -v script >/dev/null 2>&1; then
  printf 'SKIP: script(1) is not available; the pty tests are skipped
'
  exit 0
fi

RUNNER="$TEST_TMP_ROOT/prompt_tty_runner.sh"

# 在 pty 里跑命令。GNU 的 script 只认 -c "命令串"，路径里不能有单引号。
_script_run() {
  case "$(uname -s)" in
    Darwin | *BSD) script -q /dev/null "$@" ;;
    *) script -q -c "'$*'" /dev/null ;;
  esac
}

# 写一个在 pty 里跑的脚本：加载库，跑用例正文。
# 正文用 printf 追加，避免 heredoc 把正文里的 $VAR 提前展开掉。
_write_runner() {
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -u'
    printf '. "%s"\n' "$TEST_ROOT/lib/bootstrap.sh"
    printf '%s\n' 'export SHELLKIT_NONINTERACTIVE=0'
    printf '%s\n' "$1"
  } >"$RUNNER"
  chmod +x "$RUNNER"
}

# 在 pty 里跑 RUNNER 并喂一行输入，返回去掉 \r 的输出。
# 末尾多睡一会儿：script 读到 stdin EOF 就可能收工，别让它抢在子进程前面。
_pty_run() {
  local __input=$1
  (
    printf '%s\n' "$__input"
    sleep 0.5
  ) | _script_run "$RUNNER" 2>&1 | tr -d '\r'
}

# 从输出里取 KEY=VALUE 的值。
# 提示语是 printf '%s: ' 写的、没有换行，会和标记挤在同一行，所以不能锚定行首。
_pty_value() {
  local __key=$1 __out=$2 __val
  __val=$(printf '%s\n' "$__out" | sed -n "s/.*$__key=\([^[:space:]]*\).*/\1/p" | head -1)
  printf '%s' "${__val#*=}"
}

# pty 自检：这台机器的 script 到底能不能给出 tty
_write_runner 'printf "PTYOK\n"'
raw=$(_pty_run "")
case "$raw" in
  *PTYOK*) ;;
  *)
    printf 'SKIP: script(1) cannot provide a pty here; the pty tests are skipped\n'
    exit 0
    ;;
esac

# CASE: ask_yn 采纳用户输入的 n，而不是默认值 y
body_ask_yn='ask_yn ANS "Continue?" y
printf "\nANS=%s\n" "$ANS"'
_write_runner "$body_ask_yn"
raw=$(_pty_run "n")
assert_eq "n" "$(_pty_value ANS "$raw")" "ask_yn must use the answer the user typed (n), not the default (y)"

# CASE: ask 采纳用户输入的 IP，而不是默认值
body_ask='ask V "IP" 1.2.3.4
printf "\nV=%s\n" "$V"'
_write_runner "$body_ask"
raw=$(_pty_run "9.9.9.9")
assert_eq "9.9.9.9" "$(_pty_value V "$raw")" "ask must use the answer the user typed, not the default"

# CASE: ask_choice 采纳用户输入的选项，而不是默认值
body_choice='ask_choice V "Engine" "mysql|postgresql" mysql
printf "V=%s\n" "$V"'
_write_runner "$body_choice"
raw=$(_pty_run "postgresql")
assert_eq "postgresql" "$(_pty_value V "$raw")" "ask_choice must use the answer the user typed, not the default"

# CASE: confirm 收到 n 时退出码是 1
body_confirm='confirm "Proceed?" y
__rc=$?
printf "\nRC=%s\n" "$__rc"'
_write_runner "$body_confirm"
raw=$(_pty_run "n")
assert_eq "1" "$(_pty_value RC "$raw")" "confirm must exit 1 when the user answers n"
