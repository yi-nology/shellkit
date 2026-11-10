#!/usr/bin/env bash
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"

d="$(tmpdir)"
f="$d/profile.txt"

profile_write "$f"
profile_append "$f" bun registry=https://registry.npmmirror.com
profile_append "$f" docker 'version=24.0'

out="$(profile_parse "$f")"
assert_contains "$out" "bun"
assert_contains "$out" "registry=https://registry.npmmirror.com"
assert_contains "$out" "docker"

env_out="$(profile_env "$(printf 'docker\tversion=24.0')" UXS_CONFIG_)"
assert_eq "UXS_CONFIG_version=24.0" "$env_out" "profile_env builds env assignments"

# 空格分隔的写法也认（profile 文件本身就是空格分隔的）
env_out="$(profile_env "docker version=24.0" UXS_CONFIG_)"
assert_eq "UXS_CONFIG_version=24.0" "$env_out" "profile_env accepts a space separated line"

# 多个键值对 -> 多行环境变量赋值
env_out="$(profile_env "$(printf 'bun\tregistry=https://x,mirror=https://y')" UXS_)"
assert_eq "UXS_registry=https://x
UXS_mirror=https://y" "$env_out" "profile_env emits one line per key"

# 注释：从第一个 # 起截断（与 unix_script 的 profile 解析同口径）
printf '# 这是注释\nbun registry=https://x # 尾注\n\n   \nnginx version=1.25\n' >"$f"
out="$(profile_parse "$f")"
assert_eq $'bun\tregistry=https://x' "$(printf '%s\n' "$out" | sed -n '1p')" "a trailing comment is dropped"
assert_eq $'nginx\tversion=1.25' "$(printf '%s\n' "$out" | sed -n '2p')" "blank lines are skipped"

# 第一个 # 就截断（值里带 # 也一样）
printf 'bun registry=https://x#y\n' >"$f"
assert_eq $'bun\tregistry=https://x' "$(profile_parse "$f")" "the first hash starts the comment"

# profile_write 清空文件
profile_write "$f"
assert_eq "" "$(profile_parse "$f")" "profile_write truncates the file"

# 缺参数 / 文件不存在
assert_exit_code 2 profile_write
assert_exit_code 2 profile_append
assert_exit_code 2 profile_append "$f"
assert_eq "" "$(profile_parse "$d/nosuchfile")" "parsing a missing file yields nothing"
