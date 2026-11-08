---
name: shellkit
description: 用 shellkit 写运维 Bash 脚本（Bash 3.2 基线）。需要写/改 shell 脚本、加子命令、配置读写、下载校验、重试、单实例锁、清理收尾时使用；也用于把库引入既有工程。
---
<!-- 生成物：由 tools/ai_doc.sh 拼装，请勿手改。改 docs/ai/skill.head.md 再跑 shellkit docs。 -->

# 在任意项目里用 shellkit

shellkit 是 Bash 库 + 脚手架。用它，你不用再手写日志、配置、下载校验、重试、单实例锁。

## 引入：三选一

    # A. 新工程（推荐）：直接生成带库的骨架
    shellkit new ./ops-tool --cmd deploy --cmd status

    # B. 既有工程：把库镜像到 vendor/shellkit（可提交，可复现）
    shellkit vendor .

    # C. 自用脚本：全局安装
    shellkit install-self --prefix ~/.local

脚本里加载库就一行：

    . "$(cd "$(dirname "$0")/.." && pwd)/vendor/shellkit/lib/bootstrap.sh"

## 最小可用脚本

    #!/usr/bin/env bash
    set -euo pipefail

    . ./vendor/shellkit/lib/bootstrap.sh

    require_cmd curl || exit $?
    conf_init ./config || exit $?

    host=$(conf_get_any HOST 127.0.0.1)
    port=$(conf_get_any PORT 8080)

    log_info "probing $host:$port"
    net_wait_port "$host" "$port" 10 || die "service did not come up"
    log_ok "ready"

## 更新库

    shellkit vendor . --check     # 只看有没有漂移（CI 用，漂移返回 5）
    shellkit vendor .             # 同步到最新

`vendor/shellkit/` 是镜像：**不要就地改它**，会被下一次 vendor 覆盖。
