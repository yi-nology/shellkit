#!/usr/bin/env bash
#
# 覆盖率工具的「绿灯凭据」：同一棵树的未插桩副本验过一次之后，第二遍不必重跑。
#
# 为什么要有这道用例：
#   CI 的覆盖率 job 把函数级与分支级**各跑一遍**，而两遍里的第一遍
#   （未插桩副本必须全绿）查的是同一棵树、同一套测试 ⇒ 纯重复（每遍约 7 分钟，
#   而这个 job 是整条流水线的关键路径）。
#
# 凭据的两条性质，缺一不可：
#   ① **内容寻址**：树变了凭据自动失效 ⇒ 不会拿旧的绿灯糊弄新的树；
#   ② **方向受限**：只有「这一轮跑的套件 ⊆ 当初验过的那套」才允许复用
#      （跑得更多 ⇒ 当初的绿覆盖不到 ⇒ 必须重验）。
#
# 判据用**套件运行计数器**（迷你套件每跑一次追加一行），不是断日志文案 ——
# 文案能被改，计数不会。
#
# 断言纪律：断完整文案不断单词；临时目录名只用编号；SHELLKIT_LANG=en 由
# test_helper.sh 统一设置。

set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

TOOL="$TEST_ROOT/tools/coverage.sh"
COV_TIMEOUT=120

# 迷你树：两臂函数 + 一条绿套件。套件每跑一次往计数器文件追加一行。
#
# 树里放一个 tests/test_meta_gates.sh：分支级模式会把它挪走（排除清单），
# 函数级模式不会 ⇒ 两级的排除清单不同 ⇒ 「方向受限」这条性质才测得到。
_cov_tree() {
  local dir=$1
  mkdir -p "$dir/lib/core" "$dir/tests" || return 1

  cat >"$dir/lib/core/i18n.sh" <<'I18N'
#!/usr/bin/env bash
# 假 i18n：__cov_hit 的注入落点。
I18N

  cat >"$dir/lib/core/mini.sh" <<'MINI'
#!/usr/bin/env bash
mini_alpha() {
  if [ -n "${1:-}" ]; then
    printf 'a\n'
  else
    printf 'b\n'
  fi
}
MINI

  cat >"$dir/tests/test_meta_gates.sh" <<'META'
#!/usr/bin/env bash
# 只为了让两级的排除清单不同（分支级会把它挪走）。
exit 0
META

  cat >"$dir/tests/run.sh" <<'SUITE'
#!/usr/bin/env bash
# 迷你套件：恒绿，但每跑一次追加一行计数（判据用）。
set -u
if [ -n "${COV_COUNTER:-}" ]; then
  printf 'run\n' >>"$COV_COUNTER"
fi
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/core/mini.sh"
mini_alpha x >/dev/null
SUITE
  return 0
}

# _cov_run OUTVAR ARGS... —— 跑覆盖率工具，退出码写进 OUTVAR
_cov_run() {
  local __outvar=$1
  shift
  local __rc=0
  _cov_out="$TEST_TMP_ROOT/cov-green.stdout"
  _cov_err="$TEST_TMP_ROOT/cov-green.stderr"
  if command -v timeout >/dev/null 2>&1; then
    timeout "$COV_TIMEOUT" bash "$TOOL" "$@" >"$_cov_out" 2>"$_cov_err" </dev/null || __rc=$?
  else
    bash "$TOOL" "$@" >"$_cov_out" 2>"$_cov_err" </dev/null || __rc=$?
  fi
  printf -v "$__outvar" '%s' "$__rc"
  COV_STDERR="$_cov_err"
  return 0
}

# _count FILE —— 计数器文件里有多少行
_count() {
  local __f=${1:-}
  [ -f "$__f" ] || {
    printf '0'
    return 0
  }
  wc -l <"$__f" 2>/dev/null | tr -d ' '
}

d=$(tmpdir) || _fail "cannot create tmpdir"

# 凭据写在 TMPDIR 下 ⇒ 必须给这一轮用例一个**专属**的 TMPDIR：
# 否则别的运行留下的凭据会让「第一次跑」变成「复用」⇒ 用例随机变红。
cov_tmp="$d/tmp"
mkdir -p "$cov_tmp" || _fail "cannot create the tmpdir"
export TMPDIR="$cov_tmp"

counter="$d/count.txt"
export COV_COUNTER="$counter"

_cov_tree "$d/tree" || _fail "cannot build the mini tree"
root="$d/tree"
base="$d/base"

# -------------------------------------------------------------------------
# CASE 1：第一遍 —— 没有凭据 ⇒ 未插桩副本必须真的跑一遍
# -------------------------------------------------------------------------
_cov_run rc --branch --root "$root" --suite 'bash tests/run.sh' --guards '' --baseline "$base"
err=$(cat "$COV_STDERR")
assert_contains "$err" "running the suite on the untouched copy" \
  "the first run must verify the untouched copy"
assert_not_contains "$err" "reusing the green result" \
  "the first run must not reuse a stamp that does not exist yet"
# 一遍工具 = 未插桩一遍 + 已插桩一遍 = 2 次套件运行
assert_eq "2" "$(_count "$counter")" \
  "the first run must execute the suite twice (untouched copy + instrumented copy)"

# -------------------------------------------------------------------------
# CASE 2：同一棵树再跑一遍 ⇒ 未插桩那遍被复用（套件只跑 1 次）
# -------------------------------------------------------------------------
_cov_run rc --branch --root "$root" --suite 'bash tests/run.sh' --guards '' --baseline "$base"
err=$(cat "$COV_STDERR")
assert_contains "$err" "reusing the green result of the untouched copy" \
  "the second run on the same tree must reuse the green result"
assert_not_contains "$err" "running the suite on the untouched copy" \
  "the second run on the same tree must not run the untouched copy again"
assert_eq "3" "$(_count "$counter")" \
  "the second run must execute the suite only once (the instrumented copy)"

# -------------------------------------------------------------------------
# CASE 3：树变了 ⇒ 凭据自动失效 ⇒ 未插桩那遍必须重跑
#
# 这是凭据的**核心性质**：内容寻址。树变了还拿旧绿灯 ⇒ 覆盖率结论建立在
# 没验过的树上 ⇒ 假绿。
# -------------------------------------------------------------------------
printf '# touched\n' >>"$root/lib/core/mini.sh"
_cov_run rc --branch --root "$root" --suite 'bash tests/run.sh' --guards '' --baseline "$base"
err=$(cat "$COV_STDERR")
assert_contains "$err" "running the suite on the untouched copy" \
  "a changed tree must invalidate the stamp and run the untouched copy again"
assert_eq "5" "$(_count "$counter")" \
  "after the tree changed the suite must run twice again"

# -------------------------------------------------------------------------
# CASE 4：树没变 ⇒ 凭据继续有效
# -------------------------------------------------------------------------
sleep 1
_cov_run rc --branch --root "$root" --suite 'bash tests/run.sh' --guards '' --baseline "$base"
err=$(cat "$COV_STDERR")
assert_contains "$err" "reusing the green result of the untouched copy" \
  "a stamp for an unchanged tree must be reused"
assert_not_contains "$err" "running the suite on the untouched copy" \
  "a stamp for an unchanged tree must not run the untouched copy again"
assert_eq "6" "$(_count "$counter")" \
  "an unchanged tree must execute the suite only once"

# -------------------------------------------------------------------------
# CASE 5：凭据过期 ⇒ 必须重跑（免得「套件早就坏了」被一份陈凭据永久掩盖）
# -------------------------------------------------------------------------
# 取第一个 stamp：不用 `find | head`（head 命中即退，会把 find 打死成 141），
# 改成纯 bash 取第一行。
__stamps=$(find "$cov_tmp" -name '*.stamp' -type f 2>/dev/null)
stamp="${__stamps%%$'\n'*}"
[ -n "$stamp" ] || _fail "the green stamp was not written"
printf '%s\t%s\t%s\n' "$(cut -f1 "$stamp")" "$(cut -f2 "$stamp")" "$(($(date +%s) - 7200))" >"$stamp"
_cov_run rc --branch --root "$root" --suite 'bash tests/run.sh' --guards '' --baseline "$base"
err=$(cat "$COV_STDERR")
assert_contains "$err" "running the suite on the untouched copy" \
  "an expired stamp must not be reused"
assert_eq "8" "$(_count "$counter")" \
  "an expired stamp must make the suite run twice again"

# -------------------------------------------------------------------------
# CASE 6：方向受限 —— 跑得**更多**的那一套不能复用跑得更少的那一套的绿灯
#
# 分支级模式排除的用例更多 ⇒ 它跑得更少 ⇒ 函数级（跑得更多）验过的绿
# **不能**反过来给分支级用之外的场景用；反过来，分支级的绿也不能给
# 函数级用（函数级跑得更多 ⇒ 覆盖不到）。
# 这一条锁的是「绿灯只能在覆盖得到的方向上传递」。
# -------------------------------------------------------------------------
_cov_run rc --root "$root" --suite 'bash tests/run.sh' --guards '' --baseline "$base"
err=$(cat "$COV_STDERR")
assert_contains "$err" "running the suite on the untouched copy" \
  "the function level run must not reuse the branch level stamp (it runs more tests)"
assert_eq "10" "$(_count "$counter")" \
  "the function level run must execute the suite twice"

# -------------------------------------------------------------------------
# CASE 7：CI 的真实顺序 —— 函数级先跑、分支级后跑 ⇒ 分支级必须复用
#
# 这就是生产路径（make coverage → make coverage-branch）：分支级排除的用例
# 比函数级多 ⇒ 跑得更少 ⇒ 函数级的绿覆盖得到 ⇒ 允许复用 ⇒ 省一整遍套件。
# -------------------------------------------------------------------------
_cov_run rc --branch --root "$root" --suite 'bash tests/run.sh' --guards '' --baseline "$base"
err=$(cat "$COV_STDERR")
assert_contains "$err" "reusing the green result of the untouched copy" \
  "the branch level run must reuse the function level green result"
assert_not_contains "$err" "running the suite on the untouched copy" \
  "the branch level run must not run the untouched copy again"
assert_eq "11" "$(_count "$counter")" \
  "the branch level run must execute the suite only once"

echo "ok - coverage green stamp"
