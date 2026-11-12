#!/usr/bin/env bash
# skill 客户端发现与配置扩展（issue #64）。
#
# 三条判据：
#   1. 支持新客户端不需要改代码（用户配置可扩展）
#   2. 不凭空造目录：只发现、只提示，目录仍由用户创建
#   3. 内置 7 个只是「默认已知集」，用户配置可覆盖
#
# 每个用例都把 HOME / XDG_CONFIG_HOME 指到自己的临时目录 —— 发现扫的是 $HOME，
# 不隔离就会把开发机上的真实客户端目录扫进断言里（假绿或假红都可能）。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

SK="$TEST_ROOT/shellkit"
cfg=""

# fresh_home —— 造一个空家目录并导出 HOME / XDG_CONFIG_HOME（不放在子 shell 里：
# 命令替换会让 export 只在子进程生效，父进程拿到的还是旧 HOME）
fresh_home() {
  local __d
  __d=$(tmpdir)
  mkdir -p "$__d"
  # 归一 HOME：tmpdir 给的路径可能带 //（TMPDIR 尾斜杠），而 pwd 会把它折成
  # 单斜杠 —— 不归一的话「记录的路径」和「扫到的路径」永远差一个字符。
  HOME=$(cd "$__d" && pwd)
  XDG_CONFIG_HOME="$__d/.config"
  export HOME XDG_CONFIG_HOME
  cfg="$XDG_CONFIG_HOME/shellkit/skill-clients"
}

# CASE: 空家目录 —— 只有内置默认集，没有发现段
fresh_home
out=$("$SK" skill list 2>&1)
assert_eq "0" "$?" "skill list must succeed"
for __c in claude codex mcode opencode cursor gemini windsurf; do
  assert_contains "$out" "$__c" "the default set must still list $__c"
done
assert_not_contains "$out" "discovered" "an empty home has nothing to discover"
assert_not_contains "$out" "install with" "nothing to hint at without a candidate"

# CASE: 发现 —— 扫到新目录，给出能直接粘贴的命令，但不创建任何东西
mkdir -p "$HOME/.newclient/skills"
before=$(find "$HOME" | sort)
out=$("$SK" skill list 2>&1)
assert_contains "$out" "discovered, not in the list yet" "a candidate directory must be reported"
assert_contains "$out" "newclient" "the candidate must be named after its parent directory"
assert_contains "$out" "--dir $HOME/.newclient/skills" "the hint must carry the exact directory"
assert_contains "$out" "--client newclient" "the hint must carry a client name to remember it by"
assert_not_contains "$out" "--client .newclient" "the suggested name must not keep a leading dot"
after=$(find "$HOME" | sort)
assert_eq "$before" "$after" "discovery must not create, move or delete anything"

# CASE: --client + --dir —— 装进去，并把新客户端记进用户配置
out=$("$SK" skill install --dir "$HOME/.newclient/skills" --client newclient 2>&1)
assert_eq "0" "$?" "installing into an explicit directory must succeed"
assert_true test -f "$HOME/.newclient/skills/shellkit/SKILL.md"
assert_true test -f "$cfg"
assert_contains "$(cat "$cfg")" "newclient $HOME/.newclient/skills" "the record must name the client and the directory"

# CASE: 记录是幂等的 —— 跑两次还是一行
"$SK" skill install --dir "$HOME/.newclient/skills" --client newclient >/dev/null 2>&1
assert_eq "1" "$(grep -c . "$cfg")" "re-recording the same client must not duplicate the line"

# CASE: 记过之后进了全表 —— 只给 --client 也能装
rm -rf "$HOME/.newclient/skills/shellkit"
out=$("$SK" skill install --client newclient 2>&1)
assert_eq "0" "$?" "a remembered client must be installable by name alone"
assert_true test -f "$HOME/.newclient/skills/shellkit/SKILL.md"

# CASE: 卸载同样认配置里的客户端
"$SK" skill uninstall --client newclient >/dev/null 2>&1
assert_eq "0" "$?" "uninstalling a remembered client must succeed"
assert_false test -e "$HOME/.newclient/skills/shellkit/SKILL.md"

# CASE: 已知客户端不被 --dir 改写 —— --dir 对内置表是一次性逃生舱
fresh_home
"$SK" skill install --dir "$HOME/.somewhere/skills" --client claude >/dev/null 2>&1
assert_eq "0" "$?" "installing a built-in client into an explicit directory must succeed"
assert_false test -f "$cfg"
out=$("$SK" skill list 2>&1)
assert_contains "$out" "$HOME/.claude/skills" "claude must keep its built-in path"

# CASE: 相对路径的 --dir 记下来时转成绝对 —— 换个工作目录就指错地方了
fresh_home
mkdir -p "$HOME/.relclient/skills"
rc=0
(cd "$HOME" && "$SK" skill install --dir .relclient/skills --client relclient >/dev/null 2>&1) || rc=$?
assert_eq "0" "$rc" "installing from a relative directory must succeed"
assert_contains "$(cat "$cfg")" "relclient $HOME/.relclient/skills" "the record must store an absolute path"

# CASE: 手写的配置也能扩表 —— 不改代码就能加新客户端
fresh_home
mkdir -p "$HOME/.handmade/skills"
mkdir -p "$(dirname "$cfg")"
printf 'handmade %s\n' "$HOME/.handmade/skills" >"$cfg"
out=$("$SK" skill list 2>&1)
assert_contains "$out" "handmade" "a hand-written entry must show up"
assert_not_contains "$out" "discovered, not in the list yet" "a configured client is no longer a candidate"
out=$("$SK" skill install --client handmade 2>&1)
assert_eq "0" "$?" "a hand-written client must be installable"
assert_true test -f "$HOME/.handmade/skills/shellkit/SKILL.md"

# CASE: 配置覆盖内置默认 —— 同名只留一行，且路径以配置为准
fresh_home
mkdir -p "$(dirname "$cfg")"
printf 'claude %s\n' "$HOME/.claude-elsewhere/skills" >"$cfg"
out=$("$SK" skill list 2>&1)
assert_contains "$out" "$HOME/.claude-elsewhere/skills" "the configured path must win"
assert_not_contains "$out" "$HOME/.claude/skills" "the overridden built-in path must not appear twice"

# CASE: 脏行不进表 —— 配置是手编的，坏行不能变成安装目标（坑 7）
fresh_home
mkdir -p "$HOME/.ok/skills"
mkdir -p "$(dirname "$cfg")"
{
  printf 'bad name /tmp/x\n'
  printf 'nodir\n'
  printf '../escape /tmp/y\n'
  printf '# a comment\n'
  printf 'ok %s\n' "$HOME/.ok/skills"
} >"$cfg"
out=$("$SK" skill list 2>&1)
assert_contains "$out" "ok" "a well-formed entry must survive the filter"
assert_not_contains "$out" "/tmp/x" "a name with a space must be rejected"
assert_not_contains "$out" "nodir" "a line without a path must be rejected"
assert_not_contains "$out" "/tmp/y" "a traversal-looking name must be rejected"

# CASE: 配置目录是软链就拒绝记录 —— 不顺着软链写到别处（坑 8）
fresh_home
mkdir -p "$HOME/.config" "$HOME/.elsewhere"
ln -s "$HOME/.elsewhere" "$HOME/.config/shellkit"
mkdir -p "$HOME/.linked/skills"
out=$("$SK" skill install --dir "$HOME/.linked/skills" --client linked 2>&1)
assert_eq "0" "$?" "a symlinked config directory must not fail the install itself"
assert_contains "$out" "the target is a symlink, left alone" "the refused record must be reported"
assert_false test -e "$HOME/.elsewhere/skill-clients"

# CASE: 家目录是空串 —— 拿不到配置文件也不能崩，更不能凭空造目录
fresh_home
out=$(HOME="" XDG_CONFIG_HOME="" "$SK" skill list 2>&1)
assert_eq "0" "$?" "listing without a usable home directory must still succeed"
assert_contains "$out" "claude" "the built-in set must survive a missing home directory"
assert_not_contains "$out" "discovered" "discovery without a home directory finds nothing"
