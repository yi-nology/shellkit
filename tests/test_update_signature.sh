#!/usr/bin/env bash
# shellkit update 也要验 minisign 签名（与 install.sh 同口径）。
#
# 背景：install.sh 配了 SHELLKIT_MINISIGN_PUBKEY 就验 SHA256SUMS.minisig 与
# tarball 签名（docs/TRUST.md）；而 update 这条路只有 sha256 —— SHA256SUMS 与
# 包走**同一个下载通道**，中间人可以一起换掉 ⇒ 签名在升级路径上等于没用。
#
# 判据跑真的 `bash shellkit update`（PATH 上假 curl + 假 minisign，离线）：
# 假 release 是现场造的一个真 tar.gz（--check 要解包、找 VERSION 才能报版本号）。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

work=$(tmpdir)
mkdir -p "$work/bin" "$work/misbin" "$work/prefix" "$work/rel"
log=$work/curl.log
mlog=$work/minisign.log

# 已安装的前缀（版本 = 最新版）：真实更新路径在「已经是最新的」处收尾 ——
# 验签、sha256、解包全都跑过，但不会真的去动安装目录（install-self 不会被调）。
# ⚠️ 不能用 --check：它在**解析出版本号之后就返回**，根本走不到下载与验签段。
mkdir -p "$work/prefix/share/shellkit"
printf '9.9.9\n' >"$work/prefix/share/shellkit/VERSION"

# ---------- 造一个能走完整个 --check 流程的假 release ----------
src="$work/rel/src/shellkit-9.9.9"
mkdir -p "$src/lib" "$src/templates"
printf '9.9.9\n' >"$src/VERSION"
printf '#!/usr/bin/env bash\n' >"$src/shellkit"
tar -C "$work/rel/src" -czf "$work/rel/shellkit-9.9.9.tar.gz" shellkit-9.9.9 ||
  _fail "cannot build the fake tarball"
if command -v sha256sum >/dev/null 2>&1; then
  sum=$(sha256sum "$work/rel/shellkit-9.9.9.tar.gz" | awk '{print $1}')
else
  sum=$(shasum -a 256 "$work/rel/shellkit-9.9.9.tar.gz" | awk '{print $1}')
fi
printf '%s  %s\n' "$sum" 'shellkit-9.9.9.tar.gz' >"$work/rel/SHA256SUMS"
printf 'dummy-signature\n' >"$work/rel/SHA256SUMS.minisig"
printf 'dummy-signature\n' >"$work/rel/shellkit-9.9.9.tar.gz.minisig"

# 假 curl：按 URL 分派（.minisig 必须排在 .tar.gz / SHA256SUMS 前面判）。
cat >"$work/bin/curl" <<'FAKE'
#!/usr/bin/env bash
prev=""
ofile=""
url=""
for a in "$@"; do
  case "$prev" in
    -o) ofile=$a ;;
  esac
  case "$a" in
    -o) prev=$a ;;
    *) prev="" ;;
  esac
  case "$a" in
    http*) url=$a ;;
  esac
done
has_w=0
for a in "$@"; do
  case "$a" in
    -w*) has_w=1 ;;
  esac
done
printf '%s\n' "$*" >>"$FAKE_CURL_LOG"
# 只有带 -w 的调用才往 stdout 打状态码（真 curl 的 -o 下载路径 stdout 是空的 ——
# 不区分就会把 "200" 混进被测命令的 stdout，把断言搅黄）
case "$url" in
*api.github.com*)
  printf '%s' '{"tag_name":"v9.9.9"}' >"$ofile"
  [ "$has_w" = 1 ] && printf '%s' '200'
  ;;
*SHA256SUMS.minisig*)
  [ "${FAKE_SUMS_SIG_MISSING:-0}" = 1 ] && exit 22
  printf '%s' 'dummy-signature' >"$ofile"
  [ "$has_w" = 1 ] && printf '%s' '200'
  ;;
*.tar.gz.minisig*)
  [ "${FAKE_TGZ_SIG_MISSING:-0}" = 1 ] && exit 22
  printf '%s' 'dummy-signature' >"$ofile"
  [ "$has_w" = 1 ] && printf '%s' '200'
  ;;
*/SHA256SUMS)
  cat "$FAKE_SUMS" >"$ofile"
  [ "$has_w" = 1 ] && printf '%s' '200'
  ;;
*.tar.gz)
  cat "$FAKE_TARBALL" >"$ofile"
  [ "$has_w" = 1 ] && printf '%s' '200'
  ;;
*) exit 22 ;;
esac
exit 0
FAKE
chmod +x "$work/bin/curl"

# 假 minisign：记录参数、退出码由 FAKE_MINISIGN_RC 决定
cat >"$work/misbin/minisign" <<'MIS'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_MINISIGN_LOG"
exit "${FAKE_MINISIGN_RC:-0}"
MIS
chmod +x "$work/misbin/minisign"

# _run_update CLI —— 跑 update（真实路径，验签段在里面）；结果在 out / rc。
# WITH_MINISIGN=0 时不把假 minisign 放进 PATH（用例 H 要造「机器上没有 minisign」）。
out=""
rc=0
_run_update() {
  local __cli=$1 __with_mis=${2:-1} __path
  if [ "$__with_mis" = 1 ]; then
    __path="$work/bin:$work/misbin:$PATH"
  else
    __path="$work/bin:$PATH"
  fi
  out=""
  rc=0
  out=$(PATH="$__path" FAKE_CURL_LOG="$log" FAKE_MINISIGN_LOG="$mlog" \
    FAKE_TARBALL="$work/rel/shellkit-9.9.9.tar.gz" FAKE_SUMS="$work/rel/SHA256SUMS" \
    FAKE_SUMS_SIG_MISSING="${FAKE_SUMS_SIG_MISSING:-0}" \
    FAKE_TGZ_SIG_MISSING="${FAKE_TGZ_SIG_MISSING:-0}" \
    FAKE_MINISIGN_RC="${FAKE_MINISIGN_RC:-0}" \
    GH_TOKEN='' GITHUB_TOKEN='' SHELLKIT_MINISIGN_PUBKEY="${PUBKEY:-}" \
    SHELLKIT_MINISIGN_PUBKEY_FILE='' \
    bash "$__cli" update --prefix "$work/prefix" 2>"$work/err.txt") || rc=$?
  return 0
}

# --------------------------------------------------------------------------
# 用例 E：没配公钥 ⇒ 照旧只 sha256，minisign 一次都不许调（默认行为不变）
# --------------------------------------------------------------------------
unset PUBKEY
_run_update "$TEST_ROOT/shellkit"
assert_eq "0" "$rc" "update must succeed without a public key"
assert_contains "$(cat "$work/err.txt")" "already up to date" \
  "the update must reach the already-up-to-date verdict without a public key"
assert_eq "" "$(cat "$mlog" 2>/dev/null)" "minisign must not be called when no public key is configured"

# --------------------------------------------------------------------------
# 用例 F：配了公钥 + minisign 通过 ⇒ 正常升级，且两个资产都验过
# --------------------------------------------------------------------------
export PUBKEY=TESTKEY
export FAKE_MINISIGN_RC=0
_run_update "$TEST_ROOT/shellkit"
assert_eq "0" "$rc" "update must succeed when the signature verifies"
assert_contains "$(cat "$work/err.txt")" "already up to date" \
  "the update must reach the already-up-to-date verdict when the signature verifies"
assert_contains "$(cat "$mlog")" 'SHA256SUMS' "SHA256SUMS must be signature-verified"
assert_contains "$(cat "$mlog")" 'shellkit-9.9.9.tar.gz' "the tarball must be signature-verified"
assert_contains "$(cat "$mlog")" '-P TESTKEY' "the configured public key must be passed to minisign"

# --------------------------------------------------------------------------
# 用例 G：配了公钥 + minisign 不通过 ⇒ 退 5（校验失败），不许装下去
# --------------------------------------------------------------------------
export FAKE_MINISIGN_RC=1
: >"$mlog"
_run_update "$TEST_ROOT/shellkit"
assert_eq "5" "$rc" "a bad signature must be a verification failure (5)"
assert_eq "" "$out" "no version must be printed when the signature fails"

# --------------------------------------------------------------------------
# 用例 H：配了公钥但机器上没有 minisign ⇒ 退 3（前置条件），不许跳过验签
#
# ⚠️ 造「没有 minisign」只能靠 PATH 里没有它 —— 本机若装了 minisign（brew），
# 这条用例只能明说没跑（与 demo.sh 用例同一口径：不静默跳过）。
# --------------------------------------------------------------------------
export FAKE_MINISIGN_RC=0
if command -v minisign >/dev/null 2>&1; then
  printf 'NA: minisign is installed on this machine — the missing-minisign case is skipped\n'
else
  _run_update "$TEST_ROOT/shellkit" 0
  assert_eq "3" "$rc" "a configured key without minisign must be a precondition failure (3)"
  assert_eq "" "$out" "no version must be printed when minisign is missing"
fi

# --------------------------------------------------------------------------
# 用例 I：配了公钥 + SHA256SUMS.minisig 资产缺失 ⇒ 退 5（与 install.sh 同口径：
# 要验就必须验得过，缺签名资产是校验失败，不是网络失败）
# --------------------------------------------------------------------------
export FAKE_SUMS_SIG_MISSING=1
_run_update "$TEST_ROOT/shellkit"
assert_eq "5" "$rc" "a missing signature asset must be a verification failure (5)"
export FAKE_SUMS_SIG_MISSING=0

# --------------------------------------------------------------------------
# 变异自证：把「配了公钥就验签」的判断整个关掉 ⇒ 用例 G 必须变红
#
# 按函数边界做（stub_out_function），与覆盖率插桩无关：判断函数永远返回
# 「没配公钥」⇒ 验签块整段跳过 ⇒ 坏签名也照样成功。
# --------------------------------------------------------------------------
d=$(tmpdir)
cp -R "$TEST_ROOT/lib" "$d/" || _fail "cannot copy lib"
cp -f "$TEST_ROOT/shellkit" "$d/" || _fail "cannot copy the CLI"
cp -f "$TEST_ROOT/VERSION" "$d/" || _fail "cannot copy VERSION"
stub_out_function "$d/lib/core/net.sh" _sk_sig_pub_configured
export FAKE_MINISIGN_RC=1
: >"$mlog"
_run_update "$d/shellkit"
assert_eq "0" "$rc" "skipping the signature check must let a bad signature through (the defect)"

exit 0
