#!/usr/bin/env bash
# release 质量准入：被 runner 取消的必需检查，自动重跑一次（而不是人工盯着重跑）。
#
# 背景：macOS runner 会因配额/抢占把 job 直接取消（零步骤、conclusion=cancelled）。
# 那不是代码失败，但 release_gate.sh 原来把它归到「completed/* ⇒ 失败」——
# 一次 runner 侧的取消就能卡住整条发布，只能靠人看网页、手动 rerun、再推一次。
# 现在的口径：**每个检查最多自动重跑一次**；重跑后还是取消，按失败处理（fail-closed）。
#
# gh 用桩替身：
#   - 状态表每行 <检查名> TAB <结论> TAB <details_url> TAB <重跑后的结论>
#   - 收到 `gh run rerun <id>` 时把 run id 记到日志，并把该行结论换成第 4 列
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

GATE="$TEST_ROOT/tools/release_gate.sh"
SHA="0123456789abcdef0123456789abcdef01234567"
CHECKS="SHELLKIT_GATE_CHECKS=alpha|beta"

# 覆盖率副本里没有 .git：gate 反推 origin 会 die 2（与 test_release_gate.sh 同口径）
if ! git -C "$TEST_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  export GITHUB_REPOSITORY=yi-nology/shellkit
fi

# mk_gh STATE_FILE LOG_FILE —— 造一个 gh 桩；状态表与日志的路径由 sed 注入。
# 用**带引号**的 heredoc：桩里全部是字面量，运行时才展开，不会被这里提前吃掉。
mk_gh() {
  local __state=$1 __log=$2 __bin
  __bin=$(mktemp -d "$TEST_TMP_ROOT/ghbin.XXXXXX") || _fail "mktemp failed"
  sed -e "s|@STATE@|$__state|" -e "s|@LOG@|$__log|" >"$__bin/gh" <<'STUB'
#!/usr/bin/env bash
state='@STATE@'
log='@LOG@'
if [ "${1:-}" = "run" ] && [ "${2:-}" = "rerun" ]; then
  printf '%s\n' "${3:-}" >>"$log"
  tmp=$(mktemp)
  awk -F'\t' 'BEGIN{OFS="\t"} { $2 = $4; print }' "$state" >"$tmp" && mv "$tmp" "$state"
  exit 0
fi
name=""
for a in "$@"; do
  case "$a" in
    check_name=*) name=${a#check_name=} ;;
  esac
done
awk -F'\t' -v n="$name" '$1 == n { printf "%s\t%s", $2, $3; found = 1; exit } END { if (!found) printf "MISSING" }' "$state" 2>/dev/null
STUB
  chmod 755 "$__bin/gh"
  printf '%s' "$__bin"
}

d=$(mktemp -d "$TEST_TMP_ROOT/gate-cancel.XXXXXX") || _fail "mktemp failed"

# CASE: 一个检查被取消 ⇒ 自动重跑一次，重跑后成功 ⇒ 放行
printf 'alpha\tcompleted/success\t\tcompleted/success\nbeta\tcompleted/cancelled\thttps://github.com/o/r/actions/runs/4242/job/9\tcompleted/success\n' >"$d/state1"
: >"$d/log1"
bin=$(mk_gh "$d/state1" "$d/log1")
out=$(env PATH="$bin:$PATH" "$CHECKS" bash "$GATE" "$SHA" --timeout 10 --interval 1 2>&1)
rc=$?
assert_eq "0" "$rc" "a cancelled check that passes after one re-run must pass the gate"
assert_contains "$out" "[RETRY] beta" "the gate must say it requested a re-run"
assert_contains "$out" "verdict: PASSED" "the rerun must let the gate pass"
assert_eq "4242" "$(cat "$d/log1")" "the gate must rerun exactly the run named in details_url"

# CASE: 重跑后又被取消 ⇒ 只重跑一次，然后判失败（fail-closed）
printf 'alpha\tcompleted/success\t\tcompleted/success\nbeta\tcompleted/cancelled\thttps://github.com/o/r/actions/runs/4242/job/9\tcompleted/cancelled\n' >"$d/state2"
: >"$d/log2"
bin2=$(mk_gh "$d/state2" "$d/log2")
out=$(env PATH="$bin2:$PATH" "$CHECKS" bash "$GATE" "$SHA" --timeout 10 --interval 1 2>&1)
rc=$?
assert_eq "1" "$rc" "a check cancelled again after the one re-run must block the release"
assert_contains "$out" "NOT PASSED" "the verdict must say not passed"
assert_contains "$out" "one re-run is spent" "the verdict must explain that the retry was already used"
assert_eq "4242" "$(cat "$d/log2")" "the gate must not rerun the same check twice"

# CASE: --no-rerun ⇒ 不请求重跑，被取消即失败（人工/测试通道）
printf 'alpha\tcompleted/success\t\tcompleted/success\nbeta\tcompleted/cancelled\thttps://github.com/o/r/actions/runs/4242/job/9\tcompleted/success\n' >"$d/state3"
: >"$d/log3"
bin3=$(mk_gh "$d/state3" "$d/log3")
out=$(env PATH="$bin3:$PATH" "$CHECKS" bash "$GATE" "$SHA" --once --no-rerun 2>&1)
rc=$?
assert_eq "1" "$rc" "with --no-rerun a cancelled check must fail the gate"
assert_eq "" "$(cat "$d/log3")" "--no-rerun must not request any re-run"
assert_contains "$out" "cancelled by the runner" "the verdict must say the check was cancelled"

# CASE: 取消但没有 details_url ⇒ 无从重跑，判失败而不是崩
printf 'alpha\tcompleted/success\t\tcompleted/success\nbeta\tcompleted/cancelled\t\tcompleted/success\n' >"$d/state4"
: >"$d/log4"
bin4=$(mk_gh "$d/state4" "$d/log4")
out=$(env PATH="$bin4:$PATH" "$CHECKS" bash "$GATE" "$SHA" --once 2>&1)
rc=$?
assert_eq "1" "$rc" "a cancelled check without a run URL must fail closed"
assert_eq "" "$(cat "$d/log4")" "no run id means no re-run request"
assert_contains "$out" "cancelled by the runner" "the verdict must name the cause"

# CASE: 正常的成功路径不受影响（重跑逻辑不能把绿的说成红的）
printf 'alpha\tcompleted/success\t\tcompleted/success\nbeta\tcompleted/success\t\tcompleted/success\n' >"$d/state5"
: >"$d/log5"
bin5=$(mk_gh "$d/state5" "$d/log5")
out=$(env PATH="$bin5:$PATH" "$CHECKS" bash "$GATE" "$SHA" --once 2>&1)
rc=$?
assert_eq "0" "$rc" "green checks must still pass"
assert_eq "" "$(cat "$d/log5")" "nothing to rerun on a green run"

# --- 结构判据：自动重跑要 Actions 的写权限 ---
# release.yml 的 GITHUB_TOKEN 默认只有 contents: write；gh run rerun 需要
# actions: write，缺了它重跑请求会被拒 —— 自动重跑形同虚设（还会 fail-closed）。
WF="$TEST_ROOT/.github/workflows/release.yml"
if [ -f "$WF" ]; then
  _perms() {
    awk '/^permissions:/ { on = 1; next } on && /^[^ ]/ { on = 0 } on { print }' "$1"
  }
  _missing_perm() {
    case "$(_perms "$1")" in
      *"actions: write"*) return 0 ;;
    esac
    printf 'missing actions: write\n'
  }
  assert_eq "" "$(_missing_perm "$WF")" \
    "release.yml must grant actions: write so a cancelled check can be re-run"

  # 自证：把那行删掉，判据必须看得见
  d2=$(mktemp -d "$TEST_TMP_ROOT/gate-cancel.XXXXXX") || _fail "mktemp failed"
  awk '!/^  actions: write$/' "$WF" >"$d2/release.yml"
  assert_contains "$(_missing_perm "$d2/release.yml")" "missing actions: write" \
    "dropping the permission must break the structural check"
fi

exit 0
