#!/usr/bin/env bash
#
# shellkit 修复脚本 —— 不依赖已安装的 ShellKit 库。
#
# 什么时候需要它：安装（install-self）或 vendor 同步在「旧目录已经移走、
# 新目录还没就位」的瞬间被中断（SIGKILL / 断电 / 磁盘满），装好的 shellkit
# 就此起不来：恢复逻辑写在 CLI 里，而 CLI 自己就是那个起不来的东西。
# 备份不一定丢 —— 缺的是一个不依赖 CLI 的恢复入口。
#
# 这个脚本自己什么依赖都不带：只用 bash 内建 + 常见的 POSIX 工具。
# 它把中断留下的 .old / .new 残骸收拾干净，让 shellkit 重新可用。
#
#   curl -fsSL https://raw.githubusercontent.com/yi-nology/shellkit/main/repair.sh | bash
#   ./repair.sh --prefix ~/.local
#   ./repair.sh --project ./my-app --check
#
# 退出码：0 修好了（或本来就没事）/ 1 修不好（得重装）/ 2 用法错
set -u

PROG=repair.sh
SK_OK=0
SK_ERR=1
SK_USAGE=2

PREFIX=""
PROJECTS=""
CHECK=0
FAILED=0

say() { printf '%s\n' "$*" >&2; }
ok() { printf '[ OK ] %s\n' "$*" >&2; }
warn() { printf '[WARN] %s\n' "$*" >&2; }

die() {
  local __msg=$1 __code=${2:-$SK_ERR}
  printf '[FAIL] %s\n' "$__msg" >&2
  exit "$__code"
}

usage() {
  printf 'Usage: %s [options]\n' "$PROG" >&2
  cat >&2 <<'EOF'

  --prefix DIR     修 PREFIX 下的已安装副本（PREFIX/share/shellkit）
  --project DIR    修某个工程里的 vendor 副本（可重复）
  --check          只报告，不动手
  -h, --help       显示本帮助

不给 --prefix 时：脚本先从自己的位置反推 PREFIX
（装好的副本长这样：PREFIX/share/shellkit/repair.sh），
反推不出来就试默认位置（/usr/local 与 ~/.local）。
EOF
}

# _complete DIR —— 这个目录是不是一份完整的 shellkit 副本
#
# 判据用 lib/bootstrap.sh：CLI 与库都靠它启动，缺了它这份副本就是半份。
_complete() {
  [ -n "${1:-}" ] || return 1
  [ -f "$1/lib/bootstrap.sh" ]
}

# _slot_guard PATH —— 这个路径像不像一个可以动刀的 shellkit 槽位
#
# rm -rf 之前必须过这一关：路径拼错一次就是把用户整个家目录删掉。
# 认得的形状只有两种：<prefix>/share/shellkit 与 <project>/vendor/shellkit。
_slot_guard() {
  case "${1:-}" in
    */share/shellkit | */share/shellkit.old | */share/shellkit.new) return 0 ;;
    */vendor/shellkit | */vendor/.shellkit-old | */vendor/.shellkit-new) return 0 ;;
  esac
  return 1
}

# _rm PATH —— 删一个残骸目录（先过形状检查）
_rm() {
  local __p=${1:-}
  [ -n "$__p" ] || return 0
  if ! _slot_guard "$__p"; then
    warn "refusing to remove an unexpected path: $__p"
    FAILED=1
    return 1
  fi
  rm -rf "$__p" 2>/dev/null || {
    warn "failed to remove: $__p"
    FAILED=1
    return 1
  }
  return 0
}

# _repair LABEL MAIN OLD NEW —— 收拾一个槽位
#
# 状态只有三种：
#   1) 主副本完整 → 残骸是垃圾，清掉（CLI 的正常路径也是这么做的）
#   2) 主副本缺失或半份、旧副本完整 → 把旧副本挪回去，恢复启动能力
#   3) 主副本缺失或半份、旧副本也没了 → 修不好，只能重装
_repair() {
  local __label=$1 __main=$2 __old=$3 __new=$4
  local __main_ok=0 __old_ok=0

  if [ ! -e "$__main" ] && [ ! -e "$__old" ] && [ ! -e "$__new" ]; then
    return 0
  fi
  if _complete "$__main"; then
    __main_ok=1
  fi
  if _complete "$__old"; then
    __old_ok=1
  fi

  if [ "$__main_ok" = "1" ]; then
    if [ -e "$__old" ]; then
      if [ "$CHECK" = "1" ]; then
        warn "$__label: a leftover old copy is there: $__old"
      else
        _rm "$__old" && ok "$__label: removed the leftover old copy"
      fi
    fi
    if [ -e "$__new" ]; then
      if [ "$CHECK" = "1" ]; then
        warn "$__label: a leftover staging directory is there: $__new"
      else
        _rm "$__new" && ok "$__label: removed the leftover staging directory"
      fi
    fi
    return 0
  fi

  # 主副本不可用：只有旧副本能救它
  if [ "$__old_ok" = "1" ]; then
    if [ "$CHECK" = "1" ]; then
      warn "$__label: broken, but the old copy is complete — rerun without --check to restore"
      FAILED=1
      return 0
    fi
    _rm "$__main" || return 1
    if ! mv "$__old" "$__main"; then
      warn "$__label: failed to move the old copy back: $__old"
      FAILED=1
      return 1
    fi
    ok "$__label: restored from the old copy"
    if [ -e "$__new" ]; then
      _rm "$__new"
    fi
    return 0
  fi

  warn "$__label: nothing to restore from — reinstall shellkit"
  FAILED=1
  return 1
}

# _prefix_from_self —— 从脚本自己的位置反推 PREFIX
#
# 装好的副本长这样：PREFIX/share/shellkit/repair.sh；
# 被中断时旧副本还在：PREFIX/share/shellkit.old/repair.sh。
# 这条路径就是「只剩已安装副本、没有源码仓库」那台机器的入口。
_prefix_from_self() {
  local __self=${BASH_SOURCE[0]:-} __dir
  [ -n "$__self" ] || return 1
  __dir=$(cd -P "$(dirname "$__self")" 2>/dev/null && pwd) || return 1
  case "$__dir" in
    */share/shellkit | */share/shellkit.old | */share/shellkit.new)
      printf '%s' "${__dir%/share/shellkit*}"
      return 0
      ;;
  esac
  return 1
}

# _default_prefix —— 没有 --prefix 也没有自推位置时用哪儿
_default_prefix() {
  if [ -w /usr/local/bin ] || [ "$(id -u)" = "0" ]; then
    printf '%s' "/usr/local"
  else
    printf '%s/.local' "${HOME:-/tmp}"
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)
      shift
      [ $# -ge 1 ] || die "--prefix needs an argument" "$SK_USAGE"
      PREFIX=$1
      ;;
    --prefix=*)
      PREFIX=${1#*=}
      ;;
    --project)
      shift
      [ $# -ge 1 ] || die "--project needs an argument" "$SK_USAGE"
      PROJECTS="${PROJECTS}${1}
"
      ;;
    --project=*)
      PROJECTS="${PROJECTS}${1#*=}
"
      ;;
    --check)
      CHECK=1
      ;;
    -h | --help)
      usage
      exit "$SK_OK"
      ;;
    *)
      die "unknown option: $1" "$SK_USAGE"
      ;;
  esac
  shift
done

if [ -z "$PREFIX" ]; then
  PREFIX=$(_prefix_from_self) || PREFIX=""
fi
if [ -z "$PREFIX" ]; then
  PREFIX=$(_default_prefix)
fi
PREFIX="${PREFIX%/}"

say "shellkit repair"
if [ "$CHECK" = "1" ]; then
  say "mode: check only (nothing will be changed)"
fi

# ---- 已安装的副本 ----
_repair "installed copy ($PREFIX)" \
  "$PREFIX/share/shellkit" "$PREFIX/share/shellkit.old" "$PREFIX/share/shellkit.new"

# ---- 工程里的 vendor 副本 ----
while IFS= read -r __proj; do
  [ -n "$__proj" ] || continue
  _repair "vendored copy ($__proj)" \
    "$__proj/vendor/shellkit" "$__proj/vendor/.shellkit-old" "$__proj/vendor/.shellkit-new"
done <<EOF
$PROJECTS
EOF

if [ "$FAILED" != "0" ]; then
  die "some copies could not be restored — reinstall shellkit" "$SK_ERR"
fi

if _complete "$PREFIX/share/shellkit"; then
  ok "the installed copy is usable again: $PREFIX/bin/shellkit"
else
  say "no installed copy under $PREFIX — nothing to repair there"
fi
exit "$SK_OK"
