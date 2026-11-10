#!/usr/bin/env bash
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"

# svc_platform：只能是 systemd/launchd/none 之一
case "$(svc_platform)" in
  systemd | launchd | none) ;;
  *) _fail "unexpected svc_platform: $(svc_platform)" ;;
esac

# 动作动词是 systemd 一套的，测的时候把平台钉成 systemd
export SK_SVC_PLATFORM=systemd

# 用 stub 顶掉 systemctl，断言动作与参数
stub systemctl --body 'exit 0'
svc_start nginx
assert_stub_called systemctl 1
assert_stub_args systemctl "start nginx"
svc_stop nginx
assert_stub_args systemctl "stop nginx"
svc_restart nginx
assert_stub_args systemctl "restart nginx"
svc_reload nginx
assert_stub_args systemctl "reload nginx"
svc_enable nginx
assert_stub_args systemctl "enable nginx"
svc_disable nginx
assert_stub_args systemctl "disable nginx"
svc_enable_now nginx
assert_stub_args systemctl "enable --now nginx"
svc_disable_now nginx
assert_stub_args systemctl "disable --now nginx"
svc_daemon_reload
assert_stub_args systemctl "daemon-reload"
unstub systemctl

# 只读动作：直跑，不套 dry-run
stub systemctl --body 'exit 0'
assert_exit_code 0 svc_is_active nginx
assert_stub_args systemctl "is-active --quiet nginx"
assert_exit_code 0 svc_is_enabled nginx
assert_stub_args systemctl "is-enabled --quiet nginx"
unstub systemctl

stub systemctl --body 'exit 1'
assert_exit_code 1 svc_is_active nginx
assert_exit_code 1 svc_is_enabled nginx
unstub systemctl

# dry-run：只打印不执行
stub systemctl --body 'exit 0'
SHELLKIT_DRY_RUN=1 svc_restart nginx
assert_stub_not_called systemctl
SHELLKIT_DRY_RUN=1 svc_daemon_reload
assert_stub_not_called systemctl
unstub systemctl

# 用法错：缺 unit
assert_exit_code 2 svc_start
assert_exit_code 2 svc_start ""
assert_exit_code 2 svc_stop
assert_exit_code 2 svc_is_active
assert_exit_code 2 svc_install_unit

# 当前平台没有 systemd：写类与只读动作都返回 3
export SK_SVC_PLATFORM=none
assert_exit_code 3 svc_start nginx
assert_exit_code 3 svc_restart nginx
assert_exit_code 3 svc_daemon_reload
assert_exit_code 3 svc_is_active nginx
assert_exit_code 3 svc_install_unit foo.service
unset SK_SVC_PLATFORM

# svc_install_unit：dry-run 下不写盘、不 reload
export SK_SVC_PLATFORM=systemd
stub systemctl --exit 0
printf '[Unit]\nDescription=x\n' | SHELLKIT_DRY_RUN=1 svc_install_unit foo.service
export SHELLKIT_DRY_RUN=1
assert_exit_code 0 svc_install_unit foo.service </dev/null
unset SHELLKIT_DRY_RUN
assert_stub_not_called systemctl
unstub systemctl

# svc_install_unit 的真写路径：**全程 stub**，真实 /etc 一个字节都不许碰。
# （历史缺陷：这里以前是裸调用 —— 在 systemd + 免密 sudo 的机器上会真写
#   /etc/systemd/system/foo.service；而且 harness 的 stub --body 假绿让
#   这条断言从没被执行过，包着的假绿一直没露头。）
export SK_SVC_PLATFORM=systemd
stub systemctl --exit 0
stub sudo --exit 0
stub id --stdout 501
printf '[Unit]\nDescription=x\n' | svc_install_unit foo.service
assert_stub_args sudo "tee /etc/systemd/system/foo.service"
assert_stub_called systemctl 1
unstub id
unstub sudo
unstub systemctl

# root：直接 tee，不套 sudo —— 极简容器里常有 root 但没有 sudo 命令
# （sudo 也要 stub：unstub 不清调用日志，上一段的记录会让「没被调用」的
#   断言看到旧账 —— stub 一声明就重置日志，才是干净的对照）
export SK_SVC_PLATFORM=systemd
stub systemctl --exit 0
stub sudo --exit 0
stub tee --exit 0
stub id --stdout 0
printf '[Unit]\nDescription=x\n' | svc_install_unit foo.service
assert_stub_args tee "/etc/systemd/system/foo.service"
assert_stub_not_called sudo
unstub id
unstub tee
unstub sudo
unstub systemctl

# UNIT 名带路径组件：直接拒绝（退出码 2），一个命令都不许调 ——
# 拼进 /etc/systemd/system/ 之后是用 root 权限写的，穿越出去就是任意位置写文件
export SK_SVC_PLATFORM=systemd
stub sudo --exit 0
stub tee --exit 0
assert_exit_code 2 svc_install_unit ../evil.service
assert_exit_code 2 svc_install_unit foo/bar.service
assert_exit_code 2 svc_install_unit .hidden.service
assert_exit_code 2 svc_install_unit 'bad name.service'
assert_stub_not_called sudo
assert_stub_not_called tee
unstub tee
unstub sudo

# svc_install_unit：不是 systemd 平台返回 3
export SK_SVC_PLATFORM=none
assert_exit_code 3 svc_install_unit foo.service
