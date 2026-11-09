#!/usr/bin/env bash
#
# 脚手架：模板变量、渲染、生成物清单、钩子。
#
# 这一层为什么存在：shellkit new 以前只能一次性把模板铺出来，交付之后就没有
# 办法跟着 shellkit 一起演进 —— 想升级只能删了重来，或者手工 diff。
# 有了清单（.shellkit-manifest）就能做增量更新：模板改了什么，
# 只更新没被你改过的文件；你改过的文件留着并告警。
#
# 模板变量：模板文件里写 {{KEY}}，值来自 template.config 的默认值、
# 命令行 --set KEY=VALUE、或交互提问。未声明的 {{KEY}} 原样保留。

# 模板变量表。格式是 KEY=VALUE 的多行文本；跨函数传状态用公开变量。
SK_SCAFFOLD_VARS=""

# manifest 解析出来的标量（公开变量，scaffold_manifest_read 之后可读）
SK_MANIFEST_VERSION=""
SK_MANIFEST_TEMPLATE_VERSION=""
SK_MANIFEST_NAME=""
SK_MANIFEST_COMMANDS=""

# _sk_scaffold_store_set KEY VALUE —— 在变量表里写一个键
_sk_scaffold_store_set() {
  local __key=$1 __value=$2 __out="" __line __rest="$SK_SCAFFOLD_VARS" __found=0
  while [ -n "$__rest" ]; do
    __line=${__rest%%$'\n'*}
    if [ "$__line" = "$__rest" ]; then
      __rest=""
    else
      __rest=${__rest#*$'\n'}
    fi
    case "$__line" in
      "") continue ;;
      "${__key}="*)
        printf -v __out '%s%s=%s\n' "$__out" "$__key" "$__value"
        __found=1
        ;;
      *) printf -v __out '%s%s\n' "$__out" "$__line" ;;
    esac
  done
  if [ "$__found" -eq 0 ]; then
    printf -v __out '%s%s=%s\n' "$__out" "$__key" "$__value"
  fi
  SK_SCAFFOLD_VARS="$__out"
}

# _sk_scaffold_store_get KEY DEFAULT —— 读变量表里的一个键
_sk_scaffold_store_get() {
  local __key=$1 __default=$2 __line __rest="$SK_SCAFFOLD_VARS" __found=0
  while [ -n "$__rest" ]; do
    __line=${__rest%%$'\n'*}
    if [ "$__line" = "$__rest" ]; then
      __rest=""
    else
      __rest=${__rest#*$'\n'}
    fi
    case "$__line" in
      "${__key}="*)
        printf '%s\n' "${__line#*=}"
        __found=1
        break
        ;;
    esac
  done
  if [ "$__found" -eq 0 ]; then
    printf '%s\n' "$__default"
  fi
  return 0
}

# scaffold_vars_set KEY VALUE —— 设一个模板变量
scaffold_vars_set() {
  local __key=${1:-} __value=${2:-}
  if ! validate_key "$__key"; then
    log_error "$(_t 'invalid template variable name'): $__key"
    return "$SK_USAGE"
  fi
  _sk_scaffold_store_set "$__key" "$__value"
  return 0
}

# scaffold_vars_get KEY [DEFAULT] —— 读一个模板变量；未设置时给默认值
scaffold_vars_get() {
  local __key=${1:-} __default=${2:-}
  if ! validate_key "$__key"; then
    printf '%s\n' "$__default"
    return "$SK_USAGE"
  fi
  _sk_scaffold_store_get "$__key" "$__default"
}

# scaffold_vars_list —— 逐行输出 KEY=VALUE
scaffold_vars_list() {
  local __line __rest="$SK_SCAFFOLD_VARS"
  while [ -n "$__rest" ]; do
    __line=${__rest%%$'\n'*}
    if [ "$__line" = "$__rest" ]; then
      __rest=""
    else
      __rest=${__rest#*$'\n'}
    fi
    [ -n "$__line" ] && printf '%s\n' "$__line"
  done
  return 0
}

# scaffold_config_load FILE —— 从 template.config 载入模板变量
#
# 格式与 conf 模块一致：KEY=VALUE，# 开头是注释。
# 值为空是合法的（表示「这个变量默认没有值，生成时问用户」）。
scaffold_config_load() {
  local __file=${1:-} __line __key __value
  _sk_need_args "$#" 1 "scaffold_config_load FILE" || return $?
  if [ ! -f "$__file" ]; then
    log_error "$(_t 'template config not found'): $__file"
    return "$SK_PRECOND"
  fi
  while IFS= read -r __line || [ -n "$__line" ]; do
    case "$__line" in
      '' | '#'*) continue ;;
    esac
    case "$__line" in
      *=*) ;;
      *)
        log_warn "$(_t 'skipped a malformed template variable'): $__line"
        continue
        ;;
    esac
    __key=${__line%%=*}
    __value=${__line#*=}
    if ! validate_key "$__key"; then
      log_warn "$(_t 'skipped an invalid template variable name'): $__key"
      continue
    fi
    _sk_scaffold_store_set "$__key" "$__value"
  done <"$__file"
  return 0
}

# _sk_sed_repl_escape TEXT —— 转义 sed 替换侧的元字符
# 顺序要紧：先转义反斜杠，再转义 & 与分隔符 |。
_sk_sed_repl_escape() {
  local __s=${1:-}
  __s=${__s//\\/\\\\}
  __s=${__s//&/\\&}
  __s=${__s//|/\\|}
  printf '%s' "$__s"
}

# scaffold_render SRC DST —— 用当前模板变量渲染文件
#
# 未声明的 {{KEY}} 原样保留（这样模板里的示例占位符不会被误伤）。
# 返回非 0 表示没写出来，调用方必须判。
scaffold_render() {
  local __src=${1:-} __dst=${2:-} __sedfile __rc=0 __line __key __value __esc
  _sk_need_args "$#" 2 "scaffold_render SRC DST" || return $?
  if [ ! -f "$__src" ]; then
    log_error "$(_t 'template is missing'): $__src"
    return 1
  fi
  __sedfile=$(mktemp "${TMPDIR:-/tmp}/shellkit-scaffold.XXXXXX") || return 1
  while IFS= read -r __line || [ -n "$__line" ]; do
    case "$__line" in
      *=*) ;;
      *) continue ;;
    esac
    __key=${__line%%=*}
    __value=${__line#*=}
    __esc=$(_sk_sed_repl_escape "$__value")
    printf 's|{{%s}}|%s|g\n' "$__key" "$__esc" >>"$__sedfile" || __rc=1
  done <<EOF
$SK_SCAFFOLD_VARS
EOF
  if [ "$__rc" -ne 0 ]; then
    rm -f "$__sedfile"
    return 1
  fi
  if ! sed -f "$__sedfile" "$__src" >"$__dst"; then
    rm -f "$__sedfile"
    return 1
  fi
  rm -f "$__sedfile"
  return 0
}

# scaffold_manifest_write DIR NAME COMDS TEMPLATE_VERSION FILELIST
#
# 写 DIR/.shellkit-manifest。FILELIST 是换行分隔的相对路径（模板自有的文件），
# 每个文件记一个 sha256 —— 升级时靠它判断「这个文件用户动过没有」。
scaffold_manifest_write() {
  local __dir=${1:-} __name=${2:-} __cmds=${3:-} __tver=${4:-} __files=${5:-}
  local __out="$__dir/.shellkit-manifest" __tmp __line __rel __sum
  _sk_need_args "$#" 4 "scaffold_manifest_write DIR NAME COMDS TEMPLATE_VERSION [FILELIST]" || return $?
  fs_ensure_dir "$__dir" 755 || return 1
  __tmp=$(mktemp "$__out.tmp.XXXXXX") || return 1
  {
    printf '# shellkit manifest v1\n'
    printf '# 生成时的模板版本与文件指纹。shellkit upgrade 用它判断哪些文件能安全覆盖。\n'
    printf 'version=%s\n' "${SK_VERSION:-dev}"
    printf 'template_version=%s\n' "$__tver"
    printf 'name=%s\n' "$__name"
    printf 'commands=%s\n' "$__cmds"
    while IFS= read -r __line || [ -n "$__line" ]; do
      [ -n "$__line" ] || continue
      printf '@var %s\n' "$__line"
    done <<EOF
$SK_SCAFFOLD_VARS
EOF
    while IFS= read -r __rel || [ -n "$__rel" ]; do
      [ -n "$__rel" ] || continue
      if [ -f "$__dir/$__rel" ]; then
        __sum=$(os_sha256 "$__dir/$__rel" 2>/dev/null) || __sum=""
      else
        __sum=""
      fi
      printf '@file %s %s\n' "$__rel" "$__sum"
    done <<EOF
$__files
EOF
  } >"$__tmp" || {
    rm -f "$__tmp"
    return 1
  }
  if ! mv -f "$__tmp" "$__out"; then
    rm -f "$__tmp"
    return 1
  fi
  return 0
}

# scaffold_manifest_read DIR —— 读 DIR/.shellkit-manifest
#
# 标量进 SK_MANIFEST_* 公开变量，@var 条目进模板变量表。
scaffold_manifest_read() {
  local __dir=${1:-} __file __line __rest
  _sk_need_args "$#" 1 "scaffold_manifest_read DIR" || return $?
  __file="$__dir/.shellkit-manifest"
  if [ ! -f "$__file" ]; then
    log_error "$(_t 'no shellkit manifest in'): $__dir"
    return "$SK_PRECOND"
  fi
  SK_MANIFEST_VERSION=""
  SK_MANIFEST_TEMPLATE_VERSION=""
  SK_MANIFEST_NAME=""
  SK_MANIFEST_COMMANDS=""
  while IFS= read -r __line || [ -n "$__line" ]; do
    case "$__line" in
      '') continue ;;
      '#'*) continue ;;
      '@var '*)
        __rest=${__line#@var }
        case "$__rest" in
          *=*) _sk_scaffold_store_set "${__rest%%=*}" "${__rest#*=}" ;;
        esac
        continue
        ;;
      '@file '*) continue ;;
      *=*)
        __rest=${__line#*=}
        case "$__line" in
          version=*) SK_MANIFEST_VERSION="$__rest" ;;
          template_version=*) SK_MANIFEST_TEMPLATE_VERSION="$__rest" ;;
          name=*) SK_MANIFEST_NAME="$__rest" ;;
          commands=*) SK_MANIFEST_COMMANDS="$__rest" ;;
        esac
        continue
        ;;
    esac
  done <"$__file"
  return 0
}

# scaffold_manifest_get KEY —— 读 manifest 里的一个标量
scaffold_manifest_get() {
  local __key=${1:-}
  case "$__key" in
    version) printf '%s\n' "$SK_MANIFEST_VERSION" ;;
    template_version) printf '%s\n' "$SK_MANIFEST_TEMPLATE_VERSION" ;;
    name) printf '%s\n' "$SK_MANIFEST_NAME" ;;
    commands) printf '%s\n' "$SK_MANIFEST_COMMANDS" ;;
    *)
      log_error "$(_t 'unknown manifest key'): $__key"
      return "$SK_USAGE"
      ;;
  esac
  return 0
}

# scaffold_manifest_list_files —— 逐行输出模板自有的文件（相对路径）
scaffold_manifest_list_files() {
  local __dir=${1:-} __file __line __rel
  _sk_need_args "$#" 1 "scaffold_manifest_list_files DIR" || return $?
  __file="$__dir/.shellkit-manifest"
  [ -f "$__file" ] || return 1
  while IFS= read -r __line || [ -n "$__line" ]; do
    case "$__line" in
      '@file '*)
        __rel=${__line#@file }
        printf '%s\n' "${__rel%% *}"
        ;;
    esac
  done <"$__file"
  return 0
}

# scaffold_manifest_file_sum DIR RELPATH —— 读 manifest 里记的某个文件的 sha256
scaffold_manifest_file_sum() {
  local __dir=${1:-} __rel=${2:-} __file __line
  _sk_need_args "$#" 2 "scaffold_manifest_file_sum DIR RELPATH" || return $?
  __file="$__dir/.shellkit-manifest"
  [ -f "$__file" ] || return 1
  while IFS= read -r __line || [ -n "$__line" ]; do
    case "$__line" in
      "@file $__rel "*)
        printf '%s\n' "${__line#@file $__rel }"
        return 0
        ;;
    esac
  done <"$__file"
  return 1
}

# scaffold_run_hook FILE PROJECT_DIR —— 跑一个模板钩子
#
# 钩子是模板目录里的可执行脚本（template.hooks.d/pre、template.hooks.d/post）。
# 环境变量里会带上：SHELLKIT_PROJECT_DIR / SHELLKIT_PROJECT_NAME /
# SHELLKIT_PROJECT_COMMANDS / SHELLKIT_TEMPLATE_VERSION，以及每个模板变量。
# 钩子不存在就跳过；不可执行就跳过并告警（不因为钩子没设执行位就让生成失败）。
scaffold_run_hook() {
  local __file=${1:-} __dir=${2:-} __line __key __value
  _sk_need_args "$#" 2 "scaffold_run_hook FILE PROJECT_DIR" || return $?
  if [ ! -f "$__file" ]; then
    return 0
  fi
  if [ ! -x "$__file" ]; then
    log_warn "$(_t 'hook is not executable, skipped'): $__file"
    return 0
  fi
  SHELLKIT_PROJECT_DIR="$__dir"
  export SHELLKIT_PROJECT_DIR
  # 钩子约定的几个变量：项目名、命令清单、模板版本
  SHELLKIT_PROJECT_NAME=$(_sk_scaffold_store_get PROJECT_NAME "")
  SHELLKIT_PROJECT_COMMANDS=$(_sk_scaffold_store_get PROJECT_COMMANDS "")
  SHELLKIT_TEMPLATE_VERSION=$(_sk_scaffold_store_get TEMPLATE_VERSION "")
  export SHELLKIT_PROJECT_NAME SHELLKIT_PROJECT_COMMANDS SHELLKIT_TEMPLATE_VERSION
  while IFS= read -r __line || [ -n "$__line" ]; do
    case "$__line" in
      *=*) ;;
      *) continue ;;
    esac
    __key=${__line%%=*}
    __value=${__line#*=}
    case "$__key" in
      '' | *[!A-Za-z0-9_]*) continue ;;
    esac
    export "$__key=$__value"
  done <<EOF
$SK_SCAFFOLD_VARS
EOF
  if ! "$__file"; then
    log_error "$(_t 'hook failed'): $__file"
    return "$SK_ERR"
  fi
  return 0
}
