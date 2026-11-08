#!/usr/bin/env bash
# 平台与系统探测。所有 Darwin / Linux 差异只在这里出现。

_sk_os_detect() {
  case "$(uname -s 2>/dev/null)" in
    Linux*) SK_OS=linux ;;
    Darwin*) SK_OS=darwin ;;
    *) SK_OS=other ;;
  esac
  case "$(uname -m 2>/dev/null)" in
    arm64 | aarch64) SK_ARCH=aarch64 ;;
    x86_64 | amd64) SK_ARCH=x86_64 ;;
    *) SK_ARCH=other ;;
  esac
}

_sk_os_detect

# os_name —— linux | darwin | other
os_name() { printf '%s\n' "$SK_OS"; }

# os_arch —— x86_64 | aarch64 | other
os_arch() { printf '%s\n' "$SK_ARCH"; }

# os_is_root
os_is_root() {
  if [ "$(id -u 2>/dev/null)" = "0" ]; then
    return 0
  fi
  return 1
}

# os_has_cmd CMD...
os_has_cmd() {
  local __c
  for __c in "$@"; do
    if ! command -v "$__c" >/dev/null 2>&1; then
      return 1
    fi
  done
  return 0
}

_sk_pkg_mgr() {
  if [ -n "${SK_PKG_MGR:-}" ]; then
    printf '%s\n' "$SK_PKG_MGR"
    return 0
  fi
  local __m
  for __m in dnf yum apt-get zypper apk; do
    if command -v "$__m" >/dev/null 2>&1; then
      SK_PKG_MGR=$__m
      printf '%s\n' "$SK_PKG_MGR"
      return 0
    fi
  done
  return 1
}

# os_pkg_manager
os_pkg_manager() { _sk_pkg_mgr; }

# os_pkg_update
os_pkg_update() {
  local __mgr
  __mgr=$(_sk_pkg_mgr) || {
    log_error "$(_t 'no supported package manager found')"
    return "$SK_PRECOND"
  }
  case "$__mgr" in
    dnf) dnf -q -y makecache ;;
    yum) yum -q -y makecache ;;
    apt-get) DEBIAN_FRONTEND=noninteractive apt-get -qq update ;;
    zypper) zypper -q --non-interactive refresh ;;
    apk) apk update -q ;;
  esac
}

# os_pkg_install PKG...
os_pkg_install() {
  local __mgr
  __mgr=$(_sk_pkg_mgr) || {
    log_error "$(_t 'no supported package manager found')"
    return "$SK_PRECOND"
  }
  case "$__mgr" in
    dnf) dnf -q -y install "$@" ;;
    yum) yum -q -y install "$@" ;;
    apt-get) DEBIAN_FRONTEND=noninteractive apt-get -qq -y install "$@" ;;
    zypper) zypper -q --non-interactive install "$@" ;;
    apk) apk add -q "$@" ;;
  esac
}

# os_sed_i ARGS... —— 就地编辑；Darwin 的 sed 必须给个备份后缀
os_sed_i() {
  if [ "$SK_OS" = "darwin" ]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# os_md5 FILE
os_md5() {
  local __f=$1
  if command -v md5sum >/dev/null 2>&1; then
    md5sum "$__f" | awk '{print $1}'
  elif command -v md5 >/dev/null 2>&1; then
    md5 -q "$__f"
  else
    return 1
  fi
}

# os_sha256 FILE
os_sha256() {
  local __f=$1
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$__f" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$__f" | awk '{print $1}'
  else
    return 1
  fi
}
