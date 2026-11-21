#!/usr/bin/env bash
#
# 判据：vendor 同步前的同名体检。
#
# 场景：库这一版新加了一个公开函数，而工程里**自己**也定义了一个同名函数。
# 两份定义语义不同（库的 registry_scan 要两个参数，工程的那个不要），
# 谁生效取决于「谁后被 source」—— 加载顺序一变，工程的行为就静默变了
# （菜单空、模块扫不到，而退出码还是 0）。
#
# 本判据钉五件事：
#   1. 新引入的撞名 ⇒ 退 5，且**副本一个字节都没动**（fail-closed）；
#   2. 点名报出：撞的是哪个名字、工程在哪一行、库在哪一行；
#   3. 本来就撞的（工程早就在这么写）⇒ 只提示，不拦升级；
#   4. --allow-shadow 是显式放行的口子；
#   5. 变异自证：把守卫改坏 ⇒ 第 1 条必须不再拦
#      （守卫若没生效，这条判据就没有牙齿）。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

work=$(tmpdir)

# 工程自己定义的同名函数：语义与库里那份完全不同（库里要两个参数）
make_project() {
  local dir=$1
  mkdir -p "$dir/lib"
  cat >"$dir/lib/mine.sh" <<'EOF'
registry_scan() {
  # 工程自己的实现：不要参数，扫多个分类目录
  _REGISTRY_MODULES=""
}
EOF
}

# ---- 1. 新引入的撞名 ⇒ 退 5，且副本没被动 ----
p1="$work/p1"
make_project "$p1"
out=$(bash "$TEST_ROOT/shellkit" vendor "$p1" 2>&1) && rc=0 || rc=$?
assert_eq 5 "$rc" "a fresh name collision must fail closed"
assert_contains "$out" "registry_scan" "the colliding name is named"
assert_contains "$out" "the project defines it at" "the project's definition is pointed at"
assert_contains "$out" "the library defines it at" "the library's definition is pointed at"
assert_contains "$out" "--allow-shadow" "the way out is named"
if [ -e "$p1/vendor/shellkit" ]; then
  _fail "the sync must not touch the project when the collision is new"
fi

# ---- 2. 显式放行 ----
p2="$work/p2"
make_project "$p2"
assert_exit_code 0 "$TEST_ROOT/shellkit" vendor "$p2" --allow-shadow
assert_true test -f "$p2/vendor/shellkit/VERSION"
assert_eq "$(cat "$TEST_ROOT/VERSION")" "$(cat "$p2/vendor/shellkit/VERSION")" \
  "the copy is synced when the collision is allowed"

# ---- 3. 本来就撞 ⇒ 只提示，不拦升级 ----
p3="$work/p3"
bash "$TEST_ROOT/shellkit" new "$p3" >/dev/null 2>&1 || _fail "shellkit new failed"
make_project "$p3"
out=$(bash "$TEST_ROOT/shellkit" vendor "$p3" 2>&1) && rc=0 || rc=$?
assert_eq 0 "$rc" "a pre-existing collision must not block the sync"
assert_contains "$out" "the project defines a function with the same name as the library" \
  "the pre-existing collision is reported"

# ---- 4. 没有撞名 ⇒ 不该有任何噪声 ----
p4="$work/p4"
mkdir -p "$p4/lib"
printf 'my_own_helper() { :; }
' >"$p4/lib/mine.sh"
out=$(bash "$TEST_ROOT/shellkit" vendor "$p4" 2>&1) && rc=0 || rc=$?
assert_eq 0 "$rc" "a project without collisions syncs cleanly"
assert_not_contains "$out" "name collision" "a clean project gets no collision report"

# ---- 5. 变异自证：把守卫改坏 ⇒ 新引入的撞名不再拦 ----
#
# 守卫要是形同虚设，上面第 1 条就只是一句断言而已：真正的同步根本不会停。
# 这里造一份「守卫被改坏」的 CLI（同 SELF_DIR，库还在）再跑一遍：
# 它必须**放行**（退出码 0）—— 证明拦住升级的确实是守卫本身。
fake="$work/fakecli"
mkdir -p "$fake"
for f in lib locale templates tests VERSION repair.sh; do
  cp -R "$TEST_ROOT/$f" "$fake/$f" || _fail "cannot copy $f for the mutated CLI"
done
sed 's|^_sk_shadow_guard() {$|_sk_shadow_guard() { return 0;|' "$TEST_ROOT/shellkit" >"$fake/shellkit" ||
  _fail "cannot build the mutated CLI"
chmod +x "$fake/shellkit"
p5="$work/p5"
make_project "$p5"
out=$(bash "$fake/shellkit" vendor "$p5" 2>&1) && rc=0 || rc=$?
assert_eq 0 "$rc" "without the guard the fresh collision slips through"

echo "test_vendor_shadow: all cases passed"
