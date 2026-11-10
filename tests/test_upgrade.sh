#!/usr/bin/env bash
# upgrade 的回归与故障注入测试。
#
# 这里守的是一条底线：**用户的修改永远不能被升级覆盖掉**。
# 历史缺陷：升级时把「文件当前内容的指纹」写回清单，于是第一次升级跳过了
# 用户改过的文件，第二次升级却以为它没被改过而覆盖掉 —— 用户的手工修改没了。
# 所以每个用例都要连着升两次以上，只升一次证明不了任何事。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

work=$(tmpdir)

# sha256_of FILE —— 各家工具都算得出来同一个摘要
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    openssl dgst -sha256 "$1" | awk '{print $NF}'
  fi
}

# manifest_sum FILE REL —— 清单里记的某个文件的指纹
manifest_sum() {
  awk -v rel="$2" '$1 == "@file" && $2 == rel { print $3; found = 1; exit }
    END { if (!found) print "" }' "$1"
}

tpl="$work/tpl"
cp -R "$TEST_ROOT/templates" "$tpl"
proj="$work/tool"
"$TEST_ROOT/shellkit" new --name tool "$proj" --cmd run --yes >/dev/null 2>&1
assert_true test -f "$proj/.shellkit-manifest"

# ---------------------------------------------------------------- 连续升级不丢修改
printf 'LOCAL EDIT MARKER\n' >>"$proj/README.md"
local_sum=$(sha256_of "$proj/README.md")

out=$("$TEST_ROOT/shellkit" upgrade "$proj" --template "$tpl" 2>&1)
assert_contains "$out" "left alone" "the first upgrade must leave the modified file alone"
assert_contains "$(cat "$proj/README.md")" "LOCAL EDIT MARKER" "the local edit must survive the first upgrade"

# 关键的一条：清单里的基线不能被推进成「用户改过之后的内容」
recorded=$(manifest_sum "$proj/.shellkit-manifest" "README.md")
assert_ne "$local_sum" "$recorded" "the manifest must not record the user's edit as the baseline"

# 第二次升级才是真正的考题：清单里记的还是模板基线，文件还是用户改过的
out=$("$TEST_ROOT/shellkit" upgrade "$proj" --template "$tpl" 2>&1)
assert_contains "$out" "left alone" "the second upgrade must leave the modified file alone"
assert_contains "$(cat "$proj/README.md")" "LOCAL EDIT MARKER" "the local edit must survive the second upgrade"

# 第三次也一样
"$TEST_ROOT/shellkit" upgrade "$proj" --template "$tpl" >/dev/null 2>&1
assert_contains "$(cat "$proj/README.md")" "LOCAL EDIT MARKER" "the local edit must survive the third upgrade"

recorded2=$(manifest_sum "$proj/.shellkit-manifest" "README.md")
assert_eq "$recorded" "$recorded2" "the baseline must not move while the file stays locally modified"

# ---------------------------------------------------------------- 未改过的文件要更新
# 用另一个没被改过的文件（AGENTS.md）：README.md 这会儿正带着用户的修改，
# 它本来就该被跳过，拿它验「会更新」是自相矛盾。
printf '\nTEMPLATE ADDITION\n' >>"$tpl/AGENTS.md"
out=$("$TEST_ROOT/shellkit" upgrade "$proj" --template "$tpl" 2>&1)
assert_contains "$out" "updated" "an unmodified file must be updated"
assert_contains "$(cat "$proj/AGENTS.md")" "TEMPLATE ADDITION" "the template content must land in the project"

# 更新之后，清单里的基线必须等于这个文件当前内容的指纹（模板基线，不是别的）
recorded3=$(manifest_sum "$proj/.shellkit-manifest" "AGENTS.md")
assert_eq "$(sha256_of "$proj/AGENTS.md")" "$recorded3" "the baseline must be the applied template content"

# ---------------------------------------------------------------- 幂等：再升一次没有可更新的
out=$("$TEST_ROOT/shellkit" upgrade "$proj" --template "$tpl" 2>&1)
assert_contains "$out" "0 updated" "an up-to-date project must report nothing to update"

# ---------------------------------------------------------------- --force 才是明确的覆盖意图
printf 'FORCE TARGET MARKER\n' >>"$tpl/README.md"
out=$("$TEST_ROOT/shellkit" upgrade "$proj" --template "$tpl" --force 2>&1)
assert_contains "$(cat "$proj/README.md")" "FORCE TARGET MARKER" "--force must overwrite the local edit"
assert_not_contains "$(cat "$proj/README.md")" "LOCAL EDIT MARKER" "--force must drop the old local edit"

# ---------------------------------------------------------------- 故障注入：文件缺失
p2="$work/missing-file"
"$TEST_ROOT/shellkit" new --name tool "$p2" --cmd run --yes >/dev/null 2>&1
rm -f "$p2/README.md"
out=$("$TEST_ROOT/shellkit" upgrade "$p2" --template "$tpl" 2>&1)
assert_contains "$out" "added" "a missing file must be restored by the upgrade"
assert_true test -f "$p2/README.md"

# ---------------------------------------------------------------- 故障注入：清单不是 shellkit 写的
p3="$work/no-manifest"
mkdir -p "$p3"
printf 'hello\n' >"$p3/README.md"
rc=0
"$TEST_ROOT/shellkit" upgrade "$p3" --template "$tpl" >/dev/null 2>&1 || rc=$?
assert_eq "3" "$rc" "a directory without a manifest must be rejected"
assert_eq "hello" "$(cat "$p3/README.md")" "a rejected upgrade must not touch the files"

# ---------------------------------------------------------------- 故障注入：清单损坏
p4="$work/broken-manifest"
"$TEST_ROOT/shellkit" new --name tool "$p4" --cmd run --yes >/dev/null 2>&1
printf 'garbage\n@@@ not a manifest @@@\n' >"$p4/.shellkit-manifest"
printf 'BROKEN MANIFEST LOCAL EDIT\n' >>"$p4/README.md"
rc=0
out=$("$TEST_ROOT/shellkit" upgrade "$p4" --template "$tpl" 2>&1) || rc=$?
assert_ne "0" "$rc" "a broken manifest must not be treated as a successful upgrade"
assert_contains "$(cat "$p4/README.md")" "BROKEN MANIFEST LOCAL EDIT" "a broken manifest must not cost the user their file"

# ---------------------------------------------------------------- 故障注入：写不进去
if [ "$(id -u)" = "0" ]; then
  printf 'running as root, skipping the read-only directory case\n' >&2
else
  p5="$work/readonly"
  "$TEST_ROOT/shellkit" new --name tool "$p5" --cmd run --yes >/dev/null 2>&1
  printf 'READONLY LOCAL EDIT\n' >>"$p5/README.md"
  # 目录不可写 + 文件不可写：cp -f 先试着打开目标（失败），再试着删掉重建
  # （目录不可写，删不掉）—— 两步都失败才真的写不进去。
  # 目标选 AGENTS.md：模板里它已经变了，升级一定会去写它；
  # 选一个没变化的文件就碰不到写盘这一步（内容一致，直接跳过）。
  chmod 555 "$p5"
  chmod 444 "$p5/AGENTS.md"
  rc=0
  "$TEST_ROOT/shellkit" upgrade "$p5" --template "$tpl" >/dev/null 2>&1 || rc=$?
  chmod 755 "$p5"
  chmod 644 "$p5/AGENTS.md"
  assert_ne "0" "$rc" "an upgrade that cannot write must fail"
  assert_contains "$(cat "$p5/README.md")" "READONLY LOCAL EDIT" "a failed upgrade must not lose the local edit"
  # 权限恢复后再升一次：用户改过的文件依然要被跳过
  out=$("$TEST_ROOT/shellkit" upgrade "$p5" --template "$tpl" 2>&1)
  assert_contains "$out" "left alone" "a failed upgrade must not break the protection of local edits"
  assert_contains "$(cat "$p5/README.md")" "READONLY LOCAL EDIT" "the local edit must survive the recovery upgrade"
  assert_contains "$(cat "$p5/AGENTS.md")" "TEMPLATE ADDITION" "the recovery upgrade must apply the pending template change"
fi

# ---------------------------------------------------------------- 故障注入：中途被杀
p6="$work/interrupted"
"$TEST_ROOT/shellkit" new --name tool "$p6" --cmd run --yes >/dev/null 2>&1
printf 'INTERRUPT LOCAL EDIT\n' >>"$p6/README.md"
"$TEST_ROOT/shellkit" upgrade "$p6" --template "$tpl" >/dev/null 2>&1 &
pid=$!
sleep 0.2
kill -INT "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
# 无论是被打断还是已经跑完，结果都必须是：清单还能用、本地修改还在、工程还能跑
assert_true test -f "$p6/.shellkit-manifest"
assert_contains "$(cat "$p6/.shellkit-manifest")" "template_version=" "the manifest must stay readable after an interrupted upgrade"
assert_contains "$(cat "$p6/README.md")" "INTERRUPT LOCAL EDIT" "an interrupted upgrade must not lose the local edit"
assert_exit_code 0 "$p6/bin/tool" --help

exit 0
