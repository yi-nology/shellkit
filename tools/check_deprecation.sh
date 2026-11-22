#!/usr/bin/env bash
#
# 门禁：弃用承诺必须兑现（docs/COMPATIBILITY.md 的「弃用流程」）。
#
# 承诺三步：① 源码写 @deprecated <版本> 并同步 docs/MIGRATING.md；
# ② 保留至少一个已发布的 minor；③ 然后才允许删除。
# COMPATIBILITY 过去自认「靠迁移表与评审守，没有自动判据」—— 没有执法的
# 承诺随时可能被无声违反。本门禁查四件事：
#   a) 每个 @deprecated 注解版本合法，且 tools/deprecated.txt 有同版本台账；
#   b) 被弃用的函数在 docs/MIGRATING.md 里提得到（反引号包着的函数名）；
#   c) 台账登记了移除的：源码里必须真的没了、弃用到移除满一个 minor、
#      移除版本不晚于当前 VERSION、基线里留有记录、迁移表里提得到；
#   d) 反向：基线里有、源码里没有的函数，台账必须登记了移除版本。
#
# 空状态（零注解、台账只有头注释）是**合法**的：门禁已武装、没有目标。
# 判据能力由 tests/test_deprecation_gate.sh 双向 + 变异自证证明。
#
#   bash tools/check_deprecation.sh    # 0 通过；5 不合格；2 用法错
set -u

ROOT="${SHELLKIT_CHECK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)}"
MIGRATING="$ROOT/docs/MIGRATING.md"
BASELINE="$ROOT/tools/api_baseline.txt"
LEDGER="$ROOT/tools/deprecated.txt"
VER_FILE="$ROOT/VERSION"
SEMVER="$ROOT/tools/ver_semver.sh"

_bad=0
_fail() {
  printf 'deprecation-check: %s\n' "$1" >&2
  _bad=1
}

case "${1:-}" in
  "") ;;
  -h | --help)
    printf 'usage: bash %s\n' "${0##*/}"
    exit 0
    ;;
  *)
    printf 'deprecation-check: unknown option: %s\n' "$1" >&2
    exit 2
    ;;
esac

for __req in "$MIGRATING" "$BASELINE" "$LEDGER" "$VER_FILE" "$SEMVER"; do
  if [ ! -f "$__req" ]; then
    printf 'deprecation-check: missing %s\n' "$__req" >&2
    exit 5
  fi
done

# shellcheck source=tools/ver_semver.sh
. "$SEMVER"

_cur="$(tr -d '[:space:]' <"$VER_FILE")"
if ! printf '%s\n' "$_cur" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$'; then
  printf 'deprecation-check: VERSION is not x.y.z: <%s>\n' "$_cur" >&2
  exit 5
fi

# _is_ver V —— x.y.z（可带预发布后缀）
_is_ver() {
  printf '%s\n' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$'
}

# _ver_major / _ver_minor —— 取主 / 次版本号（纯数字）
_ver_major() {
  printf '%s' "${1%%.*}"
}
_ver_minor() {
  __mv=${1#*.}
  printf '%s' "${__mv%%.*}"
}

# _window_ok DEP CUR —— 从 DEP 到 CUR 至少满一个 minor
# （同 major 要求 minor 差 ≥1；major 更大也算过；major 更小不算）
_window_ok() {
  __dj=$(_ver_major "$1")
  __dm=$(_ver_minor "$1")
  __cj=$(_ver_major "$2")
  __cm=$(_ver_minor "$2")
  if [ "$__cj" -gt "$__dj" ]; then return 0; fi
  if [ "$__cj" -lt "$__dj" ]; then return 1; fi
  [ $((__cm - __dm)) -ge 1 ]
}

# _src_has FN —— 函数还在 lib/core 源码里吗
_src_has() {
  grep -Eq "^$1\(\)[ \t]*\{" "$ROOT"/lib/core/*.sh 2>/dev/null
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/shellkit-deprecation.XXXXXX")" || exit 3
trap 'rm -rf "$WORK"' EXIT
ANN="$WORK/ann.tsv"
BASE_NAMES="$WORK/base.list"

# ---- 源码里的 @deprecated 注解：函数名<TAB>版本 ----
# 注解行与定义之间允许夹说明注释；隔了非注释内容 ⇒ 悬空（单独报）。
awk '
  /^# @deprecated[ \t]+[0-9]/ { ver = $3; pending = 1; next }
  /^[A-Za-z_][A-Za-z0-9_]*\(\)[ \t]*\{/ && pending {
    name = $0
    sub(/\(.*/, "", name)
    print name "\t" ver
    pending = 0
    next
  }
  pending && /^#/ { next }
  pending { pending = 0 }
  END { if (pending) print "__DANGLING__\t" ver }
' "$ROOT"/lib/core/*.sh >"$ANN" || exit 5

# ---- 规则 a/b：注解侧 ----
while IFS=$'\t' read -r __fn __ver; do
  [ -n "$__fn" ] || continue
  if [ "$__fn" = "__DANGLING__" ]; then
    _fail "@deprecated 注解后面没有紧邻的函数定义（悬空注解）：$__ver"
    continue
  fi
  if ! _is_ver "$__ver"; then
    _fail "$__fn 的 @deprecated 版本不是 x.y.z: <$__ver>"
    continue
  fi
  if _ver_gt "$__ver" "$_cur"; then
    _fail "${__fn} 的弃用版本 $__ver 晚于当前 VERSION ${_cur}（不能声明未来的弃用）"
  fi
  __led="$(awk -F'\t' -v f="$__fn" '$1==f{print $2}' "$LEDGER")"
  if [ -z "$__led" ]; then
    _fail "$__fn 有 @deprecated $__ver 注解，但 tools/deprecated.txt 没有它的台账行"
  elif [ "$__led" != "$__ver" ]; then
    _fail "$__fn 的注解版本 $__ver 与台账 $__led 不一致"
  fi
  if ! grep -qF "\`$__fn\`" "$MIGRATING"; then
    _fail "$__fn 有 @deprecated 注解，但 docs/MIGRATING.md 里没有反引号包着的 $__fn"
  fi
done <"$ANN"

# ---- 规则 a/c：台账侧 ----
while IFS=$'\t' read -r __fn __dep __rm; do
  case "$__fn" in '' | '#'*) continue ;; esac
  if ! _is_ver "$__dep"; then
    _fail "台账里 $__fn 的弃用版本不是 x.y.z: <${__dep:-}>"
    continue
  fi
  if _ver_gt "$__dep" "$_cur"; then
    _fail "台账里 $__fn 的弃用版本 $__dep 晚于当前 VERSION $_cur"
    continue
  fi
  if _src_has "$__fn"; then
    # 还在源码里：注解必须在（不许静默取消弃用），移除列必须是 -
    if ! awk -F'\t' -v f="$__fn" '$1==f{found=1} END{exit !found}' "$ANN"; then
      _fail "台账登记了 $__fn 被弃用，但源码里没有 @deprecated 注解（弃用被静默取消？）"
    fi
    if [ -n "${__rm:-}" ] && [ "$__rm" != "-" ]; then
      _fail "台账说 ${__fn} 已移除（${__rm}），但源码里还有它的定义"
    fi
    continue
  fi
  # 已从源码删除：移除版本必须齐全且满窗口
  if [ -z "${__rm:-}" ] || [ "$__rm" = "-" ]; then
    _fail "台账里的 $__fn 已从源码删除，但第三列没有登记移除版本"
    continue
  fi
  if ! _is_ver "$__rm"; then
    _fail "台账里 $__fn 的移除版本不是 x.y.z: <$__rm>"
    continue
  fi
  if _ver_gt "$__rm" "$_cur"; then
    _fail "台账里 $__fn 的移除版本 $__rm 晚于当前 VERSION $_cur"
  fi
  if ! _window_ok "$__dep" "$__rm"; then
    _fail "台账里 $__fn 从弃用 $__dep 到移除 $__rm 不满一个 minor（COMPATIBILITY 承诺的窗口）"
  fi
  if ! awk -F'\t' -v f="$__fn" '$1==f{found=1} END{exit !found}' "$BASELINE"; then
    _fail "台账说 $__fn 被移除了，但 tools/api_baseline.txt 里没有它的记录（重生成基线？）"
  fi
  if ! grep -qF "\`$__fn\`" "$MIGRATING"; then
    _fail "台账里的 $__fn 在 docs/MIGRATING.md 里提不到（移除必须写迁移表）"
  fi
done <"$LEDGER"

# ---- 规则 d：反向 —— 基线里有、源码里没有 ⇒ 台账必须登记了移除 ----
awk -F'\t' '/^[A-Za-z_][A-Za-z0-9_]*\t/ {print $1}' "$BASELINE" >"$BASE_NAMES" || true
while IFS= read -r __fn; do
  [ -n "$__fn" ] || continue
  if _src_has "$__fn"; then continue; fi
  __rm="$(awk -F'\t' -v f="$__fn" '$1==f{print $3}' "$LEDGER")"
  if [ -z "$__rm" ] || [ "$__rm" = "-" ]; then
    _fail "$__fn 在基线里但源码里已经没有了 —— tools/deprecated.txt 必须登记它的移除版本"
  fi
done <"$BASE_NAMES"

if [ "$_bad" -ne 0 ]; then
  printf 'deprecation-check: FAILED\n' >&2
  exit 5
fi
printf 'deprecation-check: ok\n'
exit 0
