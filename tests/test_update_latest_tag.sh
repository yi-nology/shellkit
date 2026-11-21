#!/usr/bin/env bash
# 查最新版本：API 配额用光时也要能升级。
#
# 背景（2026-11-21 实测）：`shellkit update` 打的是 api.github.com 的**未认证**请求，
# 配额是 60 次/小时**每个 IP** —— 共享出口（公司 NAT / 云主机 / CI runner）很容易用光。
# 实测本机撞上：x-ratelimit-remaining: 0 ⇒ HTTP 403 ⇒ update 直接不可用，
# 而用户此时正想升级。
#
# ⇒ 两道取法：① API（带了 token 就是认证请求，5000 次/小时）；
#    ② /releases/latest 的**重定向**（不吃 API 配额）。
#
# 全程离线：假 curl 按 URL 分派两种响应，一个包都不发出去。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"
. "$TEST_ROOT/lib/core/http.sh"

API="https://api.github.com/repos/yi-nology/shellkit/releases/latest"
PAGE="https://github.com/yi-nology/shellkit/releases/latest"

# 假 curl：把 -o 指到的文件写成响应体，-D 指到的文件写成响应头，
# 状态码打到 stdout（真 curl 的 -w %{http_code} 就是这个效果）。
# 按 URL 分派：api.github.com 与 releases/latest 给不同的响应。
FAKE_CURL_BODY='
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
    -o|-D) prev=$a ;;
    *) prev="" ;;
  esac
  case "$a" in
    http*) url=$a ;;
  esac
done
case "$url" in
*api.github.com*)
  printf "%s" "$FAKE_API_BODY" >"$ofile"
  printf "%s" "$FAKE_API_HEADERS" >"$dfile"
  printf "%s" "$FAKE_API_CODE"
  ;;
*releases/latest*)
  printf "%s" "$FAKE_PAGE_BODY" >"$ofile"
  printf "%s" "$FAKE_PAGE_HEADERS" >"$dfile"
  printf "%s" "$FAKE_PAGE_CODE"
  ;;
esac
'

# _fake_curl —— 装上假 curl（每个用例前重来一次，让调用次数可数）
_fake_curl() {
  # stub 自己会清空日志（`: >log`）⇒ 重新装一次桩，调用次数就从头数。
  # 不用 stub_reset：它把桩目录删了却不清 SK_STUB_ROOT ⇒ 下一次装桩时目录不再建，
  # 桩的日志写不进去 ⇒ 桩形同虚设（调用次数恒为 0）。
  stub curl --body "$FAKE_CURL_BODY"
}

# --------------------------------------------------------------------------
# 用例 1：API 有答案 ⇒ 用 API 的，且不去碰重定向
# --------------------------------------------------------------------------
export FAKE_API_BODY='{"tag_name":"v9.9.9"}'
export FAKE_API_HEADERS='HTTP/1.1 200 OK
Content-Type: application/json
'
export FAKE_API_CODE=200
export FAKE_PAGE_BODY=''
export FAKE_PAGE_HEADERS='HTTP/1.1 302 Found
location: https://github.com/yi-nology/shellkit/releases/tag/v1.6.0
'
export FAKE_PAGE_CODE=302
_fake_curl
tag=$(_sk_http_latest_tag "$API" "$PAGE")
assert_eq "v9.9.9" "$tag" "the API answer must win"
assert_stub_called curl 1

# --------------------------------------------------------------------------
# 用例 2：API 被限流（403，配额用光）⇒ 必须走重定向兜底
# --------------------------------------------------------------------------
export FAKE_API_BODY='{"message":"API rate limit exceeded"}'
export FAKE_API_HEADERS='HTTP/1.1 403 Forbidden
X-RateLimit-Remaining: 0
'
export FAKE_API_CODE=403
_fake_curl
tag=$(_sk_http_latest_tag "$API" "$PAGE")
assert_eq "v1.6.0" "$tag" "the redirect must be the fallback when the API is rate limited"
assert_stub_called curl 2

# --------------------------------------------------------------------------
# 用例 3：两条路都不通 ⇒ 非 0，且不输出半截 tag
# --------------------------------------------------------------------------
export FAKE_PAGE_BODY=''
export FAKE_PAGE_HEADERS='HTTP/1.1 404 Not Found
'
export FAKE_PAGE_CODE=404
_fake_curl
tag=''
rc=0
tag=$(_sk_http_latest_tag "$API" "$PAGE") || rc=$?
assert_ne "0" "$rc" "no tag at all must not look like success"
assert_eq "" "$tag" "no tag must be printed"

# --------------------------------------------------------------------------
# 用例 4：有 token ⇒ 请求带 Authorization 头（认证请求配额 5000/小时）
# --------------------------------------------------------------------------
export FAKE_API_BODY='{"tag_name":"v9.9.9"}'
export FAKE_API_HEADERS='HTTP/1.1 200 OK
'
export FAKE_API_CODE=200
_fake_curl
export GH_TOKEN=secret-token
tag=$(_sk_http_latest_tag "$API" "$PAGE")
unset GH_TOKEN
assert_eq "v9.9.9" "$tag" "the API answer must win with a token too"
assert_stub_args curl "-H Authorization: Bearer secret-token"

# --------------------------------------------------------------------------
# 用例 5：两个端点都没给 ⇒ 退 2（用法错），不许发请求出去
# --------------------------------------------------------------------------
rc=0
_sk_http_latest_tag "" "" >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "no endpoints at all must be a usage error"

# --------------------------------------------------------------------------
# 变异自证：把兜底那一段改回去（只剩 API），判据必须变红
# --------------------------------------------------------------------------
d=$(tmpdir)
cp "$TEST_ROOT/lib/core/http.sh" "$d/http.sh"
# 把兜底函数整个换成「永远失败」—— 按函数边界做，与覆盖率插桩无关
stub_out_function "$d/http.sh" _sk_http_latest_tag_via_redirect
export FAKE_API_BODY='{"message":"API rate limit exceeded"}'
export FAKE_API_HEADERS='HTTP/1.1 403 Forbidden
'
export FAKE_API_CODE=403
export FAKE_PAGE_HEADERS='HTTP/1.1 302 Found
location: https://github.com/yi-nology/shellkit/releases/tag/v1.6.0
'
export FAKE_PAGE_CODE=302
_fake_curl
. "$d/http.sh"
mut_tag=''
mut_rc=0
mut_tag=$(_sk_http_latest_tag "$API" "$PAGE") || mut_rc=$?
assert_ne "v1.6.0" "$mut_tag" "dropping the redirect fallback must break the check"
assert_ne "0" "$mut_rc" "without the fallback the rate-limited case must fail"

exit 0
