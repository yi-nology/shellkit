#!/usr/bin/env bash
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

work=$(tmpdir)
proj="$work/demo-tool"

out=$("$TEST_ROOT/shellkit" new "$proj" --cmd start --cmd stop 2>&1)
assert_true test -d "$proj"
assert_contains "$out" "project created" "new reports success"

# 结构完整
for p in bin/demo-tool lib/app.sh commands/start.sh commands/stop.sh \
  tests/run.sh tests/test_helper.sh tests/test_smoke.sh \
  config.example Makefile .shellcheckrc README.md AGENTS.md .shellkit-manifest \
  vendor/shellkit/lib/bootstrap.sh vendor/shellkit/VERSION; do
  if [ ! -e "$proj/$p" ]; then
    _fail "missing generated file: $p"
  fi
done

assert_file_mode "$proj/bin/demo-tool" "755"

# 占位符必须全部被替换
if grep -rq '{{NAME}}|{{CMD}}|{{SHELLKIT_VERSION}}|{{DESCRIPTION}}' \
  "$proj/bin" "$proj/lib" "$proj/commands" "$proj/tests" "$proj/README.md" "$proj/AGENTS.md"; then
  _fail "unrendered placeholder left in generated project"
fi

# 生成物能跑：help / version / 两个命令 / 未知命令返回 2
assert_exit_code 0 "$proj/bin/demo-tool" --help
assert_exit_code 0 "$proj/bin/demo-tool" start
assert_exit_code 0 "$proj/bin/demo-tool" stop
assert_exit_code 2 "$proj/bin/demo-tool" nope

# stdout 只给数据：日志不能出现
out=$("$proj/bin/demo-tool" start 2>/dev/null)
assert_not_contains "$out" "[INFO]" "logs must go to stderr"

# 空目录可以复用，非空目录必须拒绝
assert_exit_code 3 "$TEST_ROOT/shellkit" new "$proj"

# ---------------------------------------------------------------- 模板变量
p2="$work/with-vars"
out=$("$TEST_ROOT/shellkit" new "$p2" --cmd run --set DESCRIPTION="我的工具" --yes 2>&1)
assert_contains "$out" "project created"
assert_contains "$(cat "$p2/README.md")" "我的工具" "template variable must be rendered"

# template.config 的默认值在没给 --set 时生效
p2b="$work/with-default"
"$TEST_ROOT/shellkit" new "$p2b" --cmd run --yes >/dev/null 2>&1
assert_contains "$(cat "$p2b/README.md")" "A command line tool" "template.config default must be applied"

# --set 覆盖 template.config 的默认值
assert_not_contains "$(cat "$p2/README.md")" "A command line tool" "--set must override the default"

# --set 的参数形态不对要报用法错
assert_exit_code 2 "$TEST_ROOT/shellkit" new "$work/bad-set" --set NOEQUALS --yes

# ---------------------------------------------------------------- 自定义模板
tpl="$work/tpl"
cp -R "$TEST_ROOT/templates" "$tpl"
printf '# {{NAME}}\n\nCUSTOM TEMPLATE MARKER\n' >"$tpl/README.md"
p3="$work/custom"
out=$("$TEST_ROOT/shellkit" new "$p3" --template "$tpl" --cmd run --yes 2>&1)
assert_contains "$out" "project created"
assert_contains "$(cat "$p3/README.md")" "CUSTOM TEMPLATE MARKER" "custom template must be used"

# 模板目录不存在要报前置条件错
assert_exit_code 3 "$TEST_ROOT/shellkit" new "$work/no-tpl" --template "$work/nope" --yes

# ---------------------------------------------------------------- 钩子
tpl2="$work/tpl2"
cp -R "$TEST_ROOT/templates" "$tpl2"
mkdir -p "$tpl2/template.hooks.d"
cat >"$tpl2/template.hooks.d/pre" <<'HOOK'
#!/usr/bin/env bash
printf 'pre %s %s\n' "$SHELLKIT_PROJECT_NAME" "$SHELLKIT_PROJECT_COMMANDS" >"$SHELLKIT_PROJECT_DIR/pre.marker"
HOOK
cat >"$tpl2/template.hooks.d/post" <<'HOOK'
#!/usr/bin/env bash
printf 'post %s\n' "$SHELLKIT_TEMPLATE_VERSION" >"$SHELLKIT_PROJECT_DIR/post.marker"
HOOK
chmod 755 "$tpl2/template.hooks.d/pre" "$tpl2/template.hooks.d/post"
p4="$work/hooked"
"$TEST_ROOT/shellkit" new "$p4" --template "$tpl2" --cmd alpha --yes >/dev/null 2>&1
assert_true test -f "$p4/pre.marker"
assert_true test -f "$p4/post.marker"
assert_contains "$(cat "$p4/pre.marker")" "alpha" "hook must receive the command list"

# 钩子失败必须让生成失败
tpl3="$work/tpl3"
cp -R "$TEST_ROOT/templates" "$tpl3"
mkdir -p "$tpl3/template.hooks.d"
printf '#!/usr/bin/env bash\nexit 3\n' >"$tpl3/template.hooks.d/pre"
chmod 755 "$tpl3/template.hooks.d/pre"
assert_exit_code 1 "$TEST_ROOT/shellkit" new "$work/hook-fail" --template "$tpl3" --cmd run --yes

# ---------------------------------------------------------------- upgrade
# 没被改过的文件要更新；被改过的文件要留着不动
tpl4="$work/tpl4"
cp -R "$TEST_ROOT/templates" "$tpl4"
p5="$work/upgradable"
"$TEST_ROOT/shellkit" new "$p5" --cmd run --yes >/dev/null 2>&1
printf '\nNEW LINE FROM TEMPLATE\n' >>"$tpl4/README.md"

out=$("$TEST_ROOT/shellkit" upgrade "$p5" --template "$tpl4" --check 2>&1)
assert_contains "$out" "would update"
assert_not_contains "$(cat "$p5/README.md")" "NEW LINE FROM TEMPLATE" "--check must not write anything"

out=$("$TEST_ROOT/shellkit" upgrade "$p5" --template "$tpl4" 2>&1)
assert_contains "$out" "updated"
assert_contains "$(cat "$p5/README.md")" "NEW LINE FROM TEMPLATE" "unmodified file must be updated"

# 用户改过的文件不覆盖
printf 'LOCAL EDIT\n' >>"$p5/README.md"
out=$("$TEST_ROOT/shellkit" upgrade "$p5" --template "$tpl4" 2>&1)
assert_contains "$out" "left alone"
assert_contains "$(cat "$p5/README.md")" "LOCAL EDIT" "locally modified file must be kept"

# 用户自己的命令文件永远不被升级碰
printf '# my own command\n' >>"$p5/commands/run.sh"
"$TEST_ROOT/shellkit" upgrade "$p5" --template "$tpl4" >/dev/null 2>&1
assert_contains "$(cat "$p5/commands/run.sh")" "my own command" "user files must never be touched"

# 不是 shellkit 生成的目录要报前置条件错
assert_exit_code 3 "$TEST_ROOT/shellkit" upgrade "$work" --yes

# upgrade 后清单要跟着更新
assert_contains "$(cat "$p5/.shellkit-manifest")" "template_version=" "manifest must record the template version"

# ---------------------------------------------------------------- 补全
out=$("$TEST_ROOT/shellkit" completion bash 2>&1)
assert_contains "$out" "complete -F" "bash completion must be generated"
assert_contains "$out" "new" "completion must list the subcommands"
out=$("$TEST_ROOT/shellkit" completion zsh 2>&1)
assert_contains "$out" "compdef" "zsh completion must be generated"
assert_exit_code 2 "$TEST_ROOT/shellkit" completion fish

# ---------------------------------------------------------------- 工程闭环
# 生成的工程要能自己升级、自己补全、知道自己的库版本。
p6="$work/loop-tool"
"$TEST_ROOT/shellkit" new "$p6" --cmd run --yes >/dev/null 2>&1

if ! command -v make >/dev/null 2>&1; then
  printf 'make not installed, skipping the project make targets\n' >&2
  exit 0
fi

# help 里要列出新目标
out=$(make -C "$p6" help 2>&1)
assert_contains "$out" "make upgrade" "help must list the upgrade target"
assert_contains "$out" "make completion" "help must list the completion target"
assert_contains "$out" "make version" "help must list the version target"
assert_contains "$out" "make vendor" "help must list the vendor target"

# version 打印工程用的库版本
out=$(make -C "$p6" version 2>&1)
assert_contains "$out" "$(tr -d '[:space:]' <"$p6/vendor/shellkit/VERSION")" \
  "version must print the vendored library version"

# completion：脚本走 stdout，安装提示走 stderr
out=$(make -C "$p6" completion 2>/dev/null)
assert_contains "$out" "complete -F" "completion must print a bash completion script"
assert_contains "$out" "run" "completion must list the project subcommands"
err=$(make -C "$p6" completion 2>&1 >/dev/null)
assert_contains "$err" "bash_completion.d" "completion must say where to install the script"

# 工程入口自己也能出补全脚本，不依赖 PATH 上的 shellkit
out=$("$p6/bin/loop-tool" --completion bash 2>/dev/null)
assert_contains "$out" "complete -F" "the project entry must print its own completion script"

# 已经是最新模板时，升级要报 0 updated，而不是失败
out=$(PATH="$TEST_ROOT:$PATH" make -C "$p6" upgrade 2>&1)
assert_contains "$out" "0 updated" "upgrade must report that nothing changed"

# 工程自带 CLI：PATH 上没有 shellkit 也能升级（离线升级闭环）
#
# PATH 里只留 /bin 与 /usr/bin：coreutils 与 bash 还在，但 shellkit 不在
# （装在 ~/.local/bin 或 /usr/local/bin 都不在这个 PATH 里）。
mkdir -p "$work/empty-bin"
rc=0
out=$(PATH="$work/empty-bin:/bin:/usr/bin" "$(command -v make)" -C "$p6" upgrade 2>&1) || rc=$?
assert_eq "0" "$rc" "the project must upgrade with its own vendored CLI"
assert_contains "$out" "0 updated" "the offline upgrade must report that nothing changed"

# 副本里的 CLI 也要真的能用（不是摆设）
assert_true test -x "$p6/vendor/shellkit/shellkit"
vver=$("$p6/vendor/shellkit/shellkit" --version 2>/dev/null || true)
assert_eq "$(cat "$TEST_ROOT/VERSION")" "$vver" "the vendored CLI must report the synced version"

# 把副本里的 CLI 删掉（模拟只借了库、没带 CLI 的工程），这时要给清楚提示
rm -f "$p6/vendor/shellkit/shellkit"
rc=0
out=$(PATH="$work/empty-bin:/bin:/usr/bin" "$(command -v make)" -C "$p6" upgrade 2>&1) || rc=$?
assert_ne "$rc" "0" "upgrade must fail when no shellkit is available"
assert_contains "$out" "shellkit" "upgrade must say that shellkit is missing"

# vendor 把库镜像进工程
out=$(PATH="$TEST_ROOT:$PATH" make -C "$p6" vendor 2>&1)
assert_contains "$out" "vendored library" "vendor must sync the library into the project"
assert_true test -r "$p6/vendor/shellkit/VERSION"
