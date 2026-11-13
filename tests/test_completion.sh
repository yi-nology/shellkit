#!/usr/bin/env bash
# completion 的两级能力：命令补全（原有）+ 选项补全（批次C）+ --install。
#
# 判据分三层：
#   1. 生成物内容：usage 驱动的选项进了 case 分支（不另立第二份选项清单）
#   2. 行为：source 生成脚本后手动驱动 COMP_WORDS/COMP_CWORD ——
#      文本里有选项不等于补全行为正确，两层必须各测各的
#   3. --install：写对路径、stdout 只给路径、幂等、退出码语义
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

script=$(bash "$TEST_ROOT/shellkit" completion bash) || _fail "cannot generate the bash completion script"

# CASE: 一级命令补全仍在（升级不能把已有能力改没）
assert_contains "$script" "compgen -W" "the bash script still completes command names"
assert_contains "$script" "upgrade" "the command list is in the script"
assert_contains "$script" "complete -F" "the script registers a completion function"

# CASE: 选项从 usage 驱动（单一真相源：改 usage 补全自动跟上）
assert_contains "$script" 'upgrade) __opts="--check --diff --force"' "upgrade options come from its usage"
# doctor 的 [--dir DIR] 带占位符：按空格分词会把方括号组拆散 —— 这条钉住那个 bug
assert_contains "$script" 'doctor) __opts="--dir --json"' "bracketed options with placeholders are extracted"
assert_contains "$script" 'new) __opts="--name --cmd --template --set --yes"' "new takes option words, not placeholders"

# zsh 版同样是两级，case 分支是数组形态
zscript=$(bash "$TEST_ROOT/shellkit" completion zsh) || _fail "cannot generate the zsh completion script"
assert_contains "$zscript" "upgrade) __opts=( --check --diff --force )" "the zsh script carries options as an array"
assert_contains "$zscript" "_describe 'option'" "the zsh script describes options on the second level"

# CASE: 行为分层 —— 第一层补命令、第二层补选项、位置参数不补
d=$(tmpdir) || _fail "cannot create tmpdir"
printf '%s\n' "$script" >"$d/comp.sh"

out=$(bash -c '. "$1"; COMP_WORDS=(shellkit up); COMP_CWORD=1; _shellkit_completions; printf "%s" "${COMPREPLY[@]}"' _ "$d/comp.sh")
assert_contains "$out" "upgrade" "the first level completes command names"

out=$(bash -c '. "$1"; COMP_WORDS=(shellkit upgrade --); COMP_CWORD=2; _shellkit_completions; printf "%s" "${COMPREPLY[@]}"' _ "$d/comp.sh")
assert_contains "$out" "--check" "the second level completes the command options"
assert_contains "$out" "--force" "the second level offers every option of the command"
assert_contains "$out" "--help" "every command can be completed with --help"
assert_not_contains "$out" "upgrade" "the second level must not offer command names again"

out=$(bash -c '. "$1"; COMP_WORDS=(shellkit upgrade /tmp); COMP_CWORD=2; _shellkit_completions; printf "%s" "${COMPREPLY[@]}"' _ "$d/comp.sh")
assert_eq "" "$out" "positional arguments get no candidates (bash 3.2 has no compopt fallback)"

# CASE: --install 写用户级路径，stdout 只给路径、提示走 stderr
h=$(tmpdir) || _fail "cannot create tmpdir"
rc=0
out=$(HOME="$h" bash "$TEST_ROOT/shellkit" completion --install bash 2>"$h/err.log") || rc=$?
assert_eq "0" "$rc" "--install must succeed"
assert_contains "$out" "bash-completion/completions/shellkit" "stdout carries the install path"
__dest="$h/.local/share/bash-completion/completions/shellkit"
assert_true test -f "$__dest"
assert_contains "$(head -1 "$__dest")" "# shellkit completion for bash" "the installed file is the generated script"
assert_contains "$(cat "$h/err.log")" "activate completion" "the activation hint goes to stderr"

# 幂等：重复安装直接覆盖，不留半截文件
rc=0
HOME="$h" bash "$TEST_ROOT/shellkit" completion --install bash >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "installing twice must be idempotent"
assert_true test -f "$__dest"

# zsh 装到 fpath 惯例路径
rc=0
out=$(HOME="$h" bash "$TEST_ROOT/shellkit" completion --install zsh 2>/dev/null) || rc=$?
assert_eq "0" "$rc" "zsh install must succeed"
assert_contains "$out" ".zsh/completions/_shellkit" "zsh installs into the fpath convention"
assert_true test -f "$h/.zsh/completions/_shellkit"

# CASE: 退出码语义 —— 未知 shell 2、HOME 未设 3
rc=0
bash "$TEST_ROOT/shellkit" completion fish >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "an unknown shell is a usage error"
rc=0
env -u HOME bash "$TEST_ROOT/shellkit" completion --install bash >/dev/null 2>&1 || rc=$?
assert_eq "3" "$rc" "installing without HOME is a precondition failure"

# CASE: 选项提取器的边界（直测私有函数：它决定生成物对不对）
opts=$(bash -c '. "$1/lib/bootstrap.sh"; _sk_cli_opts_of "doctor [--dir DIR] [--json]"' _ "$TEST_ROOT")
assert_eq "--dir --json" "$opts" "an option with a placeholder keeps only the option word"
opts=$(bash -c '. "$1/lib/bootstrap.sh"; _sk_cli_opts_of "completion [bash|zsh]"' _ "$TEST_ROOT")
assert_eq "" "$opts" "positional alternatives are not options"
opts=$(bash -c '. "$1/lib/bootstrap.sh"; _sk_cli_opts_of "new [dir] [--name NAME]"' _ "$TEST_ROOT")
assert_eq "--name" "$opts" "the placeholder after the option is dropped"
opts=$(bash -c '. "$1/lib/bootstrap.sh"; _sk_cli_opts_of "no options here"' _ "$TEST_ROOT")
assert_eq "" "$opts" "a usage without options yields an empty string"

exit 0
