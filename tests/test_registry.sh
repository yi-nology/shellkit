#!/usr/bin/env bash
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"

d="$(tmpdir)"
mkdir -p "$d/alpha" "$d/beta" "$d/gamma"
printf 'LABEL=Alpha\nDEPS=beta\nPLATFORMS=linux,darwin\n' >"$d/alpha/.manifest"
printf 'LABEL=Beta\nDEPS=\nPLATFORMS=\n' >"$d/beta/.manifest"
printf 'LABEL=Gamma\nDEPS=beta\nPLATFORMS=linux\n' >"$d/gamma/.manifest"

registry_scan "$d" '.manifest'
assert_eq "Alpha" "$(registry_get alpha LABEL)" "registry_get reads a field"
assert_eq "beta" "$(registry_get alpha DEPS)" "registry_get reads a list field"
assert_eq "" "$(registry_get alpha NOSUCH)" "registry_get returns empty for a missing field"
assert_eq "" "$(registry_get nosuch LABEL)" "registry_get returns empty for an unknown entry"

# 目录名就是条目名
assert_contains "$(registry_list)" "alpha" "registry_list lists the entries"
assert_contains "$(registry_list)" "beta" "registry_list lists the entries"
assert_eq "3" "$(registry_list | grep -c '')" "registry_list lists every entry"

# 拓扑序：beta 是 alpha 的依赖
assert_eq "beta" "$(registry_deps alpha DEPS)" "registry_deps returns the dependency"
assert_eq "" "$(registry_deps beta DEPS)" "registry_deps of a leaf is empty"

# 平台可见性
assert_true registry_visible alpha PLATFORMS "a module listing both platforms is visible"
assert_true registry_visible beta PLATFORMS "a module without platform limits is visible"
if [ "$(os_name)" = 'linux' ]; then
  assert_true registry_visible gamma PLATFORMS "a linux-only module is visible on linux"
else
  assert_false registry_visible gamma PLATFORMS "a linux-only module is hidden elsewhere"
fi

# KEY 是字面量：带元字符的字段名不该被当成正则
mkdir -p "$d/dotted"
printf 'A.B=literal\nAB=other\n' >"$d/dotted/.manifest"
registry_scan "$d" '.manifest'
assert_eq "literal" "$(registry_get dotted 'A.B')" "a dotted key is matched literally"
assert_eq "other" "$(registry_get dotted 'AB')" "a prefix key does not match a longer key"

# 路径里有空格也不该把索引搞坏（根目录带空格，条目名不带）
mkdir -p "$d/root with space/eps"
printf 'LABEL=Eps\n' >"$d/root with space/eps/.manifest"
registry_scan "$d/root with space" '.manifest'
assert_eq "Eps" "$(registry_get eps LABEL)" "a path with spaces is handled"

# 环检测
mkdir -p "$d/x" "$d/y"
printf 'DEPS=y\n' >"$d/x/.manifest"
printf 'DEPS=x\n' >"$d/y/.manifest"
registry_scan "$d" '.manifest'
assert_false registry_deps x DEPS "a dependency cycle is refused"
assert_false registry_topo DEPS "a dependency cycle is refused for the whole registry"

# 扫描空目录 / 不存在的目录：什么都不该炸
registry_scan "$d/nosuchdir" '.manifest'
assert_eq "" "$(registry_list)" "scanning a missing directory yields nothing"

# ---------------------------------------------------------------------------
# registry_scan_multi：清单分散在多个根目录时，一次扫成一个索引
# （unix_script 的布局是 <分类>/<模块>/.manifest，每个分类目录各扫一次）
# ---------------------------------------------------------------------------
m1="$d/cat-a"
m2="$d/cat-b"
mkdir -p "$m1/one" "$m2/two"
printf 'LABEL=One\nDEPS=\n' >"$m1/one/.manifest"
printf 'LABEL=Two\nDEPS=one\n' >"$m2/two/.manifest"

registry_scan_multi '.manifest' "$m1" "$m2"
assert_eq "One" "$(registry_get one LABEL)" "registry_scan_multi indexes the first root"
assert_eq "Two" "$(registry_get two LABEL)" "registry_scan_multi indexes the second root"
assert_eq "2" "$(registry_list | grep -c '')" "registry_scan_multi merges both roots"
assert_eq "one" "$(registry_deps two DEPS)" "registry_scan_multi resolves deps across roots"
assert_eq "one two" "$(registry_topo DEPS)" "registry_scan_multi sorts across roots"

# 根目录的顺序决定索引的顺序
registry_scan_multi '.manifest' "$m2" "$m1"
assert_eq "two one" "$(printf '%s' "$_REGISTRY_ENTRIES")" "the index follows the root order"

# 少给一个根目录：另一个照样进索引
registry_scan_multi '.manifest' "$m1"
assert_eq "1" "$(registry_list | grep -c '')" "registry_scan_multi works with a single root"

# 不存在的根目录：不炸
registry_scan_multi '.manifest' "$d/nosuchdir"
assert_eq "" "$(registry_list)" "scanning a missing directory yields nothing"

# registry_add：登记单份清单文件（不扫目录）
one="$d/single/.manifest"
mkdir -p "$d/single"
printf 'LABEL=Single\nDEPS=\n' >"$one"
registry_scan_multi '.manifest' "$d/nosuchdir"
registry_add solo "$one"
assert_eq "Single" "$(registry_get solo LABEL)" "registry_add registers a single manifest"
assert_contains "$(registry_list)" "solo" "registry_add puts the entry in the index"
# 同名再登记一次：保持第一次的路径，不重复登记
registry_add solo "$d/other/.manifest"
assert_eq "1" "$(registry_list | grep -c '^solo$')" "registry_add does not register the same name twice"
