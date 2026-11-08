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
