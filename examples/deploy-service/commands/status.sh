#!/usr/bin/env bash
# cmd_status —— 只输出数据到 stdout，过程信息走 stderr。
#
# 这样 `state=$(deploy-service status web)` 拿到的一定是 installed / missing，
# 不会混进日志行。

cmd_status() {
  local name=${1:-}
  local root=${DEPLOY_ROOT:-/etc/systemd/system}

  if [ -z "$name" ]; then
    log_error "missing service name"
    cli_usage_cmd status
    return "$SK_USAGE"
  fi

  if [ -f "$root/$name.service" ]; then
    printf 'installed\n'
    return "$SK_OK"
  fi

  printf 'missing\n'
  return 1
}
