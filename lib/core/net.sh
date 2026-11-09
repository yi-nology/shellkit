#!/usr/bin/env bash
# 网络：下载（带校验与镜像回退）与就绪探测。

# net_sha256 FILE —— 文件的 sha256；两种工具都没有时返回 1
# @exitcode 0 成功（stdout 输出校验和）
# @exitcode 2 参数错
# @exitcode 1 算不出校验和
net_sha256() {
  _sk_need_args "$#" 1 "net_sha256 FILE" || return $?
  os_sha256 "$1"
}

# net_verify FILE SHA256 —— 校验文件的 sha256；对不上返回 SK_VERIFY(5)
# @exitcode 0 校验通过
# @exitcode 2 参数错
# @exitcode 5 校验和不匹配，或算不出校验和
net_verify() {
  local __file=${1:-} __expect=${2:-} __actual
  _sk_need_args "$#" 2 "net_verify FILE SHA256" || return $?
  if [ -z "$__expect" ]; then
    log_error "$(_t 'no checksum configured for'): $__file"
    return "$SK_VERIFY"
  fi
  __actual=$(net_sha256 "$__file") || {
    log_error "$(_t 'cannot compute checksum for'): $__file"
    return "$SK_VERIFY"
  }
  if [ "$__actual" != "$__expect" ]; then
    log_error "$(_t 'checksum mismatch for'): $__file"
    log_debug "expected=$__expect actual=$__actual"
    return "$SK_VERIFY"
  fi
  return 0
}

_sk_download_raw() {
  local __url=$1 __dest=$2
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 15 --max-time 900 -o "$__dest" "$__url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 60 -t 2 -O "$__dest" "$__url"
  else
    log_error "$(_t 'curl or wget is required to download')"
    return "$SK_PRECOND"
  fi
}

# net_download URL DEST [SHA256] —— 下载并可选校验 sha256；已有本地缓存且校验通过就不重下
# @exitcode 0 下载成功（带 SHA256 时校验通过）
# @exitcode 2 参数错
# @exitcode 3 没有 curl 或 wget
# @exitcode 4 下载失败
# @exitcode 5 校验和不匹配
# @exitcode 1 写文件失败
net_download() {
  local __url=${1:-} __dest=${2:-} __expect=${3:-} __tmp __alt
  _sk_need_args "$#" 2 "net_download URL DEST [SHA256]" || return $?
  fs_ensure_dir "$(dirname "$__dest")" "" || return 1

  if [ -f "$__dest" ]; then
    if [ -z "$__expect" ]; then
      log_debug "$(_t 'using cached file'): $__dest"
      return 0
    fi
    if net_verify "$__dest" "$__expect" >/dev/null 2>&1; then
      log_debug "$(_t 'using cached file'): $__dest"
      return 0
    fi
    log_warn "$(_t 'cached file is invalid, re-downloading'): $__dest"
    rm -f "$__dest"
  fi

  log_info "$(_t 'downloading'): $__url"
  __tmp="$__dest.part.$$"
  rm -f "$__tmp"

  if ! _sk_download_raw "$__url" "$__tmp"; then
    if [ -n "${SHELLKIT_MIRROR_FROM:-}" ] && [ -n "${SHELLKIT_MIRROR_TO:-}" ]; then
      case "$__url" in
        "${SHELLKIT_MIRROR_FROM}"*)
          __alt="${SHELLKIT_MIRROR_TO}${__url#${SHELLKIT_MIRROR_FROM}}"
          log_warn "$(_t 'retrying via mirror'): $__alt"
          if ! _sk_download_raw "$__alt" "$__tmp"; then
            rm -f "$__tmp"
            log_error "$(_t 'download failed'): $__url"
            return "$SK_NET"
          fi
          ;;
        *)
          rm -f "$__tmp"
          log_error "$(_t 'download failed'): $__url"
          return "$SK_NET"
          ;;
      esac
    else
      rm -f "$__tmp"
      log_error "$(_t 'download failed'): $__url"
      return "$SK_NET"
    fi
  fi

  if [ -n "$__expect" ] && ! net_verify "$__tmp" "$__expect"; then
    rm -f "$__tmp"
    return "$SK_VERIFY"
  fi
  if ! mv -f "$__tmp" "$__dest"; then
    rm -f "$__tmp"
    return 1
  fi
  return 0
}

# net_wait_port HOST PORT [TIMEOUT] —— 等端口可连；超时返回 SK_NET(4)
# @exitcode 0 端口已就绪
# @exitcode 2 参数错
# @exitcode 4 超时仍未就绪
net_wait_port() {
  local __host=${1:-} __port=${2:-} __timeout=${3:-30} __i=0
  _sk_need_args "$#" 2 "net_wait_port HOST PORT [TIMEOUT]" || return $?
  while [ "$__i" -lt "$__timeout" ]; do
    # 只在子 shell 里开连接：exec 的重定向会落到调用方的 shell 上，
    # 以前那行 `exec 3>&- 2>/dev/null` 既关了别人的 fd 3，也把别人的 stderr 永久丢进 /dev/null。
    if (: <"/dev/tcp/$__host/$__port") 2>/dev/null; then
      return 0
    fi
    sleep 1
    __i=$((__i + 1))
  done
  return "$SK_NET"
}

# net_wait_http URL [TIMEOUT] —— 等 HTTP 可用；超时返回 SK_NET(4)
# @exitcode 0 HTTP 已就绪
# @exitcode 2 参数错
# @exitcode 3 没有 curl
# @exitcode 4 超时仍未就绪
net_wait_http() {
  local __url=${1:-} __timeout=${2:-30} __i=0
  _sk_need_args "$#" 1 "net_wait_http URL [TIMEOUT]" || return $?
  if ! command -v curl >/dev/null 2>&1; then
    log_error "$(_t 'curl is required for HTTP probing')"
    return "$SK_PRECOND"
  fi
  while [ "$__i" -lt "$__timeout" ]; do
    if curl -fsS -o /dev/null --connect-timeout 3 --max-time 5 "$__url" 2>/dev/null; then
      return 0
    fi
    sleep 1
    __i=$((__i + 1))
  done
  return "$SK_NET"
}
