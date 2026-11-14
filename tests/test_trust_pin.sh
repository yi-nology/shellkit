#!/usr/bin/env bash
# TRUST.md 公钥钉入一致性门禁（路线图 v0.22.0）。
#
# 判据：
#   1. 钉入值与发布公钥一致 → 0（.pub 两行格式与单行 base64 都要认）
#   2. 漂移 → 1，且错误信息指名两端
#   3. 文档里没有钉入值 → 3（正式启用后「没钉」就是缺陷）
#   4. 公钥文件缺失 → 3；未知用法 → 2
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

work=$(tmpdir)
gate="$TEST_ROOT/tools/check_trust_pin.sh"

# 两个 56 位的「像 base64 的」测试值（真实公钥就是 56 位）
pin_a=$(printf '%056d' 0 | tr 0 A)
pin_b=$(printf '%056d' 0 | tr 0 B)

# _trust FILE PIN —— 生成带「### 当前公钥」节的文档；PIN 为空表示尚未钉入
_trust() {
  if [ -n "$2" ]; then
    printf '## 前言\n\n### 当前公钥\n\n```text\n%s\n```\n\n## 后续\n' "$2" >"$1"
  else
    printf '## 前言\n\n### 当前公钥\n\n```text\n状态：尚未配置\n```\n\n## 后续\n' >"$1"
  fi
}

# ---------- CASE: 一致（.pub 两行格式）----------
printf 'untrusted comment: x\n%s\n' "$pin_a" >"$work/good.pub"
_trust "$work/trust-ok.md" "$pin_a"
rc=0
out=$("$gate" --pub "$work/good.pub" --trust "$work/trust-ok.md" 2>&1) || rc=$?
assert_eq "0" "$rc" "a matching pin must pass"
assert_contains "$out" "check_trust_pin: ok" "the pass must be announced"

# ---------- CASE: 一致（单行 base64 形态）----------
printf '%s\n' "$pin_a" >"$work/one-line.pub"
rc=0
out=$("$gate" --pub "$work/one-line.pub" --trust "$work/trust-ok.md" 2>&1) || rc=$?
assert_eq "0" "$rc" "a bare base64 public key must be accepted"

# ---------- CASE: 漂移 → 1 且指名两端 ----------
printf 'untrusted comment: x\n%s\n' "$pin_b" >"$work/drift.pub"
rc=0
out=$("$gate" --pub "$work/drift.pub" --trust "$work/trust-ok.md" 2>&1) || rc=$?
assert_eq "1" "$rc" "a drifted pin must fail"
assert_contains "$out" "does not match" "the failure must name the problem"
assert_contains "$out" "AAAA" "the failure must show the pinned side"
assert_contains "$out" "BBBB" "the failure must show the signing side"

# ---------- CASE: 文档没钉入 → 3 ----------
_trust "$work/trust-empty.md" ""
rc=0
out=$("$gate" --pub "$work/good.pub" --trust "$work/trust-empty.md" 2>&1) || rc=$?
assert_eq "3" "$rc" "a missing pin must be a precondition failure"
assert_contains "$out" "no pinned public key" "the missing pin must be named"

# ---------- CASE: 公钥文件缺失 → 3 ----------
rc=0
out=$("$gate" --pub "$work/absent.pub" --trust "$work/trust-ok.md" 2>&1) || rc=$?
assert_eq "3" "$rc" "a missing public key file must be a precondition failure"

# ---------- CASE: 未知用法 → 2 ----------
rc=0
"$gate" --bogus >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "an unknown option must be a usage error"

printf 'test_trust_pin: all cases passed\n'
