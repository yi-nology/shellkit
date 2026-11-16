#!/usr/bin/env bash
# 跨版本升级矩阵的 strict 判据（issue #126）。
#
# 要守的事：--strict 必须要求**声明的每个源版本都真跑通**。旧判据只有
# `ran -eq 0` —— 三个源版本里只要有一个下载到并跑通、另外两个跳过，CI 照样
# 绿（ran=1）。跳过（资产下载不到 / 老 CLI 不可执行 / 建不出工程）恰恰是
# 兼容性事实，不是环境噪声。
#
# 场景：stub gh 只提供 3 个声明版本中的 1 个（0.20.0），另外两个下载失败。
#   - --strict 必须红，并点名跳过的版本；
#   - 非 strict 仍绿（本地离网开发体验），但逐版本列出 passed/skipped(原因)；
#   - 三个都提供时 --strict 必须绿（判据不是「一律红」）；
#   - 自证：把 strict 判据改回旧的 `ran -eq 0`，同一场景必须变绿 —— 证明
#     本用例对坏实现是红的（当前实现若回退，上面的 assert_exit_code 1 会失败）。
#
# 全文纯 bash + 本地 stub，不联网、不依赖真 shellkit 构建。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

VERSION="3.0.0"
VERSIONS="0.20.0 0.23.0 0.24.1"

# _make_harness DIR —— 造一个最小「仓库根」：tools/upgrade_matrix.sh 副本 +
# VERSION + 假当前 CLI（upgrade / install-self / uninstall-self 三个动作）。
_make_harness() {
  local __d=$1
  mkdir -p "$__d/tools"
  cp "$TEST_ROOT/tools/upgrade_matrix.sh" "$__d/tools/upgrade_matrix.sh"
  printf '%s\n' "$VERSION" >"$__d/VERSION"
  cat >"$__d/shellkit" <<EOF
#!/usr/bin/env bash
set -u
cmd=\${1:-}
shift || true
prefix=""
proj=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --prefix) prefix=\${2:-}; shift 2 ;;
    --name|--cmd) shift 2 ;;
    --yes) shift ;;
    *) proj=\${1:-}; shift ;;
  esac
done
case "\$cmd" in
  upgrade)
    [ -n "\$proj" ] || exit 2
    mkdir -p "\$proj/vendor/shellkit"
    printf '%s\n' "$VERSION" >"\$proj/vendor/shellkit/VERSION"
    echo "already up to date"
    ;;
  install-self)
    [ -n "\$prefix" ] || exit 2
    mkdir -p "\$prefix/bin" "\$prefix/share/shellkit"
    cp "\$0" "\$prefix/bin/shellkit"
    chmod 755 "\$prefix/bin/shellkit"
    : >"\$prefix/share/shellkit/.shellkit-install-manifest"
    ;;
  uninstall-self)
    [ -n "\$prefix" ] || exit 2
    rm -f "\$prefix/bin/shellkit" "\$prefix/share/shellkit/.shellkit-install-manifest"
    ;;
  *) exit 2 ;;
esac
exit 0
EOF
  chmod 755 "$__d/shellkit"
  return 0
}

# _make_gh DIR MODE —— 造 gh 可执行 stub。MODE=one 只提供 0.20.0，MODE=all
# 提供全部三个版本。download 时现场生成 shellkit-<v>.tar.gz（内含可执行老 CLI）。
_make_gh() {
  local __d=$1 __mode=$2
  mkdir -p "$__d/bin"
  cat >"$__d/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -u
if [ "${1:-}" != release ] || [ "${2:-}" != download ]; then
  exit 1
fi
tag=${3:-}
shift 3 || exit 1
dir=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir) dir=${2:-}; shift 2 ;;
    --pattern|--repo) shift 2 ;;
    --clobber) shift ;;
    *) shift ;;
  esac
done
case "$tag" in
  v0.20.0) ;;
  *)
    [ "${GH_STUB_MODE:-one}" = "all" ] || exit 1
    ;;
esac
ver=${tag#v}
[ -n "$dir" ] || exit 1
mkdir -p "$dir"
stage="$dir/.stage-$$"
mkdir -p "$stage/shellkit-$ver"
cat >"$stage/shellkit-$ver/shellkit" <<'OLD'
#!/usr/bin/env bash
[ "${1:-}" = new ] || exit 1
mkdir -p "${2:-}"
exit 0
OLD
chmod 755 "$stage/shellkit-$ver/shellkit"
tar -C "$stage" -czf "$dir/shellkit-$ver.tar.gz" "shellkit-$ver" || exit 1
rm -rf "$stage"
exit 0
EOF
  chmod 755 "$__d/bin/gh"
  # MODE 通过环境变量传给 stub（不同用例复用同一个 bin 目录）。
  printf '%s' "$__mode" >"$__d/gh-mode"
  return 0
}

_run_matrix() {
  local __d=$1 __mode=$2
  shift 2
  env PATH="$__d/bin:$PATH" GH_STUB_MODE="$__mode" \
    bash "$__d/tools/upgrade_matrix.sh" --versions "$VERSIONS" --repo acme/shellkit "$@" 2>&1
}

# --- CASE: 一跑两跳 —— strict 必须红 ---
d=$(tmpdir)
_make_harness "$d"
_make_gh "$d" one
out=$(env PATH="$d/bin:$PATH" GH_STUB_MODE=one \
  bash "$d/tools/upgrade_matrix.sh" --versions "$VERSIONS" --repo acme/shellkit --strict 2>&1)
rc=$?
assert_eq "1" "$rc" "strict must fail when 2 of 3 declared sources were skipped"
assert_contains "$out" "strict mode:" "the failure must explain the strict verdict"
assert_contains "$out" "0.23.0: skipped" "the skipped version must be named"
assert_contains "$out" "0.24.1: skipped" "every skipped version must be named"
assert_contains "$out" "0.20.0: passed" "the version that ran must be listed as passed"

# --- CASE: 非 strict 仍绿，但逐版本列结局 ---
out=$(env PATH="$d/bin:$PATH" GH_STUB_MODE=one \
  bash "$d/tools/upgrade_matrix.sh" --versions "$VERSIONS" --repo acme/shellkit 2>&1)
rc=$?
assert_eq "0" "$rc" "without --strict, skips stay acceptable for offline local runs"
assert_contains "$out" "declared=3 ran=1 passed=1 skipped=2 fails=0" "the summary must count declared/ran/passed/skipped"
assert_contains "$out" "0.20.0: passed" "per-version passed line is required"
assert_contains "$out" "0.23.0: skipped (cannot download the release tarball)" \
  "per-version skip line must carry the reason"

# --- CASE: 三个都真跑通 —— strict 必须绿（判据不是一律红） ---
dall=$(tmpdir)
_make_harness "$dall"
_make_gh "$dall" all
out=$(env PATH="$dall/bin:$PATH" GH_STUB_MODE=all \
  bash "$dall/tools/upgrade_matrix.sh" --versions "$VERSIONS" --repo acme/shellkit --strict 2>&1)
rc=$?
assert_eq "0" "$rc" "strict must pass when every declared source actually runs"
assert_contains "$out" "declared=3 ran=3 passed=3 skipped=0 fails=0" "all pass counts must line up"

# --- CASE: 自证 —— 旧判据（ran>0 即绿）在同一场景下必须绿 ---
# 把 strict 段替换成旧实现，证明本用例确实钉住了「一跑两跳」这个缺口：
# 若当前实现回退成旧判据，上面的 assert_eq 1 会失败。
dold=$(tmpdir)
_make_harness "$dold"
_make_gh "$dold" one
python3 - "$dold/tools/upgrade_matrix.sh" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
start = text.index('if [ "$strict" = "1" ]; then')
end = text.index("exit 0", start)
old = '''if [ "$strict" = "1" ] && [ "$ran" -eq 0 ]; then
  die "strict mode: not a single upgrade source was actually tested (every version was skipped)" 1
fi
'''
open(path, "w", encoding="utf-8").write(text[:start] + old + text[end:])
PY
out=$(env PATH="$dold/bin:$PATH" GH_STUB_MODE=one \
  bash "$dold/tools/upgrade_matrix.sh" --versions "$VERSIONS" --repo acme/shellkit --strict 2>&1)
rc=$?
assert_eq "0" "$rc" "the old ran>0 criterion must go green in this scenario (test sensitivity proof)"

exit 0