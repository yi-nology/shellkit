#!/usr/bin/env bash
# 发布后自检（tools/release_selfcheck.sh）与它在 release.yml 里的接线。
#
# 要守的事：**可选 job 失败不许静默**。deb/rpm 由 release.yml 的 packages job
# 打出来，那个 job 带 continue-on-error —— v0.26.0 / v0.26.1 两版就是这样
# 静默地少了系统包（run 全绿、网页上只是没有 .deb/.rpm）。所以：
#   1. 自检脚本必须点名缺了哪个资产（而不是只说「不完整」）；
#   2. release.yml 必须有一个**不可选**的 job 调它，且那个 job 等 packages 跑完。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

SELF="$TEST_ROOT/tools/release_selfcheck.sh"
VER=$(tr -d '[:space:]' <"$TEST_ROOT/VERSION")
TAG="v$VER"

mk_gh() {
  local __file=$1 __bin
  __bin=$(mktemp -d "$TEST_TMP_ROOT/scbin.XXXXXX") || _fail "mktemp failed"
  cat >"$__bin/gh" <<EOF
#!/usr/bin/env bash
cat "$__file"
EOF
  chmod 755 "$__bin/gh"
  printf '%s' "$__bin"
}

# 完整资产清单：主资产 + 签名 + 系统包
complete="$TEST_TMP_ROOT/sc-complete.txt"
{
  printf 'PUBLISHED\n'
  printf 'shellkit-%s.tar.gz\n' "$VER"
  printf 'shellkit-%s.tar.gz.minisig\n' "$VER"
  printf 'shellkit-skill-%s.tar.gz\n' "$VER"
  printf 'shellkit-skill-%s.tar.gz.minisig\n' "$VER"
  printf 'install.sh\ninstall.sh.minisig\n'
  printf 'repair.sh\nrepair.sh.minisig\n'
  printf 'demo.sh\ndemo.sh.minisig\n'
  printf 'SHA256SUMS\nSHA256SUMS.minisig\n'
  printf 'shellkit-%s.deb\nshellkit-%s.deb.minisig\n' "$VER" "$VER"
  printf 'shellkit-%s.rpm\nshellkit-%s.rpm.minisig\n' "$VER" "$VER"
} >"$complete"

bin=$(mk_gh "$complete")

# CASE: 资产齐全 ⇒ 通过
out=$(env PATH="$bin:$PATH" bash "$SELF" "$TAG" --require-packages 2>&1)
rc=$?
assert_eq "0" "$rc" "a complete release must pass the self-check"

# CASE: 缺 deb ⇒ 点名 deb，退出码 1
partial="$TEST_TMP_ROOT/sc-partial.txt"
awk -v n="shellkit-$VER.deb" '$0 != n' "$complete" >"$partial"
binp=$(mk_gh "$partial")
out=$(env PATH="$binp:$PATH" bash "$SELF" "$TAG" --require-packages 2>&1)
rc=$?
assert_eq "1" "$rc" "a release without the deb must fail the self-check"
assert_contains "$out" "shellkit-$VER.deb" "the failure must name the missing asset"
assert_not_contains "$out" "shellkit-$VER.rpm" "a present asset must not be reported missing"

# CASE: 不要求系统包时，缺 deb 也通过（历史版本没有包，不能反过来说它坏）
out=$(env PATH="$binp:$PATH" bash "$SELF" "$TAG" 2>&1)
rc=$?
assert_eq "0" "$rc" "without --require-packages the packages are optional"

# CASE: 少了签名 ⇒ 红（正式发布必须签名，缺一份就是可静默替换的口子）
nosig="$TEST_TMP_ROOT/sc-nosig.txt"
awk -v n="shellkit-$VER.tar.gz.minisig" '$0 != n' "$complete" >"$nosig"
bins=$(mk_gh "$nosig")
out=$(env PATH="$bins:$PATH" bash "$SELF" "$TAG" --require-packages 2>&1)
rc=$?
assert_eq "1" "$rc" "an unsigned asset must fail the self-check"
assert_contains "$out" "shellkit-$VER.tar.gz.minisig" "the failure must name the missing signature"

# CASE: 还是 draft ⇒ 红（对外不可见的不算发布完成）
draft="$TEST_TMP_ROOT/sc-draft.txt"
awk 'NR == 1 { print "DRAFT"; next } { print }' "$complete" >"$draft"
bind=$(mk_gh "$draft")
out=$(env PATH="$bind:$PATH" bash "$SELF" "$TAG" --require-packages 2>&1)
rc=$?
assert_eq "1" "$rc" "a draft release must fail the self-check"
assert_contains "$out" "still a draft" "the failure must explain that it is a draft"

# CASE: tag 与 VERSION 不一致 ⇒ 红（防止查错版本）
out=$(env PATH="$bin:$PATH" bash "$SELF" "v0.0.1" --require-packages 2>&1)
rc=$?
assert_eq "1" "$rc" "a tag that does not match VERSION must fail"

# CASE: 没有 gh ⇒ 前置条件不满足（3），不是「通过」
d=$(mktemp -d "$TEST_TMP_ROOT/sc.XXXXXX") || _fail "mktemp failed"
mkdir -p "$d/emptybin"
rc=0
env PATH="$d/emptybin" /bin/bash "$SELF" "$TAG" >/dev/null 2>&1 || rc=$?
assert_eq "3" "$rc" "no gh means the self-check cannot run"

# CASE: 取不回 Release ⇒ 3（不把网络失败说成「资产齐全」）
failing="$TEST_TMP_ROOT/sc-failbin"
mkdir -p "$failing"
cat >"$failing/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod 755 "$failing/gh"
rc=0
env PATH="$failing:$PATH" bash "$SELF" "$TAG" >/dev/null 2>&1 || rc=$?
assert_eq "3" "$rc" "an unreadable release must be a precondition failure"

# CASE: 用法错 ⇒ 2（缺 tag）
rc=0
env PATH="$bin:$PATH" bash "$SELF" >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "a missing tag must be a usage error"

# --- 结构判据：release.yml 必须有一个不可选的自检 job，且等 packages 跑完 ---
WF="$TEST_ROOT/.github/workflows/release.yml"
if [ ! -f "$WF" ]; then
  printf 'NA: .github/workflows/release.yml is not in this tree — the self-check wiring was not verified\n'
  exit 0
fi

# _job_block JOB_ID [FILE] —— 打印该 job 的整段（从 job 头到下一个 job 头之前）
_job_block() {
  awk -v want="$1" '
    /^jobs:/ { injobs = 1; next }
    injobs && /^  [A-Za-z0-9_-]+:/ {
      id = $0
      sub(/^  /, "", id)
      sub(/:.*/, "", id)
      on = (id == want) ? 1 : 0
      if (on) print
      next
    }
    injobs && /^[^ ]/ { injobs = 0; on = 0 }
    injobs && on { print }
  ' "${2:-$WF}"
}

self_block=$(_job_block self-check)
assert_contains "$self_block" "release_selfcheck.sh" "release.yml must run the self-check"
assert_contains "$self_block" "--require-packages" "the self-check must require the deb/rpm assets"
assert_not_contains "$self_block" "continue-on-error" "the self-check itself must not be optional"
assert_contains "$self_block" "needs:" "the self-check must declare its dependencies"
assert_contains "$self_block" "packages" "the self-check must wait for the optional packages job"

# 自证：把自检 job 改成可选，上面那条必须红
d2=$(mktemp -d "$TEST_TMP_ROOT/sc.XXXXXX") || _fail "mktemp failed"
awk '
  /^  self-check:/ { on = 1 }
  on && /^    name:/ { print; print "    continue-on-error: true"; next }
  { print }
' "$WF" >"$d2/release.yml"
tampered=$(_job_block self-check "$d2/release.yml")
assert_contains "$tampered" "continue-on-error: true" "the tamper must be visible to the structural check"

exit 0
