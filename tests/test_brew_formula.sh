#!/usr/bin/env bash
#
# Homebrew formula 的判据（#164）。
#
# 背景：formula 的 install 列表里漏了 VERSION ⇒ 装出来的副本没有 VERSION
# ⇒ lib/bootstrap.sh 读不到版本 ⇒ SK_VERSION 退成 "dev"：
#   ① shellkit --version 报 dev（用户看不到真实版本）；
#   ② 更严重：shellkit skill install 拿 dev 当「期望版本」⇒ 期望版本成了
#      unknown ⇒ **任何一次 skill 安装/升级都被自己的版本检查挡住**
#      （连 --force 也救不了）—— 这正是「旧副本永远升不上」的形态。
#
# 为什么这条要有用例：formula 是**生成物**（tools/brew_formula.sh 生成），
# 仓里不存一份（钉死的 sha256 每个版本都变，留一份就是必然过期的副本）
# ⇒ 漏了什么没人看得见 ⇒ 只能靠用例盯着**生成器**。
#
# 三条判据：
#   1. formula 必须装 VERSION；
#   2. install 块必须**当场自检**（不能只靠 brew test —— 普通用户不会跑它）；
#   3. 根因复现（行为，不是文本）：缺 VERSION ⇒ --version 报 dev；
#      装上 VERSION ⇒ 报真版本。
# 外加一条变异自证：把生成器里的 VERSION 那行删掉 ⇒ 判据 1 必须红。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

GEN="$TEST_ROOT/tools/brew_formula.sh"
work="$TEST_TMP_ROOT/brew-case.$$"
mkdir -p "$work"
formula="$work/shellkit.rb"
sha=0000000000000000000000000000000000000000000000000000000000000000

bash "$GEN" --out "$formula" --version 9.9.9 --sha256 "$sha" >/dev/null 2>&1 ||
  _fail "the formula generator must produce a formula"
[ -f "$formula" ] || _fail "the formula generator must write the file"

body=$(cat "$formula")

# ── 判据 1：formula 必须装 VERSION ───────────────────────────────────────
assert_contains "$body" 'libexec.install "VERSION"' \
  "the formula must install VERSION (without it the CLI reports dev and the skill installer is blocked)"

# ── 判据 2：install 块必须当场自检 ───────────────────────────────────────
# 不能只靠 formula 末尾的 test 块：brew test 只有跑 brew test 或 CI 时才执行
# ⇒ 普通的 brew install 不跑 ⇒ 漏文件会一路溜到用户手里。
assert_contains "$body" 'raise' \
  "the install block must fail loudly when the installed copy is broken"
assert_contains "$body" 'ver_file.exist?' \
  "the install block must check that VERSION really landed"

# ── 判据 3：根因复现（行为，不是文本） ───────────────────────────────────
# 造一个「装好」的副本：有 lib/ 与 CLI ⇒ --version 读**旁边**的 VERSION。
fake="$work/libexec"
mkdir -p "$fake"
cp -R "$TEST_ROOT/lib" "$fake/" || _fail "cannot copy lib"
cp "$TEST_ROOT/shellkit" "$fake/" || _fail "cannot copy the CLI"

got=$(bash "$fake/shellkit" --version 2>/dev/null | head -1)
assert_eq "dev" "$got" "without VERSION the CLI must report dev (that is the bug)"

printf '9.9.9\n' >"$fake/VERSION"
got=$(bash "$fake/shellkit" --version 2>/dev/null | head -1)
assert_eq "9.9.9" "$got" "with VERSION the CLI must report the real version"

# install-self 那条路本来就装 VERSION（#164 说 brew 这条路单独坏了）
# —— 别把那条好路也弄丢。
if ! grep -q 'AGENTS.md VERSION shellkit' "$TEST_ROOT/shellkit"; then
  _fail "install-self must keep installing VERSION"
fi

# ── 变异自证：把生成器里的 VERSION 那行删掉 ⇒ 判据 1 必须红 ─────────────
# 变异的是**生成器的副本**，不是仓里的那个 —— 万一中途失败，仓里不留残骸。
mutgen="$work/brew_formula_mut.sh"
awk '{ if ($0 ~ /libexec\.install "VERSION"/) next; print }' "$GEN" >"$mutgen" ||
  _fail "cannot mutate the generator copy"
if cmp -s "$mutgen" "$GEN"; then
  _fail "the mutation must actually change the generator"
fi
mut="$work/mutated.rb"
bash "$mutgen" --out "$mut" --version 9.9.9 --sha256 "$sha" >/dev/null 2>&1 ||
  _fail "the mutated generator must still produce a formula"
if ( assert_contains "$(cat "$mut")" 'libexec.install "VERSION"' "mutation" ) >/dev/null 2>&1; then
  _fail "the check must go red on a formula that does not install VERSION"
fi

exit 0
