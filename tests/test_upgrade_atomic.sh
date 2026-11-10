#!/usr/bin/env bash
# upgrade 的写盘原子性回归。
#
# 这里守的是一条底线：**写盘被打断时，工程里不能出现半截文件**。
#
# 以前升级用 cp -f 逐个覆盖：cp 先 truncate 目标再写，写到一半被打断
# （断电、磁盘满、进程被杀）留下的是既不是旧内容也不是新内容的半截文件
# （实测 0 字节到 5MB 不等）。现在走 fs_atomic_copy：写同目录的临时文件，
# 再 rename 过去 —— rename 是原子的，失败要么什么都没发生、要么整体换新。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

work=$(tmpdir)
tpl="$work/tpl"
cp -R "$TEST_ROOT/templates" "$tpl"

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    openssl dgst -sha256 "$1" | awk '{print $NF}'
  fi
}

proj="$work/tool"
"$TEST_ROOT/shellkit" new --name tool "$proj" --cmd run --yes >/dev/null 2>&1 || _fail "shellkit new failed"

# 让模板里的 AGENTS.md 与工程里的内容不同 ⇒ 升级一定会去写它
printf '\nTEMPLATE ADDITION\n' >>"$tpl/AGENTS.md"

# 用一个 cp 替身模拟「写到一半被杀掉」：只写前半截就失败退出。
# 真实场景里是断电/磁盘满/进程被杀，结果一样 —— 目标文件要么是旧的完整内容，
# 要么是新的完整内容，不能是半截。
shim="$work/shim"
mkdir -p "$shim"
cat >"$shim/cp" <<'EOS'
#!/usr/bin/env bash
# cp 替身：源是 AGENTS.md 时只写前 20 字节就失败退出。
# 触发条件按「源的路径」而不是「目标的路径」—— 目标在原子写的实现里是临时文件，
# 名字会变；按源触发才与实现无关。
dst=""
src=""
for a in "$@"; do
  case "$a" in
    -*) continue ;;
  esac
  if [ -z "$src" ]; then
    src="$a"
  else
    dst="$a"
  fi
done
case "$src" in
*/AGENTS.md)
  head -c 20 "$dst" >"$dst" 2>/dev/null
  echo "cp: injected failure" >&2
  exit 1
  ;;
esac
exec /bin/cp "$@"
EOS
chmod +x "$shim/cp"

before=$(sha256_of "$proj/AGENTS.md")
rc=0
out=$(PATH="$shim:$PATH" "$TEST_ROOT/shellkit" upgrade "$proj" --template "$tpl" 2>&1) || rc=$?
after=$(sha256_of "$proj/AGENTS.md")

assert_ne "0" "$rc" "an upgrade that cannot write must fail"
assert_eq "$before" "$after" "a failed write must leave the old file intact, not a half-written one"
assert_not_contains "$(cat "$proj/AGENTS.md")" "TEMPLATE ADDITION" \
  "the new template content must not land when the write failed"
assert_not_contains "$out" "unbound variable" "the failure must not crash with an unbound variable"
assert_contains "$out" "failed to write the file" "the failure must say which file failed"

# 写失败留下的临时文件不能留在工程里
leftover=$(find "$proj" -name '*.tmp.*' -type f 2>/dev/null | wc -l | tr -d ' ')
assert_eq "0" "$leftover" "a failed write must not leave temporary files in the project"

# ---------------------------------------------------------------- 正常路径：逐字节一致
out=$("$TEST_ROOT/shellkit" upgrade "$proj" --template "$tpl" 2>&1)
assert_contains "$out" "updated: AGENTS.md" "the retry must apply the pending template change"
assert_contains "$(cat "$proj/AGENTS.md")" "TEMPLATE ADDITION" "the template change must land"
# 模板里是未渲染的占位符，工程里是渲染后的版本 —— 本来就不该逐字节相等。
# 该断言的是：占位符全被渲染掉、渲染结果确实落到文件里。
assert_not_contains "$(cat "$proj/AGENTS.md")" "{{" "the upgraded file must be fully rendered"
assert_contains "$(cat "$proj/AGENTS.md")" "tool" "the upgraded file must carry the project name"

# 再升一次内容不能变（原子替换不是「每次都重写一遍」）
h1=$(sha256_of "$proj/AGENTS.md")
"$TEST_ROOT/shellkit" upgrade "$proj" --template "$tpl" >/dev/null 2>&1
h2=$(sha256_of "$proj/AGENTS.md")
assert_eq "$h1" "$h2" "a second upgrade must not change the file"

# 末尾的换行不能被吃掉（内容参数化的写法会吃掉它）
assert_eq "1" "$(tail -c 1 "$proj/AGENTS.md" | wc -l | tr -d ' ')" \
  "the trailing newline must survive the copy"

# 正常升级也不该留下临时文件
leftover=$(find "$proj" -name '*.tmp.*' -type f 2>/dev/null | wc -l | tr -d ' ')
assert_eq "0" "$leftover" "a successful upgrade must not leave temporary files behind"

# ---------------------------------------------------------------- 目标是符号链接：跳过，不写穿
outside="$work/outside.txt"
printf 'OUTSIDE CONTENT\n' >"$outside"
rm -f "$proj/README.md"
ln -s "$outside" "$proj/README.md"
out=$("$TEST_ROOT/shellkit" upgrade "$proj" --template "$tpl" 2>&1)
assert_contains "$out" "symlink" "a symlinked target must be reported"
assert_eq "OUTSIDE CONTENT" "$(cat "$outside")" "the file outside the project must stay untouched"

exit 0
