# 变更记录
本文件由 `tools/release.sh` 在发版时自动追加，已发布的小节不要手改。
最新的在最前面。每一条对应一个提交 —— 要看「为什么」而不是「改了什么」，读 `docs/MIGRATING.md`。

## 0.11.1 — 2026-11-10

dd3d144 perf(trap): 装 trap 时的临时文件只删一次，不再 8 次 rm
aa433d7 docs(migrating): 补 0.11.1 小节 —— trap_install 的 8 次 rm 降到 1 次

## 0.11.0 — 2026-11-10

2cfb087 fix(test): 真下载的用例在「没有 curl 也没有 wget」的机器上判红
802591b fix: 按评估逐条修掉 —— upgrade 不再覆盖用户修改、dotenv 写回一致、日志脱敏、并发器加固
a9f531c fix(ci): 容器 job 的 shell 是 sh 不是 bash —— set -o pipefail 直接是非法选项
a4519b6 fix(ci): 兼容矩阵容器 job 装包策略修正 —— Rocky 9 装不上 curl
c1be6d3 fix(site): package-lock 的 tarball 地址改回官方源 —— CI 拉 npmmirror 直接挂死
797eecc fix(site): 回滚误删的 lock 条目 —— 只保留 registry 主机替换

## 0.10.0 — 2026-11-09

6ea9be4 fix(prompt): 交互式 ask 拿不到用户输入，并给整类「同名遮蔽」加门禁
4d89d3f docs(gate): 出参保留名单自动查漂移，并补门禁自测
9ba86ac feat(gate): 模块数也钉住 —— 文档里手抄的「N 个模块」必须与清单一致
dad8685 test(cli): 回归 —— 选项值写进与内部局部同名的变量时不能再丢
d9729f1 docs(site): 门禁表补两条新门禁（命名空间 / 模块数）
8e6d8c7 docs(site): 约定页讲清「出参名撞上内部局部变量会静默失效」这个坑
3f742f3 feat(man): 从注册表与函数注释生成 man page
732745b fix(test): 三个测试在 Linux 上会假红
5bae973 fix(man): 模块存在性判断别用 grep -q 管道
eaf6948 feat(gate): 新门禁 —— 管道里不能有会提前退出的消费者
72228fd docs(gate): 约定页与 AGENTS.md 补「管道早退」这个坑

## 0.9.0 — 2026-11-09

143d489 feat(api): 公开函数全部写明返回码，并加门禁守着
e263f16 feat(modules): 模块清单两列化 + SHELLKIT_MODULES 按需加载 + 依赖门禁
d363cf4 feat(vendor,doctor): 副本自带 CLI 与模板；doctor 做三类自检
a377b54 feat(test): 执行器支持 TAP/JUnit/并行/过滤，并给执行器自己补上回归测试
8d856bd feat(docs): 消灭第三份模块清单 + CHANGELOG 自动生成 + 两道新门禁

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

