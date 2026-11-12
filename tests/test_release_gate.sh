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

# mk_gh STATE_FILE —— 造一个读状态表的 gh 桩
# 状态表每行：<检查名> TAB <结论>，结论形如 completed/success、
# queued/none、MISSING；表里没有的名字按 MISSING 回话。
# 特殊值 pending-then-success：第一次回答 queued/none，然后把表里的值
# 改成 completed/success —— 模拟「还在跑，下一轮就绿」。
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

# CASE: 一个必需检查缺席（这个 SHA 上 CI 根本没跑）⇒ 不放行，退出码 1
printf 'alpha\tcompleted/success\ngamma\tcompleted/success\n' >"$d/state"
out=$(env PATH="$bin:$PATH" "$GATE_ENV" bash "$GATE" "$SHA" --once 2>&1)
rc=$?
assert_eq "1" "$rc" "a missing required check must block the release"
assert_contains "$out" "beta" "the verdict must name the missing check"

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

exit 0
