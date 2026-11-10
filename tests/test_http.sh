#!/usr/bin/env bash
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"
# http 模块还没进 lib/modules.txt（模块清单由维护者统一改），这里显式加载一次。
# 清单补上后这行变成重复 source，同名函数重定义无害。
. "$TEST_ROOT/lib/core/http.sh"

d=$(tmpdir)

# ---------------------------------------------------------------------------
# 假 curl：把响应体写到 -o 指定的文件，响应头写到 -D 指定的文件，
# 状态码走 stub 的 --stdout。全程离线，不发一个包出去。
# ---------------------------------------------------------------------------
FAKE_CURL_BODY='
prev=""
ofile=""
dfile=""
for a in "$@"; do
  case "$prev" in
    -o) ofile=$a ;;
    -D) dfile=$a ;;
  esac
  case "$a" in
    -o|-D) prev=$a ;;
    *) prev="" ;;
  esac
done
if [ -n "$ofile" ]; then printf "%s" "$FAKE_BODY" >"$ofile"; fi
if [ -n "$dfile" ]; then printf "%s" "$FAKE_HEADERS" >"$dfile"; fi
'
export FAKE_BODY='{"hello":"world"}'
export FAKE_HEADERS='HTTP/1.1 200 OK
Content-Type: application/json
'

stub curl --stdout '200' --body "$FAKE_CURL_BODY"

# ---------------------------------------------------------------------------
# net_request：方法、请求头、状态码、响应体、响应头
# ---------------------------------------------------------------------------
# 出参是全局变量，所以函数必须在当前 shell 里跑，不能包在 $( ) 里
net_request get "https://api.example.com/v1/items" --header 'Authorization: Bearer tok' \
  >"$d/stdout.txt" 2>"$d/stderr.txt"
assert_eq "" "$(cat "$d/stdout.txt")" "net_request keeps stdout clean"
assert_eq "200" "$SK_HTTP_CODE" "net_request reports the status code"
assert_eq '{"hello":"world"}' "$SK_HTTP_BODY" "net_request reports the response body"
assert_contains "$SK_HTTP_HEADERS" "Content-Type: application/json" "net_request reports the response headers"
assert_stub_called curl 1
assert_stub_args curl "-X GET"
assert_stub_args curl "-H Authorization: Bearer tok"
assert_stub_args curl "--max-time 30"
assert_stub_args curl "--connect-timeout 10"

# --json 是 --data 的便捷形式：自动补 Content-Type
net_request POST "https://api.example.com/v1/items" --json '{"name":"x"}' \
  >"$d/stdout.txt" 2>"$d/stderr.txt"
assert_stub_args curl "-H Content-Type: application/json"
assert_stub_args curl '--data {"name":"x"}'

# --data 不会自动加 Content-Type（重新 stub 是为了清掉上一次调用的日志）
stub curl --stdout '200' --body "$FAKE_CURL_BODY"
net_request POST "https://api.example.com/v1/items" --data 'plain' \
  >"$d/stdout.txt" 2>"$d/stderr.txt"
assert_not_contains "$(cat "$(_sk_stub_log curl)")" "Content-Type: application/json"

# --output 把响应体写文件，而不是放进 SK_HTTP_BODY
outfile="$d/body.json"
net_request GET "https://api.example.com/v1/items" --output "$outfile" \
  >"$d/stdout.txt" 2>"$d/stderr.txt"
assert_eq '{"hello":"world"}' "$(cat "$outfile")" "--output writes the body to the file"
assert_eq "" "$SK_HTTP_BODY" "--output leaves SK_HTTP_BODY empty"

# 500 不是错误：状态码由业务自己判断
stub curl --stdout '500' --body "$FAKE_CURL_BODY"
rc=0
net_request GET "https://api.example.com/v1/items" >"$d/stdout.txt" 2>"$d/stderr.txt" || rc=$?
assert_eq "0" "$rc" "an HTTP 500 is not a transport error"
assert_eq "500" "$SK_HTTP_CODE" "the status code is reported for a 500 too"

# 网络层失败 -> SK_NET(4)
stub curl --exit 7 --body "$FAKE_CURL_BODY"
rc=0
net_request GET "https://api.example.com/v1/items" >"$d/stdout.txt" 2>"$d/stderr.txt" || rc=$?
assert_eq "4" "$rc" "a failed connection returns SK_NET"
assert_eq "" "$SK_HTTP_CODE" "a failed connection leaves the status code empty"

# 参数错 -> SK_USAGE(2)
stub curl --stdout '200' --body "$FAKE_CURL_BODY"
rc=0
net_request >"$d/stdout.txt" 2>"$d/stderr.txt" || rc=$?
assert_eq "2" "$rc" "missing arguments return SK_USAGE"
rc=0
net_request GET "https://api.example.com/v1/items" --bogus \
  >"$d/stdout.txt" 2>"$d/stderr.txt" || rc=$?
assert_eq "2" "$rc" "an unknown option returns SK_USAGE"
rc=0
net_request GET "https://api.example.com/v1/items" --timeout abc \
  >"$d/stdout.txt" 2>"$d/stderr.txt" || rc=$?
assert_eq "2" "$rc" "a non-numeric timeout returns SK_USAGE"
rc=0
net_request GET "https://api.example.com/v1/items" --data a --json b \
  >"$d/stdout.txt" 2>"$d/stderr.txt" || rc=$?
assert_eq "2" "$rc" "--data together with --json returns SK_USAGE"

# 没有 curl -> SK_PRECOND(3)
unstub curl
mkdir -p "$d/nocurl"
saved_path=$PATH
# 故意把 PATH 缩成一个空目录：这样 command -v 才真的找不到 curl。
# shellcheck disable=SC2123
PATH="$d/nocurl"
hash -r
rc=0
net_request GET "https://api.example.com/v1/items" >"$d/stdout.txt" 2>"$d/stderr.txt" || rc=$?
PATH=$saved_path
hash -r
assert_eq "3" "$rc" "a missing curl returns SK_PRECOND"
assert_contains "$(cat "$d/stderr.txt")" "curl" "the missing curl is named in the error"

# ---------------------------------------------------------------------------
# net_json：jq / python3 解析
# ---------------------------------------------------------------------------
export FAKE_BODY='{"data":{"items":[{"name":"alpha"},{"name":"beta"}]},"ok":true}'
stub curl --stdout '200' --body "$FAKE_CURL_BODY"

if command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1; then
  net_json GET "https://api.example.com/v1/items" --path data.items.0.name \
    >"$d/stdout.txt" 2>"$d/stderr.txt"
  assert_eq "alpha" "$(cat "$d/stdout.txt")" "net_json extracts a dotted path"
  assert_eq "200" "$SK_HTTP_CODE" "net_json reports the status code too"

  net_json GET "https://api.example.com/v1/items" --path data.items.1.name \
    >"$d/stdout.txt" 2>"$d/stderr.txt"
  assert_eq "beta" "$(cat "$d/stdout.txt")" "net_json extracts the second array element"

  net_json GET "https://api.example.com/v1/items" \
    >"$d/stdout.txt" 2>"$d/stderr.txt"
  assert_eq '{"data":{"items":[{"name":"alpha"},{"name":"beta"}]},"ok":true}' \
    "$(cat "$d/stdout.txt")" "net_json prints the whole JSON when no path is given"

  rc=0
  net_json GET "https://api.example.com/v1/items" --path data.missing \
    >"$d/stdout.txt" 2>"$d/stderr.txt" || rc=$?
  assert_eq "5" "$rc" "a missing JSON path returns SK_VERIFY"

  rc=0
  net_json GET "https://api.example.com/v1/items" --path data.items.9.name \
    >"$d/stdout.txt" 2>"$d/stderr.txt" || rc=$?
  assert_eq "5" "$rc" "an out-of-range array index returns SK_VERIFY"

  # 响应不是合法 JSON -> SK_VERIFY(5)
  # 这一条也要有解析器才判得出来：没有 jq 也没有 python3 时 net_json 返回的是 3
  # （前置条件不满足），拿它当 5 断言就是假红。
  export FAKE_BODY='this is not json'
  rc=0
  net_json GET "https://api.example.com/v1/items" >"$d/stdout.txt" 2>"$d/stderr.txt" || rc=$?
  assert_eq "5" "$rc" "a non-JSON response returns SK_VERIFY"
else
  printf 'skip: no jq and no python3, the net_json parsing cases are not run\n' >&2
fi

# 没有 jq 也没有 python3 -> SK_PRECOND(3)
stub curl --stdout '200' --body "$FAKE_CURL_BODY"
mkdir -p "$d/nojson"
for t in mktemp cat mv rm tr sed; do
  src=$(command -v "$t" 2>/dev/null) || continue
  ln -sf "$src" "$d/nojson/$t"
done
saved_path=$PATH
# 故意把 PATH 缩到只剩常用工具：jq 与 python3 都找不到了。
# shellcheck disable=SC2123
PATH="$d/nojson"
hash -r
rc=0
net_json GET "https://api.example.com/v1/items" >"$d/stdout.txt" 2>"$d/stderr.txt" || rc=$?
PATH=$saved_path
hash -r
assert_eq "3" "$rc" "net_json without jq and without python3 returns SK_PRECOND"
assert_contains "$(cat "$d/stderr.txt")" "python3" "the missing parser is named in the error"

# ---------------------------------------------------------------------------
# net_escape_json
# ---------------------------------------------------------------------------
assert_eq '"a\"b"' "$(net_escape_json 'a"b')" "net_escape_json escapes double quotes"
assert_eq '"a\\b"' "$(net_escape_json 'a\b')" "net_escape_json escapes backslashes"
assert_eq '"line1\nline2"' "$(net_escape_json 'line1
line2')" "net_escape_json escapes newlines"
assert_eq '""' "$(net_escape_json '')" "net_escape_json handles an empty string"

# 降级路径（没有 jq 也没有 python3 时走的那条）单独测
assert_eq '"a\"b"' "$(_sk_http_escape_fallback 'a"b')" "the fallback escapes double quotes"
assert_eq '"a\\b"' "$(_sk_http_escape_fallback 'a\b')" "the fallback escapes backslashes"
assert_eq '"line1\nline2"' "$(_sk_http_escape_fallback 'line1
line2')" "the fallback escapes newlines"
if command -v python3 >/dev/null 2>&1; then
  fb=$(_sk_http_escape_fallback 'a"b \ c
d')
  python3 -c 'import json, sys
json.loads(sys.argv[1])' "$fb"
  assert_eq "0" "$?" "the fallback output is valid JSON"
fi

unstub curl

# ---------------------------------------------------------------------------
# GitHub release 查询
# ---------------------------------------------------------------------------
export FAKE_BODY='{"tag_name":"v1.2.3","assets":[{"browser_download_url":"https://example.com/x86_64.tar.gz"},{"browser_download_url":"https://example.com/arm64.tar.gz"}]}'
stub curl --stdout '200' --body "$FAKE_CURL_BODY"

assert_eq "1.2.3" "$(http_github_latest_tag owner/repo)" "github latest tag strips the v prefix"
assert_eq "https://example.com/x86_64.tar.gz" "$(http_github_release_asset owner/repo 'x86_64')" "github asset picks the matching one"
assert_eq "https://example.com/arm64.tar.gz" "$(http_github_release_asset owner/repo 'arm64')" "github asset picks the matching one"

# 大写 V 前缀也要去掉
export FAKE_BODY='{"tag_name":"V2.0.0"}'
assert_eq "2.0.0" "$(http_github_latest_tag owner/repo)" "github latest tag strips the V prefix"

# 没有匹配时输出空串（不是报错）
export FAKE_BODY='{"tag_name":"v1.2.3","assets":[{"browser_download_url":"https://example.com/x86_64.tar.gz"}]}'
assert_eq "" "$(http_github_release_asset owner/repo 'nosuchpattern')" "a non-matching pattern yields an empty URL"

# 认证头：有 token 就带上
stub curl --stdout '200' --body "$FAKE_CURL_BODY"
GH_TOKEN=tok-123
export GH_TOKEN
http_github_latest_tag owner/repo >/dev/null
assert_stub_args curl "Authorization: Bearer tok-123"
unset GH_TOKEN

# HTTP 错误码：查不到就返回空串，仍然是 0
export FAKE_BODY='{"message":"Not Found"}'
stub curl --stdout '404' --body "$FAKE_CURL_BODY"
out=$(http_github_latest_tag owner/repo)
rc=$?
assert_eq "" "$out" "a failed release query yields an empty tag"
assert_eq "0" "$rc" "a failed release query still returns 0"

# 网络层失败：同样是空串 + 0
stub curl --exit 7 --body "$FAKE_CURL_BODY"
out=$(http_github_latest_tag owner/repo 2>/dev/null)
rc=$?
assert_eq "" "$out" "a network failure yields an empty tag"
assert_eq "0" "$rc" "a network failure still returns 0"

# 缺参数是用法错
rc=0
http_github_latest_tag >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "github latest tag requires a repo"
rc=0
http_github_release_asset owner/repo >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "github release asset requires a pattern"

unstub curl
