#!/usr/bin/env bash
# 引导脚本查「最新版本」不许只依赖未认证 API 配额。
#
# 背景（2026-11-21 实测）：GitHub 未认证 API 的配额是 60 次/小时**每个 IP** ——
# 共享出口（公司 NAT / 云主机 / CI runner）很容易把它用光 ⇒ HTTP 403。
# 对 install.sh / demo.sh 来说这不是「升级用不了」，而是**新用户连装都装不上**。
#
# ⇒ 两道取法：① release API（带 GH_TOKEN / GITHUB_TOKEN 就是认证请求，5000 次/小时）；
#    ② /releases/latest 的**重定向**（**不吃 API 配额**）。
#
# 全程离线：假 curl 放在 **PATH** 前面 —— install.sh / demo.sh 是独立进程，
# shell 函数顶不掉它们（测试助手的 stub 只对同进程有效）。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

work=$(tmpdir)
prefix=$work/prefix
mkdir -p "$prefix" "$work/bin"
log=$work/curl.log

# 假 curl：-I ⇒ 打响应头（查重定向）；否则 ⇒ 写响应体，退出码由 FAKE_API_EXIT 决定
# （真 curl 的 -f 遇到 403 会退 22，这里照着那个形态来）。
cat >"$work/bin/curl" <<'CURL'
#!/usr/bin/env bash
prev=""
ofile=""
head=0
for a in "$@"; do
  case "$prev" in
    -o) ofile=$a ;;
  esac
  case "$a" in
    -o) prev=$a ;;
    # 真 curl 传的是**一个**参数 -sI（不是 -I）⇒ 按「含大写 I 的短选项」判
    -*I*) prev=""; head=1 ;;
    *) prev="" ;;
  esac
done
printf '%s\n' "$*" >>"$FAKE_CURL_LOG"
if [ "$head" = "1" ]; then
  printf "%s" "$FAKE_REDIRECT_HEADERS"
  # 重定向这一问本身也可以失败（断网 / 被墙）⇒ 那条臂也要有判据
  exit "${FAKE_HEAD_EXIT:-0}"
fi
if [ -n "$ofile" ]; then printf "%s" "$FAKE_API_BODY" >"$ofile"; fi
exit "$FAKE_API_EXIT"
CURL
chmod +x "$work/bin/curl"

# API 的正常回答 / 重定向的回答
export FAKE_API_BODY='{"tag_name":"v9.9.9"}'
export FAKE_API_EXIT=0
export FAKE_REDIRECT_HEADERS='HTTP/1.1 302 Found
location: https://github.com/yi-nology/shellkit/releases/tag/v8.8.8
'

# _run_install SCRIPT —— 跑 install.sh --check；结果在 out / rc，日志在 $log
out=""
rc=0
_run_install() {
  local __script=$1
  : >"$log"
  out=""
  rc=0
  out=$(PATH="$work/bin:$PATH" FAKE_CURL_LOG="$log" \
    FAKE_API_BODY="$FAKE_API_BODY" FAKE_API_EXIT="$FAKE_API_EXIT" \
    FAKE_REDIRECT_HEADERS="$FAKE_REDIRECT_HEADERS" \
    bash "$__script" --check --prefix "$prefix" 2>"$work/err.txt") || rc=$?
  return 0
}

# --------------------------------------------------------------------------
# 用例 1：API 有答案 ⇒ 用 API 的，且不去碰重定向
# --------------------------------------------------------------------------
_run_install "$TEST_ROOT/install.sh"
assert_eq "9.9.9" "$out" "install.sh --check must report the latest version"
assert_eq "0" "$rc" "install.sh --check must succeed when the API answers"
assert_contains "$(cat "$log")" "api.github.com/repos/yi-nology/shellkit/releases/latest" \
  "the API must be asked for the version"
assert_not_contains "$(cat "$log")" "https://github.com/yi-nology/shellkit/releases/latest" \
  "the redirect must not be used when the API answers"

# --------------------------------------------------------------------------
# 用例 2：API 被限流（403 ⇒ curl -f 退 22）⇒ 必须靠重定向兜底
# --------------------------------------------------------------------------
export FAKE_API_BODY='{"message":"API rate limit exceeded"}'
export FAKE_API_EXIT=22
_run_install "$TEST_ROOT/install.sh"
assert_eq "8.8.8" "$out" "the redirect must be the fallback when the API is rate limited"
assert_eq "0" "$rc" "the fallback must make install.sh --check succeed"
assert_contains "$(cat "$log")" "https://github.com/yi-nology/shellkit/releases/latest" \
  "the redirect must be asked when the API is rate limited"

# --------------------------------------------------------------------------
# 用例 3：两条路都不通 ⇒ 非 0，且不许硬凑一个版本号出来
#
# ★ 退出码也要断，而且是**断具体的那个码**：API 那一问**失败**（403 ⇒ curl -f
#   退 22）且重定向也没给出版本号 ⇒ 这是「网络/接口层失败」⇒ 4（SK_NET），
#   不是 5（SK_VERIFY）。仓库的退出码约定是「4 = 网络失败，重试可能有用；
#   5 = 校验失败，重试同一个地址永远不会成功」（docs/API-FREEZE.md；
#   install.sh 头部也写着「4 网络 / 5 校验」）。
#   两类失败被抹平成一个 ⇒ 调用方的重试与告警都跟着走错 —— 而这恰恰是
#   「给一条主路径加一条兜底路径」时最容易顺手弄丢的东西（实测 2026-11-21：
#   加了兜底之后网络失败被报成 5，主路径的 4 整个丢了）。
# --------------------------------------------------------------------------
export FAKE_REDIRECT_HEADERS='HTTP/1.1 404 Not Found
'
export FAKE_HEAD_EXIT=0
_run_install "$TEST_ROOT/install.sh"
assert_ne "0" "$rc" "no version at all must not look like success"
assert_eq "" "$out" "no version must be printed"
assert_eq "4" "$rc" "a failing API request must report a network failure (4), not a verification failure (5)"

# --------------------------------------------------------------------------
# 用例 3b：重定向这一问**本身**失败（断网 / 被墙）⇒ 同样不许硬凑版本号
# --------------------------------------------------------------------------
export FAKE_HEAD_EXIT=22
_run_install "$TEST_ROOT/install.sh"
assert_ne "0" "$rc" "a failing redirect request must not look like success"
assert_eq "" "$out" "no version must be printed"
assert_eq "4" "$rc" "two failing requests must still report a network failure (4)"
export FAKE_HEAD_EXIT=0

# --------------------------------------------------------------------------
# 用例 3c：API **答了**（200）但内容里没有版本号 ⇒ 这是「校验失败」，退 5
#
# 与用例 3 的区别只有一处：API 那一步是成功的（拿到了响应体），只是响应体里
# 没有 tag_name（落地页 HTML、被限流的 JSON、字段改了名……）。
# ⇒ 服务器答了 ⇒ 不是网络问题 ⇒ 5；两类必须能分开，否则「地址给不出版本」
#   与「断网」在调用方眼里是一回事。
# --------------------------------------------------------------------------
export FAKE_API_BODY='{"message":"Not Found"}'
export FAKE_API_EXIT=0
export FAKE_REDIRECT_HEADERS='HTTP/1.1 404 Not Found
'
export FAKE_HEAD_EXIT=0
_run_install "$TEST_ROOT/install.sh"
assert_ne "0" "$rc" "an API without a version must not look like success"
assert_eq "" "$out" "no version must be printed"
assert_eq "5" "$rc" "an API that answers without a version must report a verification failure (5)"

# --------------------------------------------------------------------------
# 用例 4：demo.sh 同样要能走重定向（查不到版本就没法生成演示工程）
#
# ⚠️ 覆盖率跑的是**副本树**，而副本清单（tools/coverage.sh）只带 lib tests tools
# templates locale po docs examples skills .github 这些目录 + shellkit install.sh
# repair.sh 等散件 —— **demo.sh 不在里面** ⇒ 副本里这条用例找不到脚本。
# ⇒ 没有就明说「没验」，而不是让一条找不到文件的断言把整轮覆盖率带红。
# --------------------------------------------------------------------------
export FAKE_REDIRECT_HEADERS='HTTP/1.1 302 Found
location: https://github.com/yi-nology/shellkit/releases/tag/v8.8.8
'
if [ -f "$TEST_ROOT/demo.sh" ]; then
  : >"$log"
  rc=0
  PATH="$work/bin:$PATH" FAKE_CURL_LOG="$log" FAKE_API_BODY="$FAKE_API_BODY" \
    FAKE_API_EXIT="$FAKE_API_EXIT" FAKE_REDIRECT_HEADERS="$FAKE_REDIRECT_HEADERS" \
    bash "$TEST_ROOT/demo.sh" >"$work/demo.out" 2>"$work/demo.err" || rc=$?
  assert_contains "$(cat "$log")" "https://github.com/yi-nology/shellkit/releases/latest" \
    "demo.sh must fall back to the redirect as well"
  # demo.sh 的退出码约定与 install.sh 同一套（脚本头部写着「4 网络 / 5 校验」）：
  # 两条路都问不到 ⇒ 4（网络失败），不是 5。
  export FAKE_API_BODY='{"message":"API rate limit exceeded"}'
  export FAKE_API_EXIT=22
  export FAKE_REDIRECT_HEADERS='HTTP/1.1 404 Not Found
'
  rc=0
  PATH="$work/bin:$PATH" FAKE_CURL_LOG="$log" FAKE_API_BODY="$FAKE_API_BODY" \
    FAKE_API_EXIT="$FAKE_API_EXIT" FAKE_REDIRECT_HEADERS="$FAKE_REDIRECT_HEADERS" \
    bash "$TEST_ROOT/demo.sh" >"$work/demo.out" 2>"$work/demo.err" || rc=$?
  assert_eq "4" "$rc" "demo.sh must report a network failure (4), not a verification failure (5)"
else
  printf 'NA: demo.sh is not in this tree (the coverage copy does not carry it) — the demo.sh case is skipped\n'
fi

# --------------------------------------------------------------------------
# 用例 5：有 token ⇒ 请求带 Authorization 头（认证请求配额 5000 次/小时）
#
# 这条不是可有可无：带不带 token 决定 API 配额是 60 还是 5000 次/小时，
# 而「带 token 的那条路」此前一条判据都没有 —— 坏了没人知道。
# --------------------------------------------------------------------------
export FAKE_API_BODY='{"tag_name":"v9.9.9"}'
export FAKE_API_EXIT=0
export FAKE_HEAD_EXIT=0
export FAKE_REDIRECT_HEADERS='HTTP/1.1 302 Found
location: https://github.com/yi-nology/shellkit/releases/tag/v8.8.8
'
: >"$log"
rc=0
out=$(PATH="$work/bin:$PATH" FAKE_CURL_LOG="$log" FAKE_API_BODY="$FAKE_API_BODY" \
  FAKE_API_EXIT="$FAKE_API_EXIT" FAKE_REDIRECT_HEADERS="$FAKE_REDIRECT_HEADERS" \
  GH_TOKEN=secret-token \
  bash "$TEST_ROOT/install.sh" --check --prefix "$prefix" 2>"$work/err5.txt") || rc=$?
assert_eq "9.9.9" "$out" "install.sh --check must report the latest version with a token"
assert_contains "$(cat "$log")" "-H Authorization: Bearer secret-token" \
  "the token must be sent as an Authorization header"

# --------------------------------------------------------------------------
# 变异自证 1：把重定向兜底改回去（只剩 API），判据必须变红
# --------------------------------------------------------------------------
d=$(tmpdir)
cp "$TEST_ROOT/install.sh" "$d/install.sh"
# 把兜底函数整个换成「永远失败」—— 按函数边界做，与覆盖率插桩无关
stub_out_function "$d/install.sh" latest_via_redirect
export FAKE_API_BODY='{"message":"API rate limit exceeded"}'
export FAKE_API_EXIT=22
_run_install "$d/install.sh"
assert_ne "8.8.8" "$out" "dropping the redirect fallback must break the check"
assert_ne "0" "$rc" "without the fallback the rate-limited case must fail"

# --------------------------------------------------------------------------
# 变异自证 2：把两类失败抹平成一类（网络失败也报 5），判据必须变红
#
# 这正是 2026-11-21 实际发生的那个回归：给「查最新版本」加了兜底路径之后，
# 两条路都失败时一律 die 5 —— 主路径原本的 4（网络失败）整个丢了。
# 后果不是「退出码不好看」：4 = 重试可能有用，5 = 重试无用 —— 抹平之后
# 调用方会把断网当成「这个版本号不可信」。
#
# 变异做在**调用点**上（把 "$?" 换回写死的 "$SK_VERIFY"）：那一行是普通文本，
# 覆盖率插桩只会往分支臂里插计数器，不会改写它 ⇒ 插桩副本里同样成立。
# --------------------------------------------------------------------------
d2=$(tmpdir)
cp "$TEST_ROOT/install.sh" "$d2/install.sh"
python3 - "$d2/install.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = 'both failed)" "$?"'
new = 'both failed)" "$SK_VERIFY"'
if old not in s:
    sys.stderr.write("mutation anchor not found\n")
    sys.exit(1)
open(p, "w", encoding="utf-8").write(s.replace(old, new))
PY
export FAKE_API_BODY='{"message":"API rate limit exceeded"}'
export FAKE_API_EXIT=22
export FAKE_REDIRECT_HEADERS='HTTP/1.1 404 Not Found
'
export FAKE_HEAD_EXIT=0
_run_install "$d2/install.sh"
assert_eq "5" "$rc" "collapsing the two failure kinds must show up as 5 (the defect) instead of 4"
assert_ne "4" "$rc" "the network failure must no longer be reported as 4 once the distinction is gone"

exit 0
