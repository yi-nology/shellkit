# 变更记录
本文件由 `tools/release.sh` 在发版时自动追加，已发布的小节不要手改。
最新的在最前面。每一条对应一个提交 —— 要看「为什么」而不是「改了什么」，读 `docs/MIGRATING.md`。

## 0.8.1 — 2026-11-09

- 60dcbb6 docs(ai): 把新 API 补进「常见任务的落点」表
- e653b5c fix(release): 发布包必须带 NOTICE，并加门禁

## 0.8.0 — 2026-11-09

- d3e60c8 feat(site): 重做文档站视觉层，并修掉两处真实缺陷
- 692cef5 feat!: 许可证改 MIT + 补齐生态缺口（HTTP/结构化日志/dotenv/并发/脚手架演化/补全）

## 0.7.0 — 2026-11-09

- 78930c2 feat(site): 用 VuePress 2 建正式文档站（中英双语 + 站内搜索）
- 6de3da9 docs(migrating): 补 0.6.0 → 0.7.0 的迁移说明
- 1b1f5dc fix(versions): 堵住「裸版本号」漏改 —— 发版后首页会自相矛盾

## 0.6.0 — 2026-11-09

- 00324ae fix: 修复 10 条 open issue（run/fs/retry/lock/args/i18n/new/install）
- ffefc9d feat(release): 一条命令发版 + versions-check 门禁
- 2883fb9 fix(release): 摘掉 VERSION / MAKEFLAGS 再跑 make check

## 0.5.0 — 2026-11-09

- 5a41560 fix: 修复 19 条 open issue（config/fs/net/trap/lock/cli/docs/tooling）

## 0.4.1 — 2026-11-09

- 987a710 fix(install): 装好的副本自己推出 prefix，卸载/更新不必再写 --prefix

## 0.4.0 — 2026-11-09

- 7903479 docs: 加 GitHub Pages 站点（Actions 构建，不另开分支）
- 3c1e11c docs: 仓库地图补上 site/、examples/、docs/shots，门禁描述对齐 make check
- c71b779 feat(install): 一键安装 / 一键更新 / 一键卸载
- fede6d1 fix(release): 产物要带上 install.sh，否则一键安装脚本不在包里
- 90a849b fix(release): install.sh 作为 release 资产发布，一键安装改走稳定地址

## 0.3.0 — 2026-11-08

- bc7aff6 docs: shellkit 设计文档（从 jumpserver/installer 抽取可复用骨架）
- b76f732 feat: shellkit 0.1.0 —— 从 jumpserver/installer 抽取的 bash 库与脚手架
- fea7881 ci: 简化工作流定义（矩阵只按 os，去掉 step 级 shell 覆盖）
- 86b5222 test: i18n 断言不依赖系统 locale（CI 上没有 zh_CN 时改验 .mo 内容）
- e2381ab test: i18n 断言不再被 locale/环境差异判红；CI 在 Linux 装 gettext 与 zh_CN locale
- ebe9af5 feat: shellkit vendor —— 把库同步进既有工程，并补迁移指南
- 37d0f92 feat: 四个新模块 —— trap / run / retry / lock
- 0b2df12 feat: fs 幂等三件 + 临时目录清理入栈
- 7b75133 feat: 注释即文档 —— 从源码注释生成 API 参考
- fed8cd3 test: 给断言库加 stub，补上五个新模块的测试
- 892015b i18n: 补 28 条新 msgid 的译文（zh_CN / zh_Hant 各 135 条全译）
- b5f37ab docs: 0.2.0 —— README 补四件套与文档生成，版本断言改读 VERSION
- 2eec2e2 fix: bash 5 的子 shell 里 trap_install 静默漏装，清理不执行
- c6a68ce test: 补跨进程锁用例 —— 别人持有时拿不到，它退出后自动释放
- 0b90eef feat: 0.3.0 —— 让不熟的人和 AI 都能直接用起来
- 4de9dbc fix(ci): 发布产物要带上 skills/ 与 examples/；shfmt 只在 Linux 装

