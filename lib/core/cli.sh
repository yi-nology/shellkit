#!/usr/bin/env bash
#
# 子命令框架。只做五件事：注册、分发、help 生成、选项解析、退出码。
# 新增命令 = 新建一个文件 + 一行 cli_cmd，不需要改分发器。

SK_CLI_NAMES=()
SK_CLI_DESCS=()
SK_CLI_USAGES=()
SK_CLI_GROUPS=()
SK_CLI_GROUP_TITLE=""

# cli_group TITLE —— 后续注册的命令归入该分组
cli_group() {
  SK_CLI_GROUP_TITLE=${1:-}
}

# _sk_is_cmd_name NAME —— 子命令名允许短横，因此不能复用变量名校验
_sk_is_cmd_name() {
  case "${1:-}" in
    '' | [0-9]* | *[!A-Za-z0-9_-]*) return 1 ;;
  esac
  return 0
}

# cli_cmd NAME DESC [USAGE]
cli_cmd() {
  local __name=${1:-} __desc=${2:-} __usage=${3:-}
  if ! _sk_is_cmd_name "$__name"; then
    log_error "$(_t 'invalid command name'): $__name"
    return "$SK_USAGE"
  fi
  if cli_has "$__name"; then
    log_error "$(_t 'duplicate command'): $__name"
    return "$SK_USAGE"
  fi
  SK_CLI_NAMES[${#SK_CLI_NAMES[@]}]="$__name"
  SK_CLI_DESCS[${#SK_CLI_DESCS[@]}]="$__desc"
  SK_CLI_USAGES[${#SK_CLI_USAGES[@]}]="$__usage"
  SK_CLI_GROUPS[${#SK_CLI_GROUPS[@]}]="$SK_CLI_GROUP_TITLE"
  return 0
}

# cli_has NAME
cli_has() {
  local __n=${1:-} __x
  if [ "${#SK_CLI_NAMES[@]}" -eq 0 ]; then
    return 1
  fi
  for __x in "${SK_CLI_NAMES[@]}"; do
    if [ "$__x" = "$__n" ]; then
      return 0
    fi
  done
  return 1
}

# _sk_cmd_fn NAME —— install-self 对应 cmd_install_self
_sk_cmd_fn() { printf 'cmd_%s' "$(printf '%s' "${1:-}" | tr '-' '_')"; }

# cli_usage_cmd NAME —— 打印单个子命令的用法行
cli_usage_cmd() {
  local __name=${1:-} __i=0 __prog
  __prog=${SK_PROG:-$(basename "$0")}
  while [ "$__i" -lt "${#SK_CLI_NAMES[@]}" ]; do
    if [ "${SK_CLI_NAMES[$__i]}" = "$__name" ]; then
      if [ -n "${SK_CLI_USAGES[$__i]}" ]; then
        printf '%s: %s %s\n' "$(_t 'Usage')" "$__prog" "${SK_CLI_USAGES[$__i]}"
      else
        printf '%s: %s %s\n' "$(_t 'Usage')" "$__prog" "$__name"
      fi
      return 0
    fi
    __i=$((__i + 1))
  done
  printf '%s: %s %s\n' "$(_t 'Usage')" "$__prog" "$__name"
  return 0
}

# cli_usage_global —— 打印总用法：命令按分组，选项固定五条
cli_usage_global() {
  local __i=0 __max=8 __len __grp="" __prog
  __prog=${SK_PROG:-$(basename "$0")}
  printf '%s: %s [<options>] <command> [<args>]\n' "$(_t 'Usage')" "$__prog"
  printf '\n%s:\n' "$(_t 'Commands')"
  while [ "$__i" -lt "${#SK_CLI_NAMES[@]}" ]; do
    __len=${#SK_CLI_NAMES[$__i]}
    if [ "$__len" -gt "$__max" ]; then
      __max=$__len
    fi
    __i=$((__i + 1))
  done
  __i=0
  while [ "$__i" -lt "${#SK_CLI_NAMES[@]}" ]; do
    if [ "${SK_CLI_GROUPS[$__i]}" != "$__grp" ]; then
      __grp=${SK_CLI_GROUPS[$__i]}
      if [ -n "$__grp" ]; then
        printf '\n  [%s]\n' "$__grp"
      fi
    fi
    printf '  %-*s  %s\n' "$__max" "${SK_CLI_NAMES[$__i]}" "${SK_CLI_DESCS[$__i]}"
    __i=$((__i + 1))
  done
  printf '\n%s:\n' "$(_t 'Options')"
  printf '  %-*s  %s\n' 16 "-h, --help" "$(_t 'show this help')"
  printf '  %-*s  %s\n' 16 "-V, --version" "$(_t 'show version')"
  printf '  %-*s  %s\n' 16 "--verbose" "$(_t 'enable debug output')"
  printf '  %-*s  %s\n' 16 "--no-color" "$(_t 'disable colored output')"
  printf '  %-*s  %s\n' 16 "-y, --yes" "$(_t 'non-interactive, use defaults')"
  return 0
}

_sk_suggest() {
  local __n=${1:-} __x __i=0 __hit=""
  while [ "$__i" -lt "${#SK_CLI_NAMES[@]}" ]; do
    __x=${SK_CLI_NAMES[$__i]}
    case "$__x" in
      "$__n"*)
        if [ -z "$__hit" ]; then
          __hit=$__x
        fi
        ;;
    esac
    __i=$((__i + 1))
  done
  if [ -n "$__hit" ]; then
    printf '%s: %s\n' "$(_t 'Did you mean')" "$__hit" >&2
  fi
  return 0
}

# cli_run ARGS...
cli_run() {
  local __name="" __fn="" __rc=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h | --help)
        cli_usage_global
        return 0
        ;;
      -V | --version)
        printf '%s\n' "${SK_VERSION:-dev}"
        return 0
        ;;
      --verbose)
        SHELLKIT_DEBUG=1
        export SHELLKIT_DEBUG
        shift
        ;;
      --no-color)
        SHELLKIT_COLOR=never
        # 由 lib/core/log.sh 的输出函数读取
        # shellcheck disable=SC2034
        SK_COLOR_ON=0
        export SHELLKIT_COLOR
        shift
        ;;
      -y | --yes)
        SHELLKIT_NONINTERACTIVE=1
        export SHELLKIT_NONINTERACTIVE
        shift
        ;;
      --)
        shift
        break
        ;;
      --?*)
        log_error "$(_t 'unknown option'): $1"
        cli_usage_global
        return "$SK_USAGE"
        ;;
      -?*)
        log_error "$(_t 'unknown option'): $1"
        cli_usage_global
        return "$SK_USAGE"
        ;;
      *)
        break
        ;;
    esac
  done

  if [ "$#" -eq 0 ]; then
    cli_usage_global
    return "$SK_USAGE"
  fi

  __name=$1
  shift
  if ! cli_has "$__name"; then
    log_error "$(_t 'no such command'): $__name"
    _sk_suggest "$__name"
    cli_usage_global
    return "$SK_USAGE"
  fi
  __fn=$(_sk_cmd_fn "$__name")
  if ! declare -F "$__fn" >/dev/null 2>&1; then
    log_error "$(_t 'command has no handler'): $__fn"
    return "$SK_ERR"
  fi

  # log_error 已经把消息写进 stderr 并记进 SK_ERRMSG，这里不需要再"补印"一次
  __rc=0
  "$__fn" "$@" || __rc=$?
  return "$__rc"
}

# ---------- 子命令选项解析 ----------
# 用法：
#   cli_opt_init
#   cli_opt VAR --long [-s] [takes_arg]
#   cli_opts "$@"
# 之后 VAR 为值（布尔为 1 或空），SK_OPTS_LEFT 为剩余位置参数。

SK_OPT_VARS=()
SK_OPT_LONGS=()
SK_OPT_SHORTS=()
SK_OPT_ARGS=()
SK_OPTS_LEFT=()

# cli_opt_init —— 清空选项注册表。不接受参数；变量默认值请自己先赋好
cli_opt_init() {
  SK_OPT_VARS=()
  SK_OPT_LONGS=()
  SK_OPT_SHORTS=()
  SK_OPT_ARGS=()
  SK_OPTS_LEFT=()
  return 0
}

# cli_opt VAR LONG [SHORT] [TAKES_ARG]
cli_opt() {
  local __var=${1:-} __long=${2:-} __short=${3:-} __arg=${4:-0}
  if ! _sk_is_name "$__var"; then
    log_error "$(_t 'invalid variable name'): $__var"
    return "$SK_USAGE"
  fi
  case "$__long" in
    --?*) ;;
    *)
      log_error "$(_t 'long option must start with --'): $__long"
      return "$SK_USAGE"
      ;;
  esac
  if [ -n "$__short" ]; then
    case "$__short" in
      -?) ;;
      *)
        log_error "$(_t 'short option must be a single dash and one letter'): $__short"
        return "$SK_USAGE"
        ;;
    esac
  fi
  # 重名注册必须当场拒绝：否则解析会静默只命中最后一个，另一个永远读不到
  if [ -n "$(_sk_opt_idx_long "$__long")" ]; then
    log_error "$(_t 'duplicate option'): $__long"
    return "$SK_USAGE"
  fi
  if [ -n "$__short" ] && [ -n "$(_sk_opt_idx_short "$__short")" ]; then
    log_error "$(_t 'duplicate option'): $__short"
    return "$SK_USAGE"
  fi
  SK_OPT_VARS[${#SK_OPT_VARS[@]}]="$__var"
  SK_OPT_LONGS[${#SK_OPT_LONGS[@]}]="$__long"
  SK_OPT_SHORTS[${#SK_OPT_SHORTS[@]}]="$__short"
  SK_OPT_ARGS[${#SK_OPT_ARGS[@]}]="$__arg"
  # 只在该变量尚未定义时初始化，保留调用方设好的默认值
  eval "if [ -z \"\${$__var+x}\" ]; then $__var=\"\"; fi"
  return 0
}

_sk_opt_idx_long() {
  local __want=${1:-} __i=0
  while [ "$__i" -lt "${#SK_OPT_LONGS[@]}" ]; do
    if [ "${SK_OPT_LONGS[$__i]}" = "$__want" ]; then
      printf '%s' "$__i"
      return 0
    fi
    __i=$((__i + 1))
  done
  return 0
}

_sk_opt_idx_short() {
  local __want=${1:-} __i=0
  while [ "$__i" -lt "${#SK_OPT_SHORTS[@]}" ]; do
    if [ "${SK_OPT_SHORTS[$__i]}" = "$__want" ]; then
      printf '%s' "$__i"
      return 0
    fi
    __i=$((__i + 1))
  done
  return 0
}

_sk_opt_set() {
  local __idx=${1:-} __val=${2:-} __target
  if [ -z "$__idx" ]; then
    return "$SK_USAGE"
  fi
  __target=${SK_OPT_VARS[$__idx]}
  printf -v "$__target" '%s' "$__val"
  return 0
}

# cli_opts NAME ARGS... —— 按 cli_opt 注册的规则解析子命令选项
cli_opts() {
  local __idx="" __opt=""
  SK_OPTS_LEFT=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --)
        shift
        while [ "$#" -gt 0 ]; do
          SK_OPTS_LEFT[${#SK_OPTS_LEFT[@]}]="$1"
          shift
        done
        break
        ;;
      --*=*)
        __idx=$(_sk_opt_idx_long "${1%%=*}")
        if [ -z "$__idx" ]; then
          log_error "$(_t 'unknown option'): ${1%%=*}"
          return "$SK_USAGE"
        fi
        # 布尔选项带 = 一律拒绝：把 "garbage" 塞进变量比直接报错难查得多
        if [ "${SK_OPT_ARGS[$__idx]}" != "1" ]; then
          log_error "$(_t 'option does not take a value'): ${1%%=*}"
          return "$SK_USAGE"
        fi
        _sk_opt_set "$__idx" "${1#*=}" || return $?
        shift
        ;;
      --?*)
        __opt=$1
        __idx=$(_sk_opt_idx_long "$__opt")
        if [ -z "$__idx" ]; then
          log_error "$(_t 'unknown option'): $1"
          return "$SK_USAGE"
        fi
        if [ "${SK_OPT_ARGS[$__idx]}" = "1" ]; then
          shift
          if [ "$#" -eq 0 ]; then
            log_error "$(_t 'option requires a value'): $__opt"
            return "$SK_USAGE"
          fi
          _sk_opt_set "$__idx" "$1" || return $?
        else
          _sk_opt_set "$__idx" "1" || return $?
        fi
        shift
        ;;
      -?*)
        __opt=$1
        __idx=$(_sk_opt_idx_short "$__opt")
        if [ -z "$__idx" ]; then
          log_error "$(_t 'unknown option'): $1"
          return "$SK_USAGE"
        fi
        if [ "${SK_OPT_ARGS[$__idx]}" = "1" ]; then
          shift
          if [ "$#" -eq 0 ]; then
            log_error "$(_t 'option requires a value'): $__opt"
            return "$SK_USAGE"
          fi
          _sk_opt_set "$__idx" "$1" || return $?
        else
          _sk_opt_set "$__idx" "1" || return $?
        fi
        shift
        ;;
      *)
        SK_OPTS_LEFT[${#SK_OPTS_LEFT[@]}]="$1"
        shift
        ;;
    esac
  done
  return 0
}
