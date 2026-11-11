# 变更记录
本文件由 `tools/release.sh` 在发版时自动追加，已发布的小节不要手改。
最新的在最前面。每一条对应一个提交 —— 要看「为什么」而不是「改了什么」，读 `docs/MIGRATING.md`。

## 0.16.0 — 2026-11-11

d1bac81 docs(bash32): Bash 3.2 指南的真相源挪进 docs/BASH32.md
c374feb feat(skill): skill 完整包 —— SKILL.md 与 references/ 投影
fa6e248 feat(cli): shellkit 新增 skill 与 demo 两个子命令
c9394c9 feat(demo): demo.sh —— 下载 release、校验 sha256、解包即跑
1db64c5 feat(release): release 资产多两个 —— demo.sh 与 skill 包 tarball
e7a3230 feat(site): llms.txt —— 中英两份，站点导航与页脚各挂一个入口
9c24380 feat(packaging): Homebrew formula 生成器 tools/brew_formula.sh
35e0fea feat(i18n): skill 与 demo 的新文案入 locale
9ad2a86 docs: 0.16.0 行为变化表 + README 与站点指南（skill / demo / llms.txt / brew）
4514164 fix(docs): check_docs.sh 排除 skill 包投影 —— 源已扫过，判据能力不增

## 0.15.0 — 2026-11-11

bf6c2b3 feat(i18n): 加 _tf（译文当 printf 格式串）+ msgmerge 禁用模糊匹配
9cd4bfc feat(upgrade,coverage,mutation,repair): 第四轮评审的四项收口
6ae6e03 docs: 0.15.0 行为变化表 + 坑 14-16 + 修复入口
f177959 fix(test): install 用例声明自己的时间上限 —— 七八轮真实安装拷贝，本机 ~8 分钟
88a853f fix(ci): release 打包清单补回 tests/，并逐项点名自检
f7d8473 fix(test): 「缺译文的条目」不再用 msgattrib 数 —— gettext 版本之间判据不同

## 0.14.0 — 2026-11-11

e629497 docs(plan): 批次 4.4 补上变异位点清单与「收编已有原语」的要求
79bc61d feat(coverage): 公开函数级覆盖率 —— 哪块没被测到，一眼可见
7868924 fix(test): 发版包里没有 CHANGELOG.md 与 site/ —— 门禁自测的夹具要自给自足
5fdb236 fix(release): 发包后的 smoke test 不许再脆断 —— 0.13.0 就是这么红的
ed09a69 fix(test): stub 的 --body 里 exit 不许杀掉测试脚本 —— 假绿真的发生过
5ba29dc fix(svc): unit 名拒绝路径穿越、root 不套 sudo —— 测试全程不碰真实 /etc
9714076 fix(upgrade,vendor,install): 可靠性闭环 —— 中断恢复、并发互斥、旧清单一次升到位
c6bff8a fix(registry): 缺失依赖要报 missing dependency —— 不能当普通节点混进排序
703645d fix(ver): 非法输入返回 2 —— 「没法比较」不许伪装成「相等」
2b15dcd docs: 0.14.0 行为变化表 + 坑13（stub exit 假绿）+ 「事务」命名纠正
4ca1fba feat(mutation): 变异测试工具 —— 验证回归网的判据能力
a60d1ea ci: 覆盖率棘轮与变异 campaign 各开一个 job
87169e5 test(upgrade): 补 rel_safe 的 .. 分支判据 —— 变异测试发现这里一打就活
5b7eb05 ci: release/pages 的 actions 引用钉到 commit SHA —— 供应链纪律收口最后一个浮动面
1da838d feat(i18n): 生成工程的 Makefile 文案跟着生成器的语言走
d56c446 fix(test): 字面 case.N 临时目录撞车 —— 三个测试文件共用 serial runner 的 TEST_TMP_ROOT

## 0.13.0 — 2026-11-11

051ec98 fix(test): 发版包里没有 CHANGELOG.md 与 site/ —— 门禁自测的夹具要自给自足
c72d5bd fix(scaffold): 模板变量的值里有换行要直接拒绝 —— 以前是静默截断
f97a389 ci: 批次 4.2 —— ARM64 与国产系统（欧拉）进流水线
476f066 docs(plan): 批次 4 收口的计划 —— 覆盖率、变异测试、ARM64/国产流水线
205ac57 ci: 下载器兜底别只认 curl-minimal —— openEuler 没有这个包名
e748518 fix(install-self): 重装不再自删运行源 —— 整份副本先进 stage 再原子换名
11af801 fix(new): 提问循环不能再挂在 heredoc 上 —— fd 0 被抢走，ask 永远判非交互
dbf14c2 fix(cli): SHELLKIT_MODULES 不再泄漏进 CLI —— 按需加载是给直接用库的人的
08baec8 fix(versions): 裸版本号门禁扩到 README —— 同一种漂移不该只在站点页被抓
a311af6 docs(migrating): 补 0.13.0 的三行行为变化 —— new 提问、install-self 自装、CLI 全量加载

## 0.12.1 — 2026-11-11

3215c7f fix(test): 守卫用例断完整文案与结构事实 —— 路径不能白送断言
02a592d fix(test): 用例的输出语言固定成英文 —— 中文 locale 不该整片炸红
03a57fd docs(ai): 补第 12 条坑 —— 输出类断言的三个前提
71a983c fix(test): 三处输出断言改为断完整文案 —— 路径不能白送断言
f67d6f4 perf(scaffold,os): 渲染与摘要少走 fork —— new 从 6~8 秒降到 1 秒
de61601 docs(migrating): 补 0.12.1 小节 —— 只砍 fork，行为不变
166a279 fix(test): 临时目录计数的断言要隔离 TMPDIR —— 否则会被并发进程改成随机红

## 0.12.0 — 2026-11-11

9da38dc docs(site): 英文站的模块数从 seventeen 改成 18 —— 文档说 17、实际 18 的漂移
3dc4af7 fix(module-count): 英文页的模块数漂移一直抓不到 —— 门禁只认数字形式
1e775bb feat(i18n): 多域查找 + 纯 bash 兜底表 —— 没有 gettext 也出译文
4a2f2a4 feat(os): 发行版与桌面环境检测 —— 麒麟靠 ID_LIKE 判定，不进 ID 硬表
402e3d5 feat(os): 提权包管理与 sudo 就绪 —— 既有 os_pkg_* 语义一字不动
c5fc1b7 feat(svc): systemd 服务动词 —— 写类动作支持 dry-run
107d6b8 fix(os): 清掉外来重复实现 —— 阵亡代理的残留块曾被误提交
17f4fda feat(ver): 版本比较 —— 纯 bash 分段比较，不依赖 GNU sort -V
90192b1 feat(status,registry,profile): 三个新模块 —— 状态契约、KV 注册表、profile 格式原语
2657fd5 feat(http): GitHub release 查询 —— net_request 取原文再本地解析
09c67f6 feat(run): 超时包装与 sudo 遮蔽 —— 遮蔽需显式调用，不改默认行为
06dee6d feat(str): str_suggest —— 纯 bash 编辑距离，bash 3.2 兼容
433218d docs: 重生 API 参考 —— 补上 http / run / str 的新公开函数
ad2cf7e style: 按 shfmt 归一 http/run 新增代码
e930b1d feat(registry): registry_scan_multi —— 一次扫多个清单根目录
b519390 feat(registry): registry_add —— 登记单份清单文件
abf2b76 fix(upgrade): 升级不再写到工程之外 —— 清单名校验、路径边界、符号链接、写盘失败不再崩溃
12b0e98 docs(reports): v0.11.0 复核报告与 v0.12.0 路线图
152f503 docs(migrating): 修正升级被中断后的描述 —— 别把没实测的行为说成会补齐
1b0ad7f docs(reports): 更正 —— test_http 的 jq-less 兜底是真 bug，不是 flaky（已被并行会话修掉）
df27b22 perf(trap): 装 trap 时的临时文件只删一次，不再 8 次 rm
6417dcd fix(docs): 新模块的文档注释里别留裸尖括号 —— 站点构建整个炸掉
d21c10d fix(upgrade): 升级写盘改成原子写 —— 中断不再留下半截文件
542f069 docs(ai): 补第 10 条坑 —— 文档注释里的裸尖括号会炸站点构建
3a7b5fa fix(man): 模块页的 DESCRIPTION 只取文件头首行摘要 —— 不再摊成一堵文字墙
913ab2d docs(site): 把 docs/MAN.md 接进站点与 README —— 别让它成为孤儿页
25231a3 docs(migrating): 把 0.11.1 小节并回 main —— v0.11.1 已发布，main 上不能没有这条记录
671ce81 fix(upgrade): 升级事务化 —— 致命问题在动文件之前就退出，vendor 目录整体换
79cabb5 docs(migrating): 说明 0.11.1 与 0.12.0 的关系 —— 0.11.1 是维护版，升级行为没变
e8242db feat(run): 命令行脱敏补齐形态 + 显式声明接口 —— 启发式永远漏，得给调用方一把钥匙
d4f0a05 docs(tests): 标注 assert_true / assert_false 只能传命令 —— 多传一个文案就变成参数
84dc518 test: 批次 2 —— runner 上限抬到 300s、TTY 假绿改成同步点、加元测试（门禁自己也要被测）
7999447 docs(changelog): 把 0.11.1 小节并回 main —— 发过的版本不能从变更记录里消失

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

