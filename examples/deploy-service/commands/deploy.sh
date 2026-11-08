#!/usr/bin/env bash
# cmd_deploy —— 幂等地安装一个 systemd 单元。
#
# 关键是「重复跑同一个命令，结果必须一样」：单元文件整份原子写，内容由服务名决定，
# 所以跑一百遍和跑一遍没有区别。
#
# DEPLOY_ROOT 用来把落点挪走（测试就靠它，不会碰到真实的 /etc）。

cmd_deploy() {
  local name=${1:-}
  local root=${DEPLOY_ROOT:-/etc/systemd/system}

  if [ -z "$name" ]; then
    log_error "missing service name"
    cli_usage_cmd deploy
    return "$SK_USAGE"
  fi

  # 同时只允许一个实例部署，避免两个进程写同一个单元文件
  lock_acquire "deploy-$name" 5 || return $?
  trap_push "lock_release 'deploy-$name'"
  trap_install

  fs_ensure_dir "$root" 755 || return $?

  # 原子写：中断时不会留下半个单元文件让 systemd 读到
  fs_atomic_write "$root/$name.service" "[Unit]
Description=$name
After=network.target

[Service]
ExecStart=/usr/local/bin/$name
Restart=on-failure

[Install]
WantedBy=multi-user.target
" 644 || return $?

  log_ok "installed $root/$name.service"
  log_info "next: systemctl daemon-reload && systemctl enable --now $name"
  return "$SK_OK"
}
