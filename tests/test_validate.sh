#!/usr/bin/env bash
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"

assert_true validate_not_empty "x"
assert_false validate_not_empty ""

assert_true validate_single_line "a=b"
assert_false validate_single_line "$(printf 'a\nb')"

assert_true validate_key "FOO_BAR1"
assert_true validate_key "_x"
assert_false validate_key "1ABC"
assert_false validate_key "A-B"
assert_false validate_key ""

assert_true validate_port "1"
assert_true validate_port "65535"
assert_false validate_port "0"
assert_false validate_port "65536"
assert_false validate_port "abc"
assert_false validate_port ""

assert_true validate_ip "10.0.0.1"
assert_true validate_ip "255.255.255.255"
assert_false validate_ip "256.0.0.1"
assert_false validate_ip "10.0.0"
assert_false validate_ip "a.b.c.d"
# 前导零会被不少程序当八进制解析（010 = 8），这类写法必须判假
assert_false validate_ip "010.1.1.1"
assert_false validate_ip "08.1.1.1"
assert_false validate_ip "001.2.3.4"
assert_false validate_ip "1.2.3.000"
assert_true validate_ip "0.0.0.0"
assert_false validate_ip "192.168.001.1"
assert_true validate_ip "8.8.8.8"

assert_true validate_version "1.2.3"
assert_true validate_version "v1.2.3"
assert_true validate_version "1"
assert_false validate_version "x.y.z"

assert_true validate_abs_path "/tmp/x"
assert_false validate_abs_path "tmp/x"

assert_true validate_url "https://example.com/a"
assert_true validate_url "http://127.0.0.1:8080"
assert_false validate_url "ftp://example.com"
assert_false validate_url "example.com"

assert_true validate_enum "b" "a|b|c"
assert_false validate_enum "d" "a|b|c"

validate_port "99999" >/dev/null 2>&1 || true
assert_contains "$SK_VALIDATE_ERR" "99999" "SK_VALIDATE_ERR keeps reason"
