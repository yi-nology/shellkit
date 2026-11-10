#!/usr/bin/env bash
# 升级的事务性回归。
#
# 这里守的是一条底线：**升级要么整体生效，要么一个文件都不动**。
#
# 以前升级是「边判边写」：判一个文件、立刻写它、再判下一个。
# 中途撞上一个写不下去的目标（目录占了文件名、父路径建不出来、目录不可写），
# 工程就停在半升状态 —— 前几个文件已是新版、后几个还是旧版，清单也对不上磁盘；
# 下一次升级还会把这些文件当成「用户改过」而永久冻结。
#
# 现在升级分两个阶段：先把所有目标判完、校验完（一个文件都不动），
# 有致命问题就直接退出；没有问题才进切换阶段，逐个原子替换。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

work=$(tmpdir)

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

tmpdir_count() {
  ls -d "${TMPDIR:-/tmp}"/shellkit-upgrade.* 2>/dev/null | wc -l | tr -d ' '
}

# assert_true 会把提示文案也当成被测命令的参数传下去（test 会报
# "binary operator expected"）—— 要带说明就自己写这三个。
assert_dir() {
  [ -d "$1" ] || _fail "expected a directory: $1"
  return 0
}

assert_file() {
  [ -f "$1" ] || _fail "expected a file: $1"
  return 0
}

assert_absent() {
  [ ! -e "$1" ] || _fail "expected it to be absent: $1"
  return 0
}

# ---------------------------------------------------------------------------
# 场景一：目标位置是个目录 ⇒ 预检阶段就退出，一个文件都不动
# ---------------------------------------------------------------------------
tpl1="$work/tpl1"
cp -R "$TEST_ROOT/templates" "$tpl1"
printf '\nTEMPLATE ADDITION\n' >>"$tpl1/README.md"
proj1="$work/p1"
"$TEST_ROOT/shellkit" new --name tool "$proj1" --cmd run --yes >/dev/null 2>&1 ||
  _fail "shellkit new failed"
rm -f "$proj1/AGENTS.md"
mkdir -p "$proj1/AGENTS.md"
rc=0
out=$("$TEST_ROOT/shellkit" upgrade "$proj1" --template "$tpl1" 2>&1) || rc=$?
assert_ne "0" "$rc" "an upgrade whose target is a directory must fail"
assert_contains "$out" "AGENTS.md" "the failure must name the file that blocks the upgrade"
assert_dir "$proj1/AGENTS.md"
assert_not_contains "$(cat "$proj1/README.md")" "TEMPLATE ADDITION" \
  "no file may be touched when the pre-flight check fails"

# ---------------------------------------------------------------------------
# 场景二：目标的父路径是个普通文件 ⇒ 同样一个文件都不动
# ---------------------------------------------------------------------------
tpl2="$work/tpl2"
cp -R "$TEST_ROOT/templates" "$tpl2"
printf '\nTEMPLATE ADDITION\n' >>"$tpl2/README.md"
proj2="$work/p2"
"$TEST_ROOT/shellkit" new --name tool "$proj2" --cmd run --yes >/dev/null 2>&1 ||
  _fail "shellkit new failed"
rm -rf "$proj2/tests"
printf 'not a directory\n' >"$proj2/tests"
rc=0
out=$("$TEST_ROOT/shellkit" upgrade "$proj2" --template "$tpl2" 2>&1) || rc=$?
assert_ne "0" "$rc" "an upgrade whose parent path is a file must fail"
assert_not_contains "$(cat "$proj2/README.md")" "TEMPLATE ADDITION" \
  "no file may be touched when the pre-flight check fails"

# ---------------------------------------------------------------------------
# 场景三：切换阶段写失败 ⇒ 目标文件保持完整旧内容，清单与磁盘一致
# ---------------------------------------------------------------------------
tpl3="$work/tpl3"
cp -R "$TEST_ROOT/templates" "$tpl3"
printf '\nTEMPLATE ADDITION\n' >>"$tpl3/README.md"
printf '\nTEMPLATE ADDITION\n' >>"$tpl3/AGENTS.md"
proj3="$work/p3"
"$TEST_ROOT/shellkit" new --name tool "$proj3" --cmd run --yes >/dev/null 2>&1 ||
  _fail "shellkit new failed"
shim3="$work/shim3"
mkdir -p "$shim3"
cat >"$shim3/cp" <<'EOS'
#!/usr/bin/env bash
# cp 替身：源是 AGENTS.md 时只写前 20 字节就失败退出。
# 触发条件按「源的路径」而不是「目标的路径」—— 目标在原子写的实现里是临时文件，
# 名字会变；按源触发才与实现无关。
src=""
dst=""
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
chmod +x "$shim3/cp"
before_agents=$(sha256_of "$proj3/AGENTS.md")
before_tmp=$(tmpdir_count)
rc=0
out=$(PATH="$shim3:$PATH" "$TEST_ROOT/shellkit" upgrade "$proj3" --template "$tpl3" 2>&1) || rc=$?
assert_ne "0" "$rc" "an upgrade that cannot write must fail"
assert_eq "$before_agents" "$(sha256_of "$proj3/AGENTS.md")" \
  "the file that failed to be written must keep its old content"
assert_not_contains "$(cat "$proj3/AGENTS.md")" "TEMPLATE ADDITION" \
  "the half-written content must not land in the project"
# 写失败之前已经写好的文件：清单里的基线必须已经推进，
# 否则下次升级会把它当成「用户改过」，永远不再更新
assert_eq "$(sha256_of "$proj3/README.md")" "$(manifest_sum "$proj3/.shellkit-manifest" "README.md")" \
  "the manifest baseline must match the files that were already written"
assert_eq "$before_tmp" "$(tmpdir_count)" "the temporary directory must be cleaned up after a failure"

# ---------------------------------------------------------------------------
# 场景四：清单写失败 ⇒ 文件已经更新，但清单不能被写坏
# ---------------------------------------------------------------------------
tpl4="$work/tpl4"
cp -R "$TEST_ROOT/templates" "$tpl4"
printf '\nTEMPLATE ADDITION\n' >>"$tpl4/README.md"
proj4="$work/p4"
"$TEST_ROOT/shellkit" new --name tool "$proj4" --cmd run --yes >/dev/null 2>&1 ||
  _fail "shellkit new failed"
shim4="$work/shim4"
mkdir -p "$shim4"
cat >"$shim4/mv" <<'EOS'
#!/usr/bin/env bash
# mv 替身：目标是 .shellkit-manifest 时失败 —— 清单写不进去。
# 文件本身的原子写也用 mv，但目标不是清单，所以不受影响。
dst=""
for a in "$@"; do
  case "$a" in
    -*) continue ;;
  esac
  dst="$a"
done
case "$dst" in
*/.shellkit-manifest)
  echo "mv: injected failure" >&2
  exit 1
  ;;
esac
exec /bin/mv "$@"
EOS
chmod +x "$shim4/mv"
rc=0
out=$(PATH="$shim4:$PATH" "$TEST_ROOT/shellkit" upgrade "$proj4" --template "$tpl4" 2>&1) || rc=$?
assert_ne "0" "$rc" "an upgrade whose manifest cannot be written must fail"
assert_contains "$out" "manifest" "the failure must say the manifest could not be written"
assert_contains "$(cat "$proj4/README.md")" "TEMPLATE ADDITION" \
  "the files that were written before the failure must stay written"
assert_contains "$(cat "$proj4/.shellkit-manifest")" "name=tool" \
  "the old manifest must stay intact instead of being half-written"

# ---------------------------------------------------------------------------
# 场景五：vendor 同步失败 ⇒ 旧副本仍然完整（不是半份库），清单照样落盘
# ---------------------------------------------------------------------------
tpl5="$work/tpl5"
cp -R "$TEST_ROOT/templates" "$tpl5"
printf '\nTEMPLATE ADDITION\n' >>"$tpl5/README.md"
proj5="$work/p5"
"$TEST_ROOT/shellkit" new --name tool "$proj5" --cmd run --yes >/dev/null 2>&1 ||
  _fail "shellkit new failed"
shim5="$work/shim5"
mkdir -p "$shim5"
cat >"$shim5/cp" <<'EOS'
#!/usr/bin/env bash
# cp 替身：源是 lib 目录时失败 —— 模拟 vendor 同步中途挂掉。
for a in "$@"; do
  case "$a" in
    -*) continue ;;
  esac
  if [ -d "$a" ]; then
    case "$a" in
      */lib)
        echo "cp: injected failure" >&2
        exit 1
        ;;
    esac
  fi
done
exec /bin/cp "$@"
EOS
chmod +x "$shim5/cp"
rc=0
out=$(PATH="$shim5:$PATH" "$TEST_ROOT/shellkit" upgrade "$proj5" --template "$tpl5" 2>&1) || rc=$?
assert_ne "0" "$rc" "an upgrade whose vendor sync fails must fail"
assert_file "$proj5/vendor/shellkit/lib/bootstrap.sh"
assert_file "$proj5/vendor/shellkit/shellkit"
# vendor 同步失败不回滚已经写好的文件 ⇒ 清单必须照样落盘，
# 否则这些文件在下次升级里会被判成「用户改过」，永远冻结
assert_eq "$(sha256_of "$proj5/README.md")" "$(manifest_sum "$proj5/.shellkit-manifest" "README.md")" \
  "the manifest must be written even when the vendor sync fails"
assert_absent "$proj5/vendor/.shellkit-new"

# ---------------------------------------------------------------------------
# 场景六：正常路径 —— 文件更新、vendor 换成新的、没有残骸
# ---------------------------------------------------------------------------
tpl6="$work/tpl6"
cp -R "$TEST_ROOT/templates" "$tpl6"
printf '\nTEMPLATE ADDITION\n' >>"$tpl6/README.md"
proj6="$work/p6"
"$TEST_ROOT/shellkit" new --name tool "$proj6" --cmd run --yes >/dev/null 2>&1 ||
  _fail "shellkit new failed"
out=$("$TEST_ROOT/shellkit" upgrade "$proj6" --template "$tpl6" 2>&1)
assert_contains "$out" "upgrade finished" "the upgrade must finish normally"
assert_contains "$(cat "$proj6/README.md")" "TEMPLATE ADDITION" \
  "the template change must land on the project"
assert_eq "$(cat "$TEST_ROOT/VERSION")" "$(cat "$proj6/vendor/shellkit/VERSION")" \
  "the vendored library must be the current one"
assert_absent "$proj6/vendor/.shellkit-new"
assert_absent "$proj6/vendor/.shellkit-old"

exit 0
