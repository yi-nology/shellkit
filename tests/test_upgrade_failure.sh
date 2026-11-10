#!/usr/bin/env bash
# upgrade 写盘失败时的行为回归。
#
# 这里守的是一条底线：**写盘失败要说得清话，不能崩，也不能留垃圾**。
#
# 历史缺陷：失败分支引用了一个还没赋值的局部变量，在 set -u 下直接
# 「unbound variable」崩掉 —— 于是「失败时把清单写成与磁盘一致」这个
# 修复一次都没执行过，临时目录也留在 /tmp 里没人清。
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

manifest_sum() {
  awk -v rel="$2" '$1 == "@file" && $2 == rel { print $3; found = 1; exit }
    END { if (!found) print "" }' "$1"
}

proj="$work/tool"
"$TEST_ROOT/shellkit" new --name tool "$proj" --cmd run --yes >/dev/null 2>&1 || _fail "shellkit new failed"

# 让模板里的 AGENTS.md 与工程里的内容不同 ⇒ 升级一定会去写它
printf '\nTEMPLATE ADDITION\n' >>"$tpl/AGENTS.md"

# 用一个 cp 替身让写盘失败：命中 AGENTS.md 就报错退出
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

tmpdir_count() {
  ls -d "${TMPDIR:-/tmp}"/shellkit-upgrade.* 2>/dev/null | wc -l | tr -d ' '
}

# 升级的临时目录建在 TMPDIR 下 —— 把 TMPDIR 指到本用例自己的目录，
# 否则这里数的是**整台机器**上的 shellkit-upgrade.*：别的进程同时在跑升级
# 就会改掉计数 ⇒ 断言随机红。
mkdir -p "$work/tmp"
export TMPDIR="$work/tmp"

before_tmp=$(tmpdir_count)
rc=0
out=$(PATH="$shim:$PATH" "$TEST_ROOT/shellkit" upgrade "$proj" --template "$tpl" 2>&1) || rc=$?
after_tmp=$(tmpdir_count)

assert_ne "0" "$rc" "an upgrade that cannot write must fail"
assert_not_contains "$out" "unbound variable" "the failure must not crash with an unbound variable"
assert_contains "$out" "failed to write the file" "the failure must say which file failed"
assert_eq "$before_tmp" "$after_tmp" "the temporary directory must be cleaned up after a failure"

# 写失败的那个文件不能被当成「用户改过」而永久冻结：
# 清单里的基线必须还是磁盘上的那个内容，重试时才能把模板改动升进去
recorded=$(manifest_sum "$proj/.shellkit-manifest" "AGENTS.md")
current=$(sha256_of "$proj/AGENTS.md")
assert_eq "$current" "$recorded" "the manifest baseline must match the file that was not written"

# 恢复写权限后再升一次：这次必须能把待升的模板改动升进去
out=$("$TEST_ROOT/shellkit" upgrade "$proj" --template "$tpl" 2>&1)
assert_contains "$out" "updated: AGENTS.md" "the pending template change must still be applicable"
assert_contains "$(cat "$proj/AGENTS.md")" "TEMPLATE ADDITION" "the template change must land on the retry"
assert_contains "$out" "upgrade finished" "the retry must finish normally"

exit 0
