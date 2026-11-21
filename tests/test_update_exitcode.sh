#!/usr/bin/env bash
# shellkit update 的退出码必须分得清「网络失败(4)」与「校验失败(5)」。
#
# 背景（v1.6.1 复核时定下的口径，docs/ROADMAP.md v1.7.0）：install.sh / demo.sh
# 在两条路都失败时按「API 没拿到东西 ⇒ 4 / 答了但没版本 ⇒ 5」分类，而 CLI 的
# cmd_update 把 _sk_http_latest_tag 的返回码一律压成 5 ⇒ 三条入口口径不一致：
# 断网在 install.sh 里是「重试可能有用」，在 update 里却成了「校验失败」。
#
# 判据跑真的 `bash shellkit update --check`（PATH 上放假 curl，全程离线）。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

work=$(tmpdir)
mkdir -p "$work/bin" "$work/prefix"
log=$work/curl.log

# 假 curl：按 URL 分派。-o 写响应体、-D 写响应头、stdout 打 http_code
# （真 curl 的 -w %{http_code} 就是这个效果）；FAKE_*_EXIT 非 0 ⇒ 整个请求失败
# （模拟连不上：真 curl 退 7）。
cat >"$work/bin/curl" <<'FAKE'
#!/usr/bin/env bash
prev=""
ofile=""
dfile=""
url=""
for a in "$@"; do
  case "$prev" in
    -o) ofile=$a ;;
    -D) dfile=$a ;;
  esac
  case "$a" in
    -o | -D) prev=$a ;;
    *) prev="" ;;
  esac
  case "$a" in
    http*) url=$a ;;
  esac
done
printf '%s\n' "$*" >>"$FAKE_CURL_LOG"
case "$url" in
*api.github.com*)
  [ "${FAKE_API_EXIT:-0}" -ne 0 ] && exit "$FAKE_API_EXIT"
  [ -n "$ofile" ] && printf '%s' "$FAKE_API_BODY" >"$ofile"
  [ -n "$dfile" ] && printf '%s' "$FAKE_API_HEADERS" >"$dfile"
  printf '%s' "$FAKE_API_CODE"
  ;;
*releases/latest*)
  [ "${FAKE_PAGE_EXIT:-0}" -ne 0 ] && exit "$FAKE_PAGE_EXIT"
  [ -n "$ofile" ] && printf '%s' "$FAKE_PAGE_BODY" >"$ofile"
  [ -n "$dfile" ] && printf '%s' "$FAKE_PAGE_HEADERS" >"$dfile"
  printf '%s' "$FAKE_PAGE_CODE"
  ;;
*) exit 22 ;;
esac
exit 0
FAKE
chmod +x "$work/bin/curl"

# _run_update CLI —— 跑 update --check；结果在 out / rc（stderr 在 err.txt）。
# GH_TOKEN / GITHUB_TOKEN 显式清空：带了 token 请求形状就变了，用例要可复现。
out=""
rc=0
_run_update() {
  local __cli=$1
  out=""
  rc=0
  out=$(PATH="$work/bin:$PATH" FAKE_CURL_LOG="$log" \
    FAKE_API_BODY="${FAKE_API_BODY:-}" FAKE_API_HEADERS="${FAKE_API_HEADERS:-}" \
    FAKE_API_CODE="${FAKE_API_CODE:-200}" FAKE_API_EXIT="${FAKE_API_EXIT:-0}" \
    FAKE_PAGE_BODY="${FAKE_PAGE_BODY:-}" FAKE_PAGE_HEADERS="${FAKE_PAGE_HEADERS:-}" \
    FAKE_PAGE_CODE="${FAKE_PAGE_CODE:-404}" FAKE_PAGE_EXIT="${FAKE_PAGE_EXIT:-0}" \
    GH_TOKEN='' GITHUB_TOKEN='' \
    bash "$__cli" update --check --prefix "$work/prefix" 2>"$work/err.txt") || rc=$?
  return 0
}

# --------------------------------------------------------------------------
# 用例 A：API 403（配额用光）+ 重定向没给版本号 ⇒ 必须是 4（没拿到东西）
# --------------------------------------------------------------------------
export FAKE_API_BODY='{"message":"API rate limit exceeded"}'
export FAKE_API_CODE=403
export FAKE_API_HEADERS='HTTP/1.1 403 Forbidden
X-RateLimit-Remaining: 0
'
export FAKE_API_EXIT=0
export FAKE_PAGE_BODY=''
export FAKE_PAGE_HEADERS='HTTP/1.1 404 Not Found
'
export FAKE_PAGE_CODE=404
export FAKE_PAGE_EXIT=0
_run_update "$TEST_ROOT/shellkit"
assert_eq "4" "$rc" "a rate-limited API plus a dead redirect must report a network failure (4)"
assert_eq "" "$out" "no version must be printed when both paths fail"

# --------------------------------------------------------------------------
# 用例 B：API 答了（200）但内容里没有 tag_name ⇒ 5（答了，但没给版本号）
#
# 与用例 A 只差一处：API 那一步是成功的。4 与 5 必须分得开 ——
# 「断网」与「地址给不出版本」在调用方眼里是两件事（重试有没有用）。
# --------------------------------------------------------------------------
export FAKE_API_BODY='{"foo":1}'
export FAKE_API_CODE=200
export FAKE_API_HEADERS='HTTP/1.1 200 OK
'
_run_update "$TEST_ROOT/shellkit"
assert_eq "5" "$rc" "an API that answers without a version must report a verification failure (5)"

# --------------------------------------------------------------------------
# 用例 C：两问都连不上（curl 退 7）⇒ 4
# --------------------------------------------------------------------------
export FAKE_API_EXIT=7
export FAKE_PAGE_EXIT=7
_run_update "$TEST_ROOT/shellkit"
assert_eq "4" "$rc" "two unreachable endpoints must report a network failure (4)"
export FAKE_API_EXIT=0
export FAKE_PAGE_EXIT=0

# --------------------------------------------------------------------------
# 用例 D：API 有答案 ⇒ 正常拿到版本号（回归：分类改造不许碰坏主路径）
# --------------------------------------------------------------------------
export FAKE_API_BODY='{"tag_name":"v9.9.9"}'
export FAKE_API_CODE=200
export FAKE_API_HEADERS='HTTP/1.1 200 OK
'
_run_update "$TEST_ROOT/shellkit"
assert_eq "0" "$rc" "update --check must succeed when the API answers"
assert_eq "9.9.9" "$out" "update --check must print the latest version"

# --------------------------------------------------------------------------
# 变异自证：把 cmd_update 的「透传返回码」改回写死的 5 ⇒ 用例 A 必须变红
#
# 变异只改一个 return（不是函数边界）：那一行是普通语句，覆盖率插桩只往
# 分支臂里插计数器、不改写 return 的参数 ⇒ 插桩副本里同样成立。
# --------------------------------------------------------------------------
d=$(tmpdir)
cp -R "$TEST_ROOT/lib" "$d/" || _fail "cannot copy lib"
cp -f "$TEST_ROOT/shellkit" "$d/" || _fail "cannot copy the CLI"
cp -f "$TEST_ROOT/VERSION" "$d/" || _fail "cannot copy VERSION"
python3 - "$d/shellkit" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
anchor = "cannot read the latest version from the release API"
i = s.index(anchor)
j = s.index('return "$__rc"', i)
s = s[:j] + 'return "$SK_VERIFY"' + s[j + len('return "$__rc"'):]
open(p, "w", encoding="utf-8").write(s)
PY
export FAKE_API_BODY='{"message":"API rate limit exceeded"}'
export FAKE_API_CODE=403
export FAKE_PAGE_CODE=404
_run_update "$d/shellkit"
assert_eq "5" "$rc" "collapsing the propagated code to SK_VERIFY must show 5 (the defect)"

exit 0
