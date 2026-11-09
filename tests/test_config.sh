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
