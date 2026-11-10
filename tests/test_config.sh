#!/usr/bin/env bash
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"

d=$(tmpdir)
cfg="$d/config.txt"

_file_inode() {
  if stat -f '%i' "$1" >/dev/null 2>&1; then
    stat -f '%i' "$1"
  else
    stat -c '%i' "$1"
  fi
}

assert_eq "fallback" "$(conf_get ANY_KEY fallback)" "conf_get before conf_init"

conf_init "$cfg"
assert_eq "$cfg" "$(conf_file)" "conf_file"

conf_set "DB_HOST" "127.0.0.1"
assert_eq "127.0.0.1" "$(conf_get DB_HOST)" "conf_get after set"
assert_file_mode "$cfg" "600" "config file mode"

conf_set "DB_PORT" "3306"
assert_eq "3306" "$(conf_get DB_PORT)" "second key"
assert_eq "127.0.0.1" "$(conf_get DB_HOST)" "first key still intact"

conf_set "DB_HOST" "10.0.0.1"
assert_eq "10.0.0.1" "$(conf_get DB_HOST)" "overwrite"
assert_eq "1" "$(grep -c '^DB_HOST=' "$cfg")" "no duplicate key lines"

inode_before=$(_file_inode "$cfg")
conf_set "DB_HOST" "10.0.0.1"
assert_eq "$inode_before" "$(_file_inode "$cfg")" "no-op write when value unchanged"

assert_true conf_has "DB_HOST"
assert_false conf_has "MISSING_KEY"

# 故意设成环境变量，用来验证「环境变量 > 配置文件」
# shellcheck disable=SC2034
DB_HOST="from-env"
assert_eq "from-env" "$(conf_get_any DB_HOST)" "env wins"
unset DB_HOST
assert_eq "10.0.0.1" "$(conf_get_any DB_HOST)" "file beats default"
assert_eq "dflt" "$(conf_get_any MISSING_KEY dflt)" "default last"

conf_disable "DB_PORT"
assert_false conf_has "DB_PORT"
assert_contains "$(cat "$cfg")" "# DB_PORT=3306"

conf_set "TEMP_KEY" "x"
conf_unset "TEMP_KEY"
assert_false conf_has "TEMP_KEY"
assert_not_contains "$(cat "$cfg")" "TEMP_KEY"

assert_exit_code 2 conf_set "BAD-KEY" "v"
assert_exit_code 2 conf_set "GOOD_KEY" "$(printf 'a\nb')"
assert_eq "" "$(conf_get GOOD_KEY)" "multiline value rejected"

conf_set "A1" "1"
conf_set "A2" "2"
keys=$(conf_keys)
assert_contains "$keys" "A1"
assert_contains "$keys" "A2"
assert_not_contains "$keys" "#"

assert_eq "" "$(conf_get NOPE)" "missing key without default"

# 「键存在但值为空」不等于「键不存在」：空值不该回落到默认值
printf 'EMPTY_KEY=\n' >>"$cfg"
assert_true conf_has "EMPTY_KEY"
assert_eq "" "$(conf_get EMPTY_KEY fallback)" "an empty value does not fall back to the default"
assert_eq "" "$(conf_get EMPTY_KEY)" "an empty value stays empty without a default"
assert_eq "fallback" "$(conf_get ABSENT_KEY fallback)" "a missing key still falls back"

# ---- dotenv ----

d2=$(tmpdir)
env_file="$d2/.env"
cat >"$env_file" <<'ENVEOF'
# a comment

PLAIN=value
QUOTED="double quoted"
SQUOTED='single quoted'
EXPORTED=exported value
EMPTY=
SPACED = spaced
this line is not valid
ENVEOF

conf_load_dotenv "$env_file" >/dev/null 2>&1
assert_eq "value" "$(conf_get PLAIN)" "dotenv: a plain value"
assert_eq "double quoted" "$(conf_get QUOTED)" "dotenv: double quotes are stripped"
assert_eq "single quoted" "$(conf_get SQUOTED)" "dotenv: single quotes are stripped"
assert_eq "exported value" "$(conf_get EXPORTED)" "dotenv: the export prefix is accepted"
assert_true conf_has "EMPTY" "dotenv: an empty value still means the key exists"
assert_eq "" "$(conf_get EMPTY)" "dotenv: an empty value stays empty"
assert_false conf_has "this line is not valid" "dotenv: an invalid line is not a key"

# 非法行只跳过并告警，不整体失败
warn=$(conf_load_dotenv "$env_file" 2>&1 >/dev/null)
assert_contains "$warn" "skipping invalid dotenv line" "dotenv: an invalid line is reported"

# 文件不存在是前置条件不满足
rc=0
conf_load_dotenv "$d2/missing.env" >/dev/null 2>&1 || rc=$?
assert_eq "3" "$rc" "dotenv: a missing file is a precondition failure"

# conf_source 把键导出为环境变量（与 conf_load_dotenv 的区别）
src_file="$d2/src.env"
printf 'EXPORTED_KEY=exported_value\n' >"$src_file"
out=$(
  conf_source "$src_file" >/dev/null 2>&1
  printf '%s\n' "$EXPORTED_KEY"
)
assert_eq "exported_value" "$out" "conf_source exports the key into the environment"

# conf_init --format dotenv 走同一条解析路径
d3=$(tmpdir)
fmt_file="$d3/app.env"
printf 'APP_NAME=demo\n' >"$fmt_file"
conf_init "$fmt_file" --format dotenv >/dev/null 2>&1
assert_eq "demo" "$(conf_get APP_NAME)" "conf_init --format dotenv reads dotenv files"
assert_eq "dotenv" "$(conf_format)" "conf_format reports the active format"

# ---- dotenv 的写回必须与读取端一致 ----
# 读的时候认 export 前缀，写的时候也必须认：否则 conf_unset 说删掉了，
# 文件里那一行还在，下一次读取又把旧值拿回来。
d4=$(tmpdir)
w_file="$d4/app.env"
printf 'export W_TOKEN=old-secret\nW_PLAIN=plain-value\n' >"$w_file"
conf_init "$w_file" --format dotenv >/dev/null 2>&1

conf_set W_TOKEN new-secret >/dev/null 2>&1
assert_contains "$(cat "$w_file")" "export W_TOKEN=new-secret" "conf_set must keep the export prefix"
assert_eq "new-secret" "$(conf_get W_TOKEN)" "conf_set must write a value that reads back"

conf_unset W_TOKEN >/dev/null 2>&1
assert_not_contains "$(cat "$w_file")" "W_TOKEN" "conf_unset must remove an exported key too"
assert_false conf_has W_TOKEN "conf_unset must really drop the key"
assert_eq "plain-value" "$(conf_get W_PLAIN)" "conf_unset must not touch the other keys"

conf_disable W_PLAIN >/dev/null 2>&1
assert_contains "$(cat "$w_file")" "# W_PLAIN=plain-value" "conf_disable must comment the line out"
assert_false conf_has W_PLAIN "a commented key must not be readable"

# 带引号的值：写回之后仍然读得回同一个值
d5=$(tmpdir)
q_file="$d5/quoted.env"
printf 'Q_ONE="quoted value"\n' >"$q_file"
conf_init "$q_file" --format dotenv >/dev/null 2>&1
assert_eq "quoted value" "$(conf_get Q_ONE)" "dotenv: the quotes are stripped on read"
conf_set Q_ONE "other value" >/dev/null 2>&1
assert_eq "other value" "$(conf_get Q_ONE)" "conf_set must keep a quoted value readable"

# 值里带行尾空白：不加引号读回来会被去尾空白，写回必须自己处理
d6=$(tmpdir)
wsp_file="$d6/space.env"
printf 'W_SPACED=plain\n' >"$wsp_file"
conf_init "$wsp_file" --format dotenv >/dev/null 2>&1
conf_set W_SPACED "trailing " >/dev/null 2>&1
assert_eq "trailing " "$(conf_get W_SPACED)" "a value with trailing spaces must survive a rewrite"

# 新增一个键：写回时也要能读回来
d7=$(tmpdir)
new_file="$d7/new.env"
printf 'EXISTING=one\n' >"$new_file"
conf_init "$new_file" --format dotenv >/dev/null 2>&1
conf_set ADDED two >/dev/null 2>&1
assert_eq "two" "$(conf_get ADDED)" "a new key must be readable right away"
assert_contains "$(cat "$new_file")" "ADDED=two" "the new key must land in the file"

# 默认的 auto 格式：老形态的值原样保留，export 行也要认
d8=$(tmpdir)
auto_file="$d8/auto.env"
printf 'export AUTO_KEY=auto-value\nA_PLAIN=plain\n' >"$auto_file"
conf_init "$auto_file" >/dev/null 2>&1
assert_eq "auto-value" "$(conf_get AUTO_KEY)" "auto: the export prefix is readable"
conf_set AUTO_KEY "changed value" >/dev/null 2>&1
assert_eq "changed value" "$(conf_get AUTO_KEY)" "auto: conf_set must write a value that reads back"
conf_unset AUTO_KEY >/dev/null 2>&1
assert_not_contains "$(cat "$auto_file")" "AUTO_KEY" "auto: conf_unset must remove an exported key"
assert_eq "plain" "$(conf_get A_PLAIN)" "auto: the untouched key keeps its value"
