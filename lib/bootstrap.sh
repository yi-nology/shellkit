#!/usr/bin/env bash
#
# shellkit 唯一入口。source 本文件即可获得全部核心函数。
#
# 全库强制约定：
#   1. stdout 只给数据，日志一律 stderr
#   2. 出参用 printf -v，函数不直接改调用方变量
#   3. 取值优先级：显式参数 > 环境变量 > 配置文件 > 默认值
#   4. 写文件必原子
#   5. 本库不改变调用方的 shell 选项，也不改变 cwd

SHELLKIT_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"
export SHELLKIT_HOME

SHELLKIT_DEBUG="${SHELLKIT_DEBUG:-0}"
SHELLKIT_COLOR="${SHELLKIT_COLOR:-auto}"
SHELLKIT_NONINTERACTIVE="${SHELLKIT_NONINTERACTIVE:-0}"
SHELLKIT_TMP_KEEP="${SHELLKIT_TMP_KEEP:-0}"
export SHELLKIT_DEBUG SHELLKIT_COLOR SHELLKIT_NONINTERACTIVE SHELLKIT_TMP_KEEP

# 最近一次 log_error 的内容，供调用方在退出前读取
# 跨模块读写的公开变量
# shellcheck disable=SC2034
SK_ERRMSG=""

SK_OK=0
SK_ERR=1
SK_USAGE=2
SK_PRECOND=3
SK_NET=4
SK_VERIFY=5
export SK_OK SK_ERR SK_USAGE SK_PRECOND SK_NET SK_VERIFY

export TEXTDOMAIN="${TEXTDOMAIN:-shellkit}"
export TEXTDOMAINDIR="${TEXTDOMAINDIR:-$SHELLKIT_HOME/locale}"

if [ -r "$SHELLKIT_HOME/VERSION" ]; then
  SK_VERSION=$(tr -d '[:space:]' <"$SHELLKIT_HOME/VERSION")
else
  SK_VERSION="dev"
fi
export SK_VERSION

# 模块加载顺序来自 lib/modules.txt —— 顺序只有一处，不再两处各写一份。
# 少写一个模块不是灾难：tools/check_module_order.sh 会查出来。
_sk_module_list() {
  local __f="$SHELLKIT_HOME/lib/modules.txt" __line
  [ -r "$__f" ] || return 1
  while IFS= read -r __line || [ -n "$__line" ]; do
    case "$__line" in
      '' | '#'*) continue ;;
    esac
    printf '%s\n' "$__line"
  done <"$__f"
}

for _sk_module in $(_sk_module_list); do
  if [ ! -f "$SHELLKIT_HOME/lib/core/${_sk_module}.sh" ]; then
    printf 'shellkit: module listed in modules.txt is missing: %s\n' "${_sk_module}" >&2
    return 1 2>/dev/null || exit 1
  fi
  if ! . "$SHELLKIT_HOME/lib/core/${_sk_module}.sh"; then
    printf 'shellkit: failed to load module: %s\n' "${_sk_module}" >&2
    return 1 2>/dev/null || exit 1
  fi
done
unset _sk_module
