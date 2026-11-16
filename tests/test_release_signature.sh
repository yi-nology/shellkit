#!/usr/bin/env bash
# 发布资产的签名覆盖面（评估 2026-11-16）：
#   同一个版本里「有的资产能验、有的不能验」= 不同渠道不同完整性保证。
# 这里钉三件事：
#   1. 没配私钥 + --require ⇒ 硬失败（3），不产出无签名资产；
#   2. 签完之后**每一个**资产都有自己的 .minisig，且 verify_release 全过；
#   3. 少一个签名、或内容被改过一个字节 ⇒ verify_release 必须失败。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

if ! command -v minisign >/dev/null 2>&1; then
  printf 'minisign is not installed; the signature coverage checks are skipped\n'
  exit 0
fi

d=$(tmpdir)
root="$d/repo"
dist="$d/dist"
mkdir -p "$root/tools" "$dist"
cp "$TEST_ROOT/tools/sign_release.sh" "$TEST_ROOT/tools/verify_release.sh" "$root/tools/"
printf '9.9.9\n' >"$root/VERSION"
for f in install.sh repair.sh demo.sh; do
  printf '#!/bin/sh\ntrue\n' >"$root/$f"
done

# dist 里：两个 tarball + deb + rpm
printf 'payload\n' >"$d/payload.txt"
tar -czf "$dist/shellkit-9.9.9.tar.gz" -C "$d" payload.txt
tar -czf "$dist/shellkit-skill-9.9.9.tar.gz" -C "$d" payload.txt
printf 'deb\n' >"$dist/shellkit-9.9.9.deb"
printf 'rpm\n' >"$dist/shellkit-9.9.9.rpm"
{
  (cd "$dist" && sha256sum shellkit-9.9.9.tar.gz shellkit-skill-9.9.9.tar.gz shellkit-9.9.9.deb shellkit-9.9.9.rpm)
  (cd "$root" && sha256sum install.sh repair.sh demo.sh)
} >"$dist/SHA256SUMS"

# 1) 没配私钥 + --require ⇒ 3
rc=0
env -u SHELLKIT_MINISIGN_KEY bash "$root/tools/sign_release.sh" --dist "$dist" --require >"$d/nokey.log" 2>&1 || rc=$?
assert_eq "3" "$rc" "signing without a key must fail in --require mode"
assert_contains "$(cat "$d/nokey.log")" "required for a release" "the refusal must say why"
assert_false test -f "$dist/SHA256SUMS.minisig"

# 2) 真签一遍
keydir="$d/keys"
mkdir -p "$keydir"
minisign -G -p "$keydir/k.pub" -s "$keydir/k.key" -W >/dev/null 2>&1 ||
  _fail "cannot generate a throwaway minisign key"

rc=0
SHELLKIT_MINISIGN_KEY="$keydir/k.key" SHELLKIT_MINISIGN_PUBKEY="$keydir/k.pub" \
  bash "$root/tools/sign_release.sh" --dist "$dist" --require >"$d/sign.log" 2>&1 || rc=$?
assert_eq "0" "$rc" "signing with a key must succeed"

# 发布目录 = 用户看到的样子：dist 的文件 + 仓库根上那三个脚本，各自带签名
rel="$d/release"
mkdir -p "$rel"
cp "$dist"/* "$rel"/
for f in install.sh repair.sh demo.sh; do
  cp "$root/$f" "$root/$f.minisig" "$rel"/
done
cp "$dist/shellkit.minisign.pub" "$rel"/

for f in shellkit-9.9.9.tar.gz shellkit-skill-9.9.9.tar.gz shellkit-9.9.9.deb shellkit-9.9.9.rpm \
  SHA256SUMS install.sh repair.sh demo.sh; do
  if [ ! -f "$rel/$f.minisig" ]; then
    _fail "every published asset needs its own signature: $f has none"
  fi
done

rc=0
bash "$root/tools/verify_release.sh" --dist "$rel" --pub "$keydir/k.pub" >"$d/ok.log" 2>&1 || rc=$?
assert_eq "0" "$rc" "a fully signed release must verify: $(tail -2 "$d/ok.log")"

# 3a) 少一个签名 ⇒ 必须失败
rm -f "$rel/repair.sh.minisig"
rc=0
bash "$root/tools/verify_release.sh" --dist "$rel" --pub "$keydir/k.pub" >"$d/miss.log" 2>&1 || rc=$?
assert_ne "0" "$rc" "a missing signature must fail the verification"
assert_contains "$(cat "$d/miss.log")" "unsigned asset: repair.sh" "the failure must name the unsigned asset"

# 3b) 改一个字节 ⇒ 必须失败
cp "$root/repair.sh.minisig" "$rel/repair.sh.minisig"
printf 'tampered\n' >>"$rel/demo.sh"
rc=0
bash "$root/tools/verify_release.sh" --dist "$rel" --pub "$keydir/k.pub" >"$d/bad.log" 2>&1 || rc=$?
assert_ne "0" "$rc" "a tampered asset must fail the verification"
assert_contains "$(cat "$d/bad.log")" "does not verify" "the failure must say the signature does not verify"

exit 0
