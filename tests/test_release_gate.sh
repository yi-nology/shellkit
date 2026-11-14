#!/usr/bin/env bash
# release 质量准入（tools/release_gate.sh）的回归。
#
# 要守的是一条发布底线：**未经质量验证不发布**。tag 一推就发布的旧路
# （issue #42）必须被拦住：必需检查缺席、没结论、结论不是 success，
# gate 一律不放行 —— 查不了状态也按不放行处理（fail-closed）。
#
# gh 用桩替身：状态表是「检查名 TAB 结论」的文件，桩按名字查表回话。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

GATE="$TEST_ROOT/tools/release_gate.sh"
SHA="0123456789abcdef0123456789abcdef01234567"

# 覆盖率副本里没有 .git（tools/coverage.sh 不拷历史）：gate 反推 origin 会
# die 2，整片用例在副本里恒红。真树照旧走 git 检测（URL 解析分支仍被测到），
# 只有拿不到 git 仓库时才用环境变量兜底。
if ! git -C "$TEST_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  export GITHUB_REPOSITORY=yi-nology/shellkit
fi

# mk_gh STATE_FILE —— 造一个读状态表的 gh 桩
# 状态表每行：<检查名> TAB <结论>，结论形如 completed/success、
# queued/none、MISSING；表里没有的名字按 MISSING 回话。
# 特殊值 pending-then-success：第一次回答 queued/none，然后把表里的值
# 改成 completed/success —— 模拟「还在跑，下一轮就绿」。
# 特殊值 missing-then-success：第一次回答 MISSING，然后把表里的值
# 改成 completed/success —— 模拟「push 后 check-run 尚未注册，下一轮
# 才注册跑完」（issue #85：注册竞态不该被当成失败）。
mk_gh() {
  local state=$1 bin
  bin=$(mktemp -d "$TEST_TMP_ROOT/ghbin.XXXXXX") || _fail "mktemp failed"
  cat >"$bin/gh" <<EOF
#!/usr/bin/env bash
state="$state"
name=""
rest=""
for a in "\$@"; do
  case "\$a" in
    -f) expect=1 ;;
    check_name=*) name=\${a#check_name=} ;;
  esac
done
line=\$(awk -F'\t' -v n="\$name" '\$1 == n { print \$2; exit }' "\$state" 2>/dev/null)
case "\$line" in
  pending-then-success)
    printf 'queued/none'
    tmp=\$(mktemp)
    awk -F'\t' -v n="\$name" -v v="completed/success" 'BEGIN{OFS="\t"} \$1==n{\$2=v; found=1} {print} END{if(!found) print n, v}' "\$state" >"\$tmp" && mv "\$tmp" "\$state"
    ;;
  missing-then-success)
    printf 'MISSING'
    tmp=\$(mktemp)
    awk -F'\t' -v n="\$name" -v v="completed/success" 'BEGIN{OFS="\t"} \$1==n{\$2=v; found=1} {print} END{if(!found) print n, v}' "\$state" >"\$tmp" && mv "\$tmp" "\$state"
    ;;
  "") printf 'MISSING' ;;
  *) printf '%s' "\$line" ;;
esac
EOF
  chmod 755 "$bin/gh"
  printf '%s' "$bin"
}

# 三条必需检查的小清单：点名一个成功、一个失败、一个待定的足够了
GATE_ENV="SHELLKIT_GATE_CHECKS=alpha|beta|gamma"

# CASE: 全部必需检查都成功 ⇒ 放行
d=$(mktemp -d "$TEST_TMP_ROOT/gate.XXXXXX") || _fail "mktemp failed"
printf 'alpha\tcompleted/success\nbeta\tcompleted/success\ngamma\tcompleted/success\n' >"$d/state"
bin=$(mk_gh "$d/state")
out=$(env PATH="$bin:$PATH" "$GATE_ENV" bash "$GATE" "$SHA" --once 2>&1)
rc=$?
assert_eq "0" "$rc" "all required checks green must pass the gate"
assert_contains "$out" "verdict: PASSED" "the verdict must say passed"

# CASE: 「required checks: N」必须等于清单的实际条数（issue #70）
#
# 旧写法是 `printf '%s' "$CHECKS" | tr '|' '\n' | wc -l`：printf 不补尾换行，
# wc -l 数的是换行符个数 ⇒ 永远比实际条数少 1。三条清单报 2，
# 下一行 verdict 却说 3 —— 同一个清单两个数字，谁也说不清哪个对。
# 这里把 N 钉死：传几条就得报几条（1/2/3/5 都试一遍，多的少的都钉住）。
for __list in alpha 'alpha|beta' 'alpha|beta|gamma' 'alpha|beta|gamma|delta|epsilon'; do
  __want=$(printf '%s\n' "$__list" | awk -F'|' '{ print NF }')
  printf '%s\n' "$__list" | tr '|' '\n' | while IFS= read -r __n; do
    [ -n "$__n" ] || continue
    printf '%s\tcompleted/success\n' "$__n"
  done >"$d/state-list"
  __bin=$(mk_gh "$d/state-list")
  out=$(env PATH="$__bin:$PATH" "SHELLKIT_GATE_CHECKS=$__list" bash "$GATE" "$SHA" --once 2>&1)
  rc=$?
  assert_eq "0" "$rc" "a list of green checks must pass the gate"
  printf '%s\n' "$out" >"$d/gate.out"
  __got=""
  while IFS= read -r __line; do
    case "$__line" in
      *"required checks: "*) __got=${__line##*required checks: } ;;
    esac
  done <"$d/gate.out"
  assert_eq "$__want" "$__got" "the required-check count must equal the number of checks listed ($__list)"
done

# CASE: 一个必需检查失败 ⇒ 不放行，退出码 1，点名是谁
printf 'alpha\tcompleted/success\nbeta\tcompleted/failure\ngamma\tcompleted/success\n' >"$d/state"
out=$(env PATH="$bin:$PATH" "$GATE_ENV" bash "$GATE" "$SHA" --once 2>&1)
rc=$?
assert_eq "1" "$rc" "a failed required check must block the release"
assert_contains "$out" "NOT PASSED" "the verdict must say not passed"
assert_contains "$out" "beta" "the verdict must name the failing check"

# CASE: 一个必需检查还在跑 ⇒ 不放行（未完成也是未通过，退出码 3）
printf 'alpha\tcompleted/success\nbeta\tin_progress/none\ngamma\tcompleted/success\n' >"$d/state"
out=$(env PATH="$bin:$PATH" "$GATE_ENV" bash "$GATE" "$SHA" --once 2>&1)
rc=$?
assert_eq "3" "$rc" "a pending required check must block the release"
assert_contains "$out" "pending" "the verdict must say what is still pending"

# CASE: 一个必需检查缺席（这个 SHA 上 CI 还没跑到/没注册）⇒ 按「还没有
# 结论」处理，退出码 3。push / tag 后立刻跑门禁是常态，check-run 注册有
# 竞态（issue #85）：「还没注册」与「失败」是两回事，轮询窗口内先等。
printf 'alpha\tcompleted/success\ngamma\tcompleted/success\n' >"$d/state"
out=$(env PATH="$bin:$PATH" "$GATE_ENV" bash "$GATE" "$SHA" --once 2>&1)
rc=$?
assert_eq "3" "$rc" "a missing required check must be waited for, not failed on sight"
assert_contains "$out" "missing" "the verdict must say what is missing"
assert_contains "$out" "beta" "the verdict must name the missing check"

# CASE: 检查缺席但下一轮就注册跑绿 ⇒ 轮询能等到（issue #85 的核心场景）
printf 'alpha\tcompleted/success\nbeta\tmissing-then-success\ngamma\tcompleted/success\n' >"$d/state"
out=$(env PATH="$bin:$PATH" "$GATE_ENV" bash "$GATE" "$SHA" --interval 0 2>&1)
rc=$?
assert_eq "0" "$rc" "a check that registers late must eventually pass"
assert_contains "$out" "verdict: PASSED" "the verdict must say passed"

# CASE: 超时后仍缺席 ⇒ 这时才判失败，退出码 1，说明原因
printf 'alpha\tcompleted/success\ngamma\tcompleted/success\n' >"$d/state2"
bin2=$(mk_gh "$d/state2")
out=$(env PATH="$bin2:$PATH" "$GATE_ENV" bash "$GATE" "$SHA" --timeout 0 --interval 0 2>&1)
rc=$?
assert_eq "1" "$rc" "a check that never registers must fail the gate after the timeout"
assert_contains "$out" "NOT PASSED" "the verdict must say not passed"
assert_contains "$out" "never registered" "the verdict must explain why"
assert_contains "$out" "beta" "the verdict must name the missing check"

# CASE: 超时后仍在跑（非缺席）⇒ 维持「没结论」语义，退出码 3
printf 'alpha\tcompleted/success\nbeta\tin_progress/none\ngamma\tcompleted/success\n' >"$d/state3"
bin3=$(mk_gh "$d/state3")
out=$(env PATH="$bin3:$PATH" "$GATE_ENV" bash "$GATE" "$SHA" --timeout 0 --interval 0 2>&1)
rc=$?
assert_eq "3" "$rc" "a timeout with a check still running has no verdict"
assert_contains "$out" "timed out" "the verdict must say it timed out"

# CASE: 还在跑但下一轮就绿 ⇒ 轮询能等到结论（不是 --once 的路径）
printf 'alpha\tcompleted/success\nbeta\tpending-then-success\ngamma\tcompleted/success\n' >"$d/state"
out=$(env PATH="$bin:$PATH" "$GATE_ENV" bash "$GATE" "$SHA" --interval 0 2>&1)
rc=$?
assert_eq "0" "$rc" "a check that turns green must eventually pass"
assert_contains "$out" "verdict: PASSED" "the verdict must say passed"

# CASE: gh 都没有 ⇒ 查不了状态就是不放行（fail-closed）
# PATH 只留一个空目录：bash 本身用绝对路径起，里面的 gh 就真的找不到了。
d=$(mktemp -d "$TEST_TMP_ROOT/gate.XXXXXX") || _fail "mktemp failed"
mkdir -p "$d/emptybin"
out=$(env PATH="$d/emptybin" GITHUB_REPOSITORY=yi-nology/shellkit "$GATE_ENV" /bin/bash "$GATE" "$SHA" --once 2>&1)
rc=$?
assert_eq "3" "$rc" "no gh means no verification means no release"

# CASE: 用法错必须退 2（缺 SHA）
rc=0
env PATH="$bin:$PATH" "$GATE_ENV" bash "$GATE" >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "a missing SHA must be a usage error"

# CASE: 没有 GITHUB_REPOSITORY 时从 origin 反推 —— 三条解析分支都要被走到：
# git@ 前缀、https 前缀、非 GitHub 远端（必须 die 2）。桩 git 只回答
# `config --get remote.origin.url`。覆盖率副本里没有 .git，
# 走的正是这条环境兜底路径之外的分支（真树的 git 检测在文件头部已说明）。
printf 'alpha\tcompleted/success\n' >"$d/state"
for __url in git@github.com:y/x.git https://github.com/y/x.git https://gitlab.com/y/x.git; do
  __bin=$(mk_gh "$d/state")
  printf '#!/bin/sh\nprintf '"'"'%%s\n'"'"' '"'"'%s'"'"'\n' "$__url" >"$__bin/git"
  chmod 755 "$__bin/git"
  rc=0
  out=$(env -u GITHUB_REPOSITORY PATH="$__bin:$PATH" SHELLKIT_GATE_CHECKS=alpha \
    bash "$GATE" "$SHA" --once 2>&1) || rc=$?
  case "$__url" in
    https://gitlab.com/*)
      assert_eq "2" "$rc" "a non-GitHub origin must be rejected ($__url)"
      assert_contains "$out" "origin is not a GitHub remote" "the rejection must name the cause"
      ;;
    *)
      assert_eq "0" "$rc" "a GitHub origin must be accepted ($__url)"
      assert_contains "$out" "repository: y/x" "the origin must be parsed into owner/repo ($__url)"
      ;;
  esac
done

exit 0
