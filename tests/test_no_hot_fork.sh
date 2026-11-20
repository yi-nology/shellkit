#!/usr/bin/env bash
#
# 热路径不许起外部进程（2026-11-20 实测后新增）。
#
# 为什么要有这条：macOS 上进程创建比 Linux 贵一个量级（实测 fork+exec：
# macOS ≈43ms/次 vs Linux ≈2~3ms/次，机器一忙再翻几倍）⇒ 同一份代码，
# 套件在 macOS 上跑 22.6 分钟、Linux 上 7.8 分钟（2.9 倍）。逐文件量下来，
# 慢的那几个文件都是被 **fork 次数** 堆出来的，不是算法慢：
#   test_upgrade_crash.sh   6153 次 fork（其中 2054 次来自 _t 的域名后缀转换）
#   test_coverage_branch.sh 7039 次 fork（其中 5779 次是 grep）
#   test_skill.sh           2329 次 fork
#
# 判据口径用 **fork 次数**，不用耗时：次数与机器快慢无关 ⇒ 门槛在任何机器上
# 都一样；慢机器只会被次数放大，不会把门槛也放大。
#
# 三条判据：
#   1. 装载库（. lib/bootstrap.sh）不许起外部进程；
#   2. _t（取译文）在没有 gettext 时不许起外部进程；
#   3. 域名 -> 函数名后缀必须与改前的 tr 实现**逐字一致**（快路只绕开 fork，
#      不许改语义）。
#
# 覆盖边界（如实说明）：判据靠「把命令换成计数包装器」数进程，因此只数
# **被盯住的那批命令**。这批 = 库里出现过的命令名 + 一小批标准命令；
# 新增一个外部命令必然写在库里 ⇒ 一定落在集合里 ⇒ 判据不会因为「新命令
# 不在名单里」而漏判。数不到的是包装器自己与 shell 内建（内建不起进程，
# 本来也不该算）。
#
# 全文不依赖 python3；用 awk 做行级替换（变异自证要改坏一份库副本）。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

BIN=$(tmpdir)
SHIM="$BIN/spawn_wrapper"
LOG="$BIN/spawn.log"

# ── 计数包装器：每个被盯住的命令调用记一笔，然后真的执行它 ─────────────────
cat >"$SHIM" <<'SHIM_EOF'
#!/bin/sh
name=${0##*/}
printf '%s\n' "$name" >> "$SPAWN_LOG"
real=$(PATH="$SPAWN_REAL_PATH" command -v "$name" 2>/dev/null || true)
[ -n "$real" ] || exit 127
exec "$real" "$@"
SHIM_EOF
chmod 755 "$SHIM"

# ── 被盯住的命令集合 ───────────────────────────────────────────────────
# 库源码里出现过的命令名（命令替换里的第一个词）+ 一小批标准命令。
# 「从库里抽」是关键：将来库里新增一个外部命令，它必然出现在源码里
# ⇒ 一定被盯住 ⇒ 这条判据不会因为「新命令不在名单里」而漏判。
watched_from_source() {
  awk '
    {
      rest = $0
      while (match(rest, /\$\([^)]*\)/)) {
        seg = substr(rest, RSTART + 2, RLENGTH - 3)
        split(seg, parts, /[[:space:]]+/)
        if (parts[1] != "") print parts[1]
        rest = substr(rest, RSTART + RLENGTH)
      }
      while (match(rest, /`[^`]*`/)) {
        seg = substr(rest, RSTART + 1, RLENGTH - 2)
        split(seg, parts, /[[:space:]]+/)
        if (parts[1] != "") print parts[1]
        rest = substr(rest, RSTART + RLENGTH)
      }
    }
  ' "$TEST_ROOT"/lib/*.sh "$TEST_ROOT"/lib/core/*.sh "$TEST_ROOT"/shellkit 2>/dev/null | LC_ALL=C sort -u
}

{
  watched_from_source
  printf '%s\n' cp mv rm mkdir rmdir chmod chown ln find sort sed awk grep git tar tr \
    dirname basename cut wc head tail xargs cat touch stat date mktemp uname du \
    gettext env expr tee readlink install cmp diff seq sleep id whoami hostname realpath
} | LC_ALL=C awk '/^[A-Za-z0-9][A-Za-z0-9._+-]*$/ {print}' | LC_ALL=C sort -u >"$BIN/watch.list"

# 装包装器：command -v 与 read 都是内建（不 fork），ln 一次建完所有软链。
: >"$BIN/wrap.list"
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  command -v "$cmd" >"$BIN/one" 2>/dev/null || true
  p=""
  read -r p <"$BIN/one" || true
  case "$p" in
    /*) printf '%s\n' "$cmd" >>"$BIN/wrap.list" ;;
  esac
done <"$BIN/watch.list"

# 装包装器：每个被盯住的命令一个软链，目标写相对路径（spawn_wrapper）——
# 换机器/换挂载路径都不会断成死链。
#
# 为什么逐个 ln：BSD 的 ln 没有 GNU 那个「目标 + 目录 + 多个源」的形式
# （macOS 上会把每个源建成指向自己的死链 ⇒ 包装器当场失效 ⇒ 判据空转）。
# 真正是外部命令的只有 ~50 个 ⇒ 50 次 ln 是可接受的代价。
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  [ "$cmd" = "spawn_wrapper" ] && continue
  ln -sf spawn_wrapper "$BIN/$cmd" 2>/dev/null || true
done <"$BIN/wrap.list"

# ── 包装器自检（关键）──────────────────────────────────────────────────
# 包装器没装上 ⇒ 后面两条判据全是空转 ⇒ 「恒真」的假绿。
# 所以先证明包装器真的会记：跑一个被盯住的命令，日志里必须出现它。
# 同时核对「建的软链数 == 要盯的命令数」：少建了要当场发现，不能带着残缺
# 的包装器去判「零调用」。
wrap_count=0
read -r first_wrap <"$BIN/wrap.list" || true
if [ -n "$first_wrap" ]; then
  : >"$LOG"
  # ⚠️ SPAWN_REAL_PATH 必须取**改 PATH 之前**的原始 PATH：
  # 同一个命令里的多个赋值是按顺序生效的（PATH=... 先落，$PATH 的展开就已经
  # 是新值了）⇒ 包装器会把自己当成真命令 ⇒ 无限递归 ⇒ 判据挂死。
  real_path=$PATH
  (
    SPAWN_LOG="$LOG" SPAWN_REAL_PATH="$real_path" PATH="$BIN:$PATH" \
      "$first_wrap" </dev/null >/dev/null 2>&1
  ) || true
  assert_contains "$(cat "$LOG")" "$first_wrap" \
    "the spawn wrapper must record the commands it intercepts"
  wrap_count=$(find "$BIN" -maxdepth 1 -type l 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "$(wc -l <"$BIN/wrap.list" | tr -d ' ')" "$wrap_count" \
    "every watched command must get its own wrapper"
fi

# ── 探针 ───────────────────────────────────────────────────────────────
# run_probe PROBE LOG [LIBROOT] —— 在计数包装器下跑探针
run_probe() {
  local probe=$1 out=$2 libroot=${3:-$TEST_ROOT}
  : >"$out"
  SPAWN_LOG="$out" SPAWN_REAL_PATH="$PATH" PATH="$BIN:$PATH" SK_LIB_ROOT="$libroot" \
    /bin/bash "$probe" </dev/null >/dev/null 2>&1
}

# 探针 1：只装载库（日志在装载前就清空 ⇒ 装载期的调用全被记下）
cat >"$BIN/probe_load.sh" <<'EOF'
set -u
. "$SK_LIB_ROOT/lib/bootstrap.sh"
EOF

# 探针 2：装载后连调 5 次后缀转换
cat >"$BIN/probe_suffix.sh" <<'EOF'
set -u
. "$SK_LIB_ROOT/lib/bootstrap.sh"
: > "$SPAWN_LOG"
i=0
while [ "$i" -lt 5 ]; do
  _sk_i18n_fn_suffix "shellkit" >/dev/null
  i=$((i + 1))
done
EOF

# 探针 3：装载后连调 5 次 _t（没有 gettext 时不许起进程）
cat >"$BIN/probe_t.sh" <<'EOF'
set -u
. "$SK_LIB_ROOT/lib/bootstrap.sh"
SK_GETTEXT=
export SHELLKIT_LANG=en
: > "$SPAWN_LOG"
i=0
while [ "$i" -lt 5 ]; do
  _t "hello" >/dev/null
  i=$((i + 1))
done
EOF

# ── 判据一：装载库不许起外部进程 ───────────────────────────────────────
run_probe "$BIN/probe_load.sh" "$LOG"
spawns=$(cat "$LOG")
assert_eq "" "$spawns" "loading the library must not fork an external command"

# ── 判据二：_t 在没有 gettext 时不许起外部进程 ─────────────────────────
run_probe "$BIN/probe_t.sh" "$LOG"
spawns=$(cat "$LOG")
assert_eq "" "$spawns" "_t must not fork an external command when gettext is absent"

# ── 判据三：后缀转换必须与改前的 tr 实现逐字一致 ───────────────────────
# 改前：printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_' '_'
# 改后：纯 bash 的恒等快路 + 同样的 tr 兜底。
# 断的是「输出逐字相同」，不是「差不多」——换 locale 也必须相同。
domains=(shellkit My-Domain.v2 UPPER_case9 "a b/c" "" x 9 _x "é" "Ω" "aéb" "a-b_c.d" "Ab C" "中文")
expected=()

# compute_expected —— 用旧实现算一遍期望值（按当前 locale）
compute_expected() {
  local d
  expected=()
  for d in "${domains[@]}"; do
    expected[${#expected[@]}]=$(printf '%s' "$d" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_' '_')
  done
}

# check_suffix_equivalence LIBROOT —— 与期望值逐字一致则返回 0
check_suffix_equivalence() {
  local libroot=$1 i d got
  (
    . "$libroot/lib/core/i18n.sh"
    i=0
    for d in "${domains[@]}"; do
      got=$(_sk_i18n_fn_suffix "$d")
      if [ "$got" != "${expected[$i]}" ]; then
        printf 'mismatch: domain=<%s> old=<%s> new=<%s>\n' "$d" "${expected[$i]}" "$got" >&2
        exit 1
      fi
      i=$((i + 1))
    done
  )
}

for loc in C __ambient__; do
  if [ "$loc" = "C" ]; then
    export LC_ALL=C
  else
    unset LC_ALL
  fi
  compute_expected
  if ! check_suffix_equivalence "$TEST_ROOT"; then
    _fail "the domain suffix must stay byte-identical to the previous tr-based implementation"
  fi
done
unset LC_ALL

# _assert_mutated FILE ORIG —— 变异必须真的改到了文件，且还是合法 bash
#
# 为什么要有这道：变异没生效 ⇒ 判据当然抓不住它 ⇒ 「变异自证」变成一句空话
# （本轮真踩过：mawk 不认正则里的 \{ ⇒ awk 报错 ⇒ 文件原封不动 ⇒ 断言报
# 「没抓到」，看起来像判据有问题，其实是变异根本没发生）。
_assert_mutated() {
  local f=$1 orig=$2
  if cmp -s "$f" "$orig"; then
    _fail "the mutation must actually change the source: $f"
  fi
  bash -n "$f" || _fail "the mutated source must still be valid bash: $f"
}

# ── 变异自证一：去掉恒等快路（永远走 tr）⇒ 判据二必须报出来 ──────────
# 改的是一份**库副本**：真库不动，判据自己先证明「它抓得住回退」。
COPY="$BIN/copy1"
mkdir -p "$COPY"
cp -Rp "$TEST_ROOT/lib" "$TEST_ROOT/locale" "$COPY/" || _fail "copy failed"
awk '
  /^  case "\$__d" in$/ { skip = 1; next }
  skip && /^  esac$/ { skip = 0; next }
  skip { next }
  { print }
' "$COPY/lib/core/i18n.sh" >"$COPY/lib/core/i18n.new" && mv "$COPY/lib/core/i18n.new" "$COPY/lib/core/i18n.sh"
_assert_mutated "$COPY/lib/core/i18n.sh" "$TEST_ROOT/lib/core/i18n.sh"

run_probe "$BIN/probe_t.sh" "$LOG" "$COPY"
mut=$(cat "$LOG")
assert_ne "" "$mut" "a suffix implementation that forks again must break the check"

# ── 变异自证二：平台探测换回 uname ⇒ 判据一必须报出来 ─────────────────
COPY2="$BIN/copy2"
mkdir -p "$COPY2"
cp -Rp "$TEST_ROOT/lib" "$TEST_ROOT/locale" "$COPY2/" || _fail "copy failed"
# ⚠️ 正则里不要用 \{ / \}：mawk（Debian/CI 的 awk）不认它 ⇒ awk 直接报错
# ⇒ 文件原封不动 ⇒ 变异没发生。改成不含花括号的等价写法。
awk '
  /^  case .*OSTYPE/ { print "  case \"\$(uname -s 2>/dev/null)\" in"; next }
  /^  case .*MACHTYPE/ { print "  case \"\$(uname -m 2>/dev/null)\" in"; next }
  { print }
' "$COPY2/lib/core/os.sh" >"$COPY2/lib/core/os.new" && mv "$COPY2/lib/core/os.new" "$COPY2/lib/core/os.sh"
_assert_mutated "$COPY2/lib/core/os.sh" "$TEST_ROOT/lib/core/os.sh"

run_probe "$BIN/probe_load.sh" "$LOG" "$COPY2"
mut=$(cat "$LOG")
assert_ne "" "$mut" "a platform probe that forks uname again must break the check"

# ── 变异自证三：把快路与慢路对调 ⇒ 差分必须报不一致 ───────────────────
COPY3="$BIN/copy3"
mkdir -p "$COPY3"
cp -Rp "$TEST_ROOT/lib" "$TEST_ROOT/locale" "$COPY3/" || _fail "copy failed"
awk '
  /^    \*\[!a-z0-9_\]\*\) ;;$/ { print "    *[!a-z0-9_]*) printf '\''%s'\'' \"\$__d\"; return 0 ;;"; next }
  /^    \*\) printf '\''%s'\'' \"\$__d\"; return 0 ;;$/ { print "    *) ;;"; next }
  { print }
' "$COPY3/lib/core/i18n.sh" >"$COPY3/lib/core/i18n.new" && mv "$COPY3/lib/core/i18n.new" "$COPY3/lib/core/i18n.sh"
_assert_mutated "$COPY3/lib/core/i18n.sh" "$TEST_ROOT/lib/core/i18n.sh"

compute_expected
if check_suffix_equivalence "$COPY3"; then
  _fail "the differential check must catch a broken identity fast path"
fi

exit 0
