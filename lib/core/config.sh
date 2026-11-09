#!/usr/bin/env bash
#
# 配置文件读写。KEY=VALUE 格式。
# 关键性质：conf_get 只往 stdout 输出值，因此可以安全地嵌进 $(...) 。

SK_CONF_FILE=""

# conf_init FILE —— 载入 KEY=VALUE 配置文件；文件不存在不报错（当成空配置）
conf_init() {
  local __file=${1:-}
  if ! validate_not_empty "$__file"; then
    log_error "$(_t 'configuration file path is required')"
    return "$SK_USAGE"
  fi
  SK_CONF_FILE=$__file
  export SK_CONF_FILE
  return 0
}

# conf_file —— 当前生效的配置文件路径；未初始化时为空
conf_file() { printf '%s\n' "${SK_CONF_FILE:-}"; }

# conf_get KEY [DEFAULT] —— 只输出值；未初始化或无文件时返回默认值
conf_get() {
  local __key=${1:-} __default=${2:-} __file=${SK_CONF_FILE:-} __line __value="" __found=0
  if ! validate_key "$__key"; then
    printf '%s\n' "$__default"
    return "$SK_USAGE"
  fi
  if [ -n "$__file" ] && [ -f "$__file" ]; then
    while IFS= read -r __line || [ -n "$__line" ]; do
      case "$__line" in
        '' | '#'*) continue ;;
      esac
      case "$__line" in
        "${__key}="*)
          __value=${__line#*=}
          __found=1
          ;;
      esac
    done <"$__file"
  fi
  # 键存在但值为空时保留空串：把空值当成"没配过"会让显式置空退回默认值
  if [ "$__found" -eq 0 ]; then
    __value=$__default
  fi
  printf '%s\n' "$__value"
  return 0
}

# conf_has KEY —— 返回码 0/1
conf_has() {
  local __key=${1:-} __file=${SK_CONF_FILE:-} __line
  if ! validate_key "$__key"; then
    return "$SK_USAGE"
  fi
  if [ -z "$__file" ] || [ ! -f "$__file" ]; then
    return 1
  fi
  while IFS= read -r __line || [ -n "$__line" ]; do
    case "$__line" in
      "${__key}="*) return 0 ;;
    esac
  done <"$__file"
  return 1
}

# conf_get_any KEY [DEFAULT] —— 环境变量 > 配置文件 > 默认值
conf_get_any() {
  local __key=${1:-} __default=${2:-} __env=""
  if ! _sk_is_name "$__key"; then
    printf '%s\n' "$__default"
    return "$SK_USAGE"
  fi
  eval "__env=\${$__key-}"
  if [ -n "$__env" ]; then
    printf '%s\n' "$__env"
    return 0
  fi
  conf_get "$__key" "$__default"
}

# conf_set KEY VALUE —— 校验 + 值未变则跳过 + 原子写 + 600
conf_set() {
  local __key=${1:-} __value=${2:-} __file=${SK_CONF_FILE:-} __line __tmp __origin __replaced=0
  if ! validate_key "$__key"; then
    log_error "$(_t 'invalid configuration key'): $__key"
    return "$SK_USAGE"
  fi
  if ! validate_single_line "$__value"; then
    log_error "$(_t 'configuration value must be a single line'): $__key"
    return "$SK_USAGE"
  fi
  if [ -z "$__file" ]; then
    log_error "$(_t 'configuration file is not initialized')"
    return "$SK_PRECOND"
  fi
  __origin=$(conf_get "$__key")
  if conf_has "$__key" && [ "$__value" = "$__origin" ]; then
    return 0
  fi
  fs_ensure_dir "$(dirname "$__file")" "" || return 1
  __tmp=$(mktemp "$__file.tmp.XXXXXX") || return 1
  if [ -f "$__file" ]; then
    while IFS= read -r __line || [ -n "$__line" ]; do
      case "$__line" in
        "${__key}="*)
          if [ "$__replaced" = "0" ]; then
            printf '%s=%s\n' "$__key" "$__value"
            __replaced=1
          fi
          ;;
        *)
          printf '%s\n' "$__line"
          ;;
      esac
    done <"$__file" >"$__tmp"
  fi
  if [ "$__replaced" = "0" ]; then
    printf '%s=%s\n' "$__key" "$__value" >>"$__tmp"
  fi
  chmod 600 "$__tmp" 2>/dev/null || true
  if ! mv -f "$__tmp" "$__file"; then
    rm -f "$__tmp"
    return 1
  fi
  return 0
}

# conf_unset KEY —— 删掉一个键；幂等，键不存在也算成功
conf_unset() {
  local __key=${1:-} __file=${SK_CONF_FILE:-} __line __tmp
  if ! validate_key "$__key"; then
    return "$SK_USAGE"
  fi
  if ! conf_has "$__key"; then
    return 0
  fi
  __tmp=$(mktemp "$__file.tmp.XXXXXX") || return 1
  while IFS= read -r __line || [ -n "$__line" ]; do
    case "$__line" in
      "${__key}="*) ;;
      *) printf '%s\n' "$__line" ;;
    esac
  done <"$__file" >"$__tmp"
  chmod 600 "$__tmp" 2>/dev/null || true
  if ! mv -f "$__tmp" "$__file"; then
    rm -f "$__tmp"
    return 1
  fi
  return 0
}

# conf_disable KEY —— 把 KEY=VALUE 改成注释行，保留原值
conf_disable() {
  local __key=${1:-} __file=${SK_CONF_FILE:-} __line __tmp
  if ! validate_key "$__key"; then
    return "$SK_USAGE"
  fi
  if ! conf_has "$__key"; then
    return 0
  fi
  __tmp=$(mktemp "$__file.tmp.XXXXXX") || return 1
  while IFS= read -r __line || [ -n "$__line" ]; do
    case "$__line" in
      "${__key}="*) printf '# %s\n' "$__line" ;;
      *) printf '%s\n' "$__line" ;;
    esac
  done <"$__file" >"$__tmp"
  chmod 600 "$__tmp" 2>/dev/null || true
  if ! mv -f "$__tmp" "$__file"; then
    rm -f "$__tmp"
    return 1
  fi
  return 0
}

# conf_keys —— 逐行输出键名
conf_keys() {
  local __file=${SK_CONF_FILE:-} __line
  if [ -z "$__file" ] || [ ! -f "$__file" ]; then
    return 0
  fi
  while IFS= read -r __line || [ -n "$__line" ]; do
    case "$__line" in
      '' | '#'*) continue ;;
    esac
    case "$__line" in
      *=*) printf '%s\n' "${__line%%=*}" ;;
    esac
  done <"$__file"
  return 0
}
