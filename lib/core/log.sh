#!/usr/bin/env bash
#
# 日志。全部写 stderr —— 这是全库最重要的约定：
# stdout 只留给数据，所以 v=$(conf_get KEY) 永远不会混进 [INFO]。
#
# 三个可选开关，全部只加不改：不设时的行为与从前逐字一致。
#
#   SHELLKIT_LOG_LEVEL   debug|info|warn|error，默认 info。低于该级别的消息不输出；
#                        log_ok 与 log_section 算 info 级。比较时大小写不敏感。
#   SHELLKIT_LOG_FORMAT  text|json，默认 text。json 模式一条消息一行紧凑 JSON：
#                        {"ts":"2026-11-09T12:34:56+08:00","level":"INFO","msg":"..."}
#   SHELLKIT_LOG_FILE    非空时把日志同时追加到该文件（文件不存在就创建）。

_sk_color_on() {
  case "${SHELLKIT_COLOR:-auto}" in
    always) return 0 ;;
    never) return 1 ;;
    *) [ -t 2 ] ;;
  esac
}

if _sk_color_on; then
  SK_COLOR_ON=1
else
  SK_COLOR_ON=0
fi

# _sk_log_threshold OUTVAR —— 把 SHELLKIT_LOG_LEVEL 折成能比大小的数值
# debug=10 info=20 warn=30 error=40。没设或认不出来一律按 info（20）。
_sk_log_threshold() {
  local __outvar=$1
  case "${SHELLKIT_LOG_LEVEL:-}" in
    [dD][eE][bB][uU][gG]) printf -v "$__outvar" '%s' 10 ;;
    [iI][nN][fF][oO]) printf -v "$__outvar" '%s' 20 ;;
    [wW][aA][rR][nN]) printf -v "$__outvar" '%s' 30 ;;
    [eE][rR][rR][oO][rR]) printf -v "$__outvar" '%s' 40 ;;
    *) printf -v "$__outvar" '%s' 20 ;;
  esac
}

# _sk_log_enabled RANK —— 这条消息现在要不要输出
# debug 有个例外：SHELLKIT_DEBUG=1 单独就能打开（老行为），跟级别无关。
_sk_log_enabled() {
  local __rank=$1 __thr
  _sk_log_threshold __thr
  if [ "$__rank" -ge "$__thr" ]; then
    return 0
  fi
  if [ "$__rank" = "10" ] && [ "${SHELLKIT_DEBUG:-0}" = "1" ]; then
    return 0
  fi
  return 1
}

# _sk_log_is_json —— 输出格式是不是 json
_sk_log_is_json() {
  case "${SHELLKIT_LOG_FORMAT:-}" in
    [jJ][sS][oO][nN]) return 0 ;;
    *) return 1 ;;
  esac
}

# _sk_log_timestamp OUTVAR —— 本地时间 ISO8601，带时区偏移（+08:00）
# %z 在 macOS 与 Linux 上都给 +0800，这里补上中间的冒号。
_sk_log_timestamp() {
  local __outvar=$1 __raw __len __tail
  __raw=$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null) || __raw=''
  if [ -z "$__raw" ]; then
    printf -v "$__outvar" '%s' ''
    return 0
  fi
  __len=${#__raw}
  if [ "$__len" -ge 5 ]; then
    __tail=${__raw:$((__len - 5)):5}
    case "$__tail" in
      [+-][0-9][0-9][0-9][0-9])
        printf -v "$__outvar" '%s' "${__raw:0:$((__len - 5))}${__tail:0:3}:${__tail:3:2}"
        return 0
        ;;
    esac
  fi
  printf -v "$__outvar" '%s' "$__raw"
}

# _sk_json_escape OUTVAR STR —— 把 STR 变成可以放进 JSON 字符串的内容
# 转义 \ " \b \f \n \r \t；剩下的控制字符转成 \u00XX。
# UTF-8 多字节原样保留（JSON 允许直接写非 ASCII）。
_sk_json_escape() {
  local __outvar=$1 __s=$2 __rest __c __code
  __s=${__s//\\/\\\\}
  __s=${__s//\"/\\\"}
  __s=${__s//$'\b'/\\b}
  __s=${__s//$'\f'/\\f}
  __s=${__s//$'\n'/\\n}
  __s=${__s//$'\r'/\\r}
  __s=${__s//$'\t'/\\t}
  case "$__s" in
    *[[:cntrl:]]*)
      __rest=$__s
      __s=''
      while [ -n "$__rest" ]; do
        __c=${__rest:0:1}
        __rest=${__rest:1}
        case "$__c" in
          [[:cntrl:]])
            printf -v __code '%d' "'$__c"
            printf -v __code '\\u%04x' "$__code"
            __s="${__s}${__code}"
            ;;
          *) __s="${__s}${__c}" ;;
        esac
      done
      ;;
  esac
  printf -v "$__outvar" '%s' "$__s"
}

# _sk_log_json_line OUTVAR LEVEL MSG —— 拼出一行紧凑 JSON
# 一条日志一行：msg 里的换行已经转义过，不会把这一行打断。
_sk_log_json_line() {
  local __outvar=$1 __level=$2 __msg=$3 __esc __ts
  _sk_json_escape __esc "$__msg"
  _sk_log_timestamp __ts
  printf -v "$__outvar" '%s' "{\"ts\":\"$__ts\",\"level\":\"$__level\",\"msg\":\"$__esc\"}"
}

# _sk_log_file_error PATH —— 日志文件打不开时只在 stderr 报一次
# 同一个路径只报一次，免得刷屏；之后继续往 stderr 写，只是不再写文件。
# 报错走 _t（用户可见文案），但不走 log_error —— 那会再写一次文件，成环。
_sk_log_file_error() {
  local __path=$1
  case "${SK_LOG_FILE_ERRORS:-}" in
    *"
${__path}
"*) return 0 ;;
  esac
  SK_LOG_FILE_ERRORS="${SK_LOG_FILE_ERRORS:-}
${__path}"
  if _sk_log_is_json; then
    __err_line=""
    _sk_log_json_line __err_line ERROR "$(_t 'no write permission'): ${__path}"
    printf '%s\n' "$__err_line" >&2
  else
    printf '[ERROR] %s: %s\n' "$(_t 'no write permission')" "$__path" >&2
  fi
  return 0
}

# _sk_log_file_write LINE —— 把一行追加到 SHELLKIT_LOG_FILE
# 语义：SHELLKIT_LOG_FILE 为空就什么都不做；文件不存在就创建；
# 父目录不存在或没有写权限时只报错，不抛异常、不改退出码 —— 日志写不进去
# 不该让调用方的脚本崩掉。
_sk_log_file_write() {
  local __line=$1 __file=${SHELLKIT_LOG_FILE:-}
  [ -n "$__file" ] || return 0
  if ! printf '%s\n' "$__line" 2>/dev/null >>"$__file"; then
    _sk_log_file_error "$__file"
  fi
  return 0
}

# _sk_log LEVEL RANK MSG... —— 所有 log_* 的共同出口
# LEVEL 是 JSON 里的 level 字段（INFO/OK/WARN/ERROR/DEBUG）；
# RANK 是比较级别用的数值（10/20/30/40）。
_sk_log() {
  local __level=$1 __rank=$2
  shift 2
  local __msg="$*" __label __color __line

  if ! _sk_log_enabled "$__rank"; then
    return 0
  fi

  if _sk_log_is_json; then
    _sk_log_json_line __line "$__level" "$__msg"
    printf '%s\n' "$__line" >&2
    _sk_log_file_write "$__line"
    return 0
  fi

  case "$__level" in
    OK)
      __label=' OK '
      __color='1;32'
      ;;
    WARN)
      __label=WARN
      __color='1;33'
      ;;
    ERROR)
      __label=ERROR
      __color='1;31'
      ;;
    DEBUG)
      __label=DEBUG
      __color='1;36'
      ;;
    *)
      __label=INFO
      __color=''
      ;;
  esac
  if [ "${SK_COLOR_ON:-0}" = "1" ] && [ -n "$__color" ]; then
    printf '\033[%sm[%s]\033[0m %s\n' "$__color" "$__label" "$__msg" >&2
  else
    printf '[%s] %s\n' "$__label" "$__msg" >&2
  fi
  # 写进文件的是不带颜色的纯文本行
  _sk_log_file_write "[${__label}] ${__msg}"
  return 0
}

# log_info MSG... —— 普通信息
log_info() { _sk_log INFO 20 "$@"; }

# log_ok MSG... —— 成功；单独用 " OK " 是为了和四字母级别对齐
log_ok() { _sk_log OK 20 "$@"; }

# log_warn MSG... —— 警告，不中断
log_warn() { _sk_log WARN 30 "$@"; }

# log_error MSG... —— 输出错误（stderr），并把最后一条错误记进 SK_ERRMSG
log_error() {
  # 公开变量：供调用方在退出前读取最后一条错误
  # shellcheck disable=SC2034
  SK_ERRMSG="$*"
  _sk_log ERROR 40 "$@"
}

# log_debug MSG... —— 仅在 SHELLKIT_DEBUG=1 或 SHELLKIT_LOG_LEVEL=debug 时输出
log_debug() { _sk_log DEBUG 10 "$@"; }

# log_section TITLE —— 分段标题，带前导空行
# json 模式下什么都不输出：JSON 行是给采集器消费的，标题没有 level 语义，
# 混进去会破坏「一行一条记录」的约定。文本模式保持原样。
log_section() {
  if _sk_log_is_json; then
    return 0
  fi
  if ! _sk_log_enabled 20; then
    return 0
  fi
  if [ "${SK_COLOR_ON:-0}" = "1" ]; then
    printf '\n\033[1;33m==> %s\033[0m\n' "$*" >&2
  else
    printf '\n==> %s\n' "$*" >&2
  fi
  _sk_log_file_write "==> $*"
  return 0
}
