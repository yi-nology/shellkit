# 变更记录
本文件由 `tools/release.sh` 在发版时自动追加，已发布的小节不要手改。
最新的在最前面。每一条对应一个提交 —— 要看「为什么」而不是「改了什么」，读 `docs/MIGRATING.md`。

## 1.0.0 — 2026-11-18


## 1.0.0-rc.1 — 2026-11-17

2a17079 docs(roadmap): 记上 v0.27.0 发版与独立验签结果
cc5b660 docs(releasing): 记 0.27.0 发版窗口事故与 --no-push 流程
2780c90 feat(api): 1.0 API 冻结清单（docs/API-FREEZE.md）+ 对账门禁
d8ad99b docs(install): 安全安装三步提到 README 顶部与安装页（中英）
25d3f2e feat(rc): 真实项目 RC 验证脚本 tools/rc_check.sh（v1.0.0 门槛）
2ff165f feat(rc): rc_check 支持 vendor 型工程 + --test-cmd（RC 证据可复跑）
942a6f0 fix(ci): compat 容器绕开 GITHUB_PATH 的 PATH 破坏 + 按需装 bash（#136）
2646d39 fix(vendor): 同步后核对版本，无所有权基线时 fail-closed（#137）
e76f79d fix(i18n): 补 #137 两条新词条的中文翻译（test_i18n 要求 zh_CN 全覆盖）
c23212e fix(vendor): 报错点名「N 个文件因缺所有权基线被保留」（#137）
c787e98 feat(ver): 预发布版本语义（-rc.N）+ RC 发版链路
6e96a0d fix(api-freeze): 冻结基线固定为 v1.0.0，不再随 VERSION 漂移
232e35d fix(versions): CHANGELOG 版本解析支持预发布后缀（RC 发版前置）
e3ebf51 test(api-freeze): 断言固定冻结基线，不再跟 VERSION 走

## 0.27.0 — 2026-11-17

a104b04 docs(roadmap): 记上 v0.26.2 与系统包的回归
b29ea13 feat(1.0): 0.27.0 契约批 —— 兼容承诺、取消重跑、发布自检、矩阵 lifecycle
b8981a7 fix(release): 门禁不再「零检查通过」+ 补齐新分支臂的覆盖
a6ea128 fix(uninstall): 卸载链路数据安全四单（#123 #124 #125 #128） (#131)
4484ef1 fix(ci/release): #126 upgrade_matrix strict 全版本跑通 + #127 DEB/RPM 公开前硬门禁 (#132)

## 0.26.2 — 2026-11-16

569df9a fix(sign): --file 点名补签不再要求 SHA256SUMS 整份齐全
5711a4d docs: 文档跟上 v0.26.1 —— 补全模块与门禁清单，重写发版链/信任链
73331ea docs(site): 图文跟上现状 —— 截图重渲染，补模块地图与发版链两张图解

## 0.26.1 — 2026-11-16

1c27eff fix(release): packages job 自己装 minisign，并加结构判据盯住所有签名 job
b4085f6 docs(roadmap): 状态行更新到 v0.26.0，补这一版的验收账与缺包遗留

## 0.26.0 — 2026-11-16

689f1dc docs(roadmap): v0.24.2 / v0.25.0 标记为已发布，并说明 0.26/0.27 为何随 0.25.0 发布
670eb0f docs(roadmap): 状态行跟上实际发版（v0.24.1 -> v0.25.0）
528603f fix(release): 新 CI job 补进发布门禁 + 双向对账用例 + 升级矩阵 --strict
eefffe1 fix(coverage): 副本带上 .github，对账用例在没 ci.yml 时显式 NA
ab39e65 fix(uninstall): 卸载只删「我们装的、内容还是原样」的文件，用户文件默认保留（P0）
c634c5e chore(coverage): 按 CI 清单补 uninstall 改动的 15 条臂、删掉 5 条已覆盖的
6672409 fix(release): 签名覆盖全部发布资产（脚本 / deb / rpm），验签改成「一个都不能少」
8dd5933 feat(release): 发布改成 draft -> 独立验签 -> 公开，验签失败不会露出资产
22ca746 fix(test): 发布顺序用例改成纯 bash 扫描，不再踩 pipe-safety 门禁
06e6f33 fix(test): pty 正向控制的超时上界抬到 60 秒，负载尖峰不再假红

## 0.25.0 — 2026-11-16

1da6376 feat(release): 跨版本升级矩阵 —— 用已发布旧版本建工程再用当前 CLI 升级（路线图 v0.25.0）
a8bb30d feat(release): 签名从可选改为必需 + 发布后独立验签（路线图 v0.27.0）
091e5f2 feat(release): 签名从可选改为必需 + 发布后独立验签（路线图 v0.27.0）
24d9a5b feat(api): 核心 fs/config/lock 批次晋升 Stable，公开契约扩到 50 个（路线图 v0.26.0）

## 0.24.2 — 2026-11-16

988f77f fix(own_sync): 用户改过的文件搬不动时整轮失败，不再静默丢失
1872c03 fix(test): file_mode 用八进制校验挑 stat 写法（GNU 的 stat -f 会「成功」吐垃圾）
1007cf1 docs(roadmap): 按实际发版重写为版本验收账本（原文档还写着 v0.18.0 是当前阶段）
eef9e09 chore(coverage): 臂号后移后已覆盖的 11 条 _sk_own_sync 条目移出基线
0be56c5 feat(release): 真产物验收抽成脚本并在 PR 阶段就跑（路线图 v0.25.0）
d7fd98a style(tools): 按 shfmt -i 2 -ci 重排产物验收脚本
fb4062d chore(coverage): 按 CI 的权威清单补齐 _sk_own_sync 的 12 条臂、删掉已不存在的 :63

## 0.24.1 — 2026-11-15

f2e74b9 fix(package): 发布 tarball 带上 .gitignore，否则包内 smoke 必红

## 0.24.0 — 2026-11-15

d0cd5fc refactor(upgrade): 路径守卫收口到库内唯一实现（gate-2）
1ec0bc4 fix(coverage): 按 CI 日志把 4 条已覆盖分支移出基线（gate-2 后续）
84e36eb docs(security): 偏差表按代码实数校正三条已收口项；给凭据忽略规则补判据
91240c9 fix(config): 写临时文件失败时不再静默清空配置（conf_set/conf_unset/conf_disable）
a014bcc test(gitignore): 覆盖率副本要带上 .gitignore，否则新用例必红
d76b52b chore(coverage): 按 Linux 实测重算 conf_* 的分支基线（写失败修复的连带）
d2ab947 fix(tests): test_doctor.sh 无 python3 时取值断言整段跳过——不再是红而是显式 skip(#101) (#102)
260d262 fix(security): 收口偏差表剩三条——备份原子写、暂存单文件写、http 经 run 脱敏
d1482ed chore(coverage): 按 Linux 实测重算 fs_backup 的分支基线（备份原子写的连带）
7128082 test(test_os): 隔离 PATH，让 os_desktop_env 的断言不再被机器上装着的会话二进制干扰

## 0.23.0 — 2026-11-15

53560ff fix(own_sync): 上游删除+用户改过的文件冻结基线登记——加回时不被静默覆盖(#91) (#94)
53635e5 ci(coverage): 分支级覆盖率接进 CI —— 新增 make coverage-branch，coverage job 双跑（路线图 v0.23.0）
890e8e1 feat(coverage): 分支覆盖缺口收敛 —— 基线 1011→988，34+ 缺口臂补测，#39 守卫锚点跟上重构（路线图 v0.23.0）
c93f146 fix(coverage): 基线改按 CI runner 口径重算 + chmod 场景补 root 守卫
bbf98c3 feat(bench): profile 计数基线 —— 升级热点有可比较的指标（路线图 v0.23.0-B2）
91dc93e docs(migrating): 0.22.0 → 0.23.0 行为变化表 —— profile 基线解禁与覆盖基线口径

## 0.22.0 — 2026-11-15

06b6036 feat(supply-chain): 正式启用 Minisign —— 密钥入 secret、公钥钉入 TRUST、发布加钉入一致性门禁（路线图 v0.22.0）
09e5000 fix(release): 签名步骤前安装 minisign —— v0.21.0 首发因 runner 缺工具在签名步骤报红（exit 3）
53560ff fix(own_sync): 上游删除+用户改过的文件冻结基线登记——加回时不被静默覆盖(#91) (#94)

## 0.21.0 — 2026-11-14

b6f35af fix: 批报 8 单(#81-#88)——删除安全化/prefix 互斥/恢复判据/force 透传/gate 三态/skill 事务/资产不可变/原生矩阵 (#89)
8550adb docs+ci: 第七轮评审收口补齐 —— MIGRATING 行为变化表 + SECURITY 删除规则 + 安全门禁删除判据 (#90)

## 0.20.0 — 2026-11-14

6169081 feat(bench): --profile 内部热点定位 —— 按数据决定优化的前提（阶段三批次A）
5ef8604 perf(i18n): 纯 C/POSIX locale 下 _t 不再 fork gettext —— 消掉每路径 39 次无效进程创建（阶段三批次A2）
51c0379 test(doctor): 字段契约对账 —— doctor --json 与 docs/JSON.md 逐节双向一致（阶段三批次B）
55b3b81 feat(cli): 补全升级到选项级 + completion --install + upgrade --diff 预览（阶段三批次C+D）

## 0.19.0 — 2026-11-13

822c451 feat(manifest): #78 —— 三类所有权清单带 schema 版本，认不出的版本明确拒读
de8af71 feat(api): #79 —— Public API 分级机制：@stability 注解 + 基线列 + 双向棘轮门禁
a3c662c feat(site): 主页重构 + 全站 GitHub 蓝紫主色 + 概念图解 + og:image + README badges\n\n视觉层（site/.vuepress/styles/index.scss）：\n- 主色从项目绿换成 GitHub 蓝紫：深色 #58a6ff/#1f6feb、浅色 #0969da\n  （白底要深一档才够 4.5:1），紫 #a371f7 作渐变辅色；补 --vp-c-brand-*\n  别名，残余旧 token 一起跟随 —— 否则换主色会留下一处没跟上的绿\n- hero 流光渐变标题（background-clip:text，9s 循环）+ 蓝紫两团慢速\n  漂浮光晕；.vp-hero 必须 z-index:0 自建层叠上下文，否则负 z-index 的\n  光晕被主题给 body 上的不透明背景整团盖掉（写了动画也看不见）\n- 特性卡悬浮发光（蓝紫双层阴影），浅色模式光效一律减弱\n- prefers-reduced-motion：动画全部停在静态帧，内容一个不少\n\n首页激进减重（site/index.md + en 同步）：\n- tagline 一句、卡片细节一行、7 卡收 6 卡成 2×3 网格\n- 删 17 行模块表与许可节，许可并进页脚；en 首页补 footer/footerHtml\n  （此前没有 llms.txt 页脚入口）\n- 装配关系图解置顶：图解先行，文字作补充\n\n概念图解（site/.vuepress/public/diagrams/，图内只放代码 token，中英共用）：\n- assembly / install-chain / quickstart-flow / conventions 四张\n- 插入 guide/{installation,quickstart,conventions} 中英六页\n  （均为手写页，不在 site_sync 投影清单内）\n\nog:image：PIL 生成 1200x633 og.png；config.ts head 加 og:/twitter: meta\n（绝对地址，分享抓取方不在站点内）；README 标题下加 release/CI/license/\nbash 四个 badge（shields.io 已实测 200）。\n\n验证：make site（91 页、site-links 422 内链 ok）、make check rc=0、\n浏览器目检深浅两色首屏与图解（资源 200、控制台零报错）、\n光晕修前修后同区域像素对比（纯背景 -> 抬升，对照区不动）。
1af20eb chore: 忽略 .superpowers/ 本机工作文档目录（设计稿等，不进分发包与文档门禁）
d48a86a fix(ci): #79 的新用例在 compat 容器里建不出副本 —— 副本改走不依赖 git 的最小树
c5dd315 fix(coverage): 把 test_api_stability.sh 加入 coverage 排除名单（它跑门禁探针）
14d32c0 fix(test): pty 用例在 macOS 系统 python3（3.9.6）下永久挂死 —— 有 timeout 就套一层
3439b6f chore(coverage): 分支基线按 c5dd315 排除口径重写（#55 棘轮双向对齐）
9cff82b feat(site): 配色改三态选择器 —— 白 / 黑 / 跟随系统（默认跟随系统）\n\n- 新增 site/.vuepress/useDarkMode.ts 整体替换主题的 @theme/useDarkMode：\n  主题只有两态布尔开关（内部 storage 虽有 auto 值域但 UI 表达不了），\n  这份实现拿到完整三态控制权，保持原契约（setupDarkMode provide +\n  可写 boolean ref + 目标值==系统偏好记 auto 的写入语义）\n- config.ts 加 alias 指向它：VuePress resolveAlias 按键长降序排序，\n  长键必然优先于主题的 @theme 前缀键；colorModeSwitch:false 隐藏内置开关\n- 导航栏 navbar-after 挂 ColorModePicker：三段胶囊（☀白 / ☾黑 / 🖥系统），\n  激活段主色实底；窄屏只留图标；文案随 locale 切换（zh 白/黑/系统，\n  en Light/Dark/System）；图标内联 SVG，不依赖主题内部路径\n- 首帧防闪：head 内联脚本在样式生效前定 data-theme，逻辑与 useDarkMode.ts\n  同源（三态 + 旧键 vuepress-color-scheme 只读迁移，老访客的选择不丢）\n- 选择存 sk-color-mode；跨标签页 storage 事件同步；系统外观翻转时\n  auto 档跟随、显式档压过系统\n\n验证：make site（91 页、site-links ok）+ make check rc=0；浏览器实测\n首次访问=跟随系统（本机 Light 浅色）、点黑变深且刷新持久、点系统回浅色、\n控制台零报错；双语标签与首帧脚本在 zh/en 产物中均核过。
0c17712 docs(stability): 首批 Stable 候选清单（46 个，待勾选）
27e03a3 feat(stability): 首批 37 个公开函数晋升 Stable，门禁兜底「Stable 改动必须进 MIGRATING」

## 0.18.0 — 2026-11-13

d83bd06 perf(registry): 查询走内存快照，不再每次 fork awk（48ms/次 → 0.9ms/次）
609b1c1 feat(v0.18.0): #56 / #59-#63 + #69/#70 —— 安全规范、API 基线、doctor --json、错误上下文、安装幂等、故障注入
f5579e9 feat(v0.18.0): #55/#57/#58 + #64-#67 —— 分支覆盖与故障矩阵、skill 客户端可配置、打包签名与升级提示
583b05f fix(ci): #71-#75 —— 修复第六轮评审点名的跨平台红灯，并把路线图落文档
3e06a48 fix(ci): #73 根因 —— bash 3.2 + UTF-8 locale 下 $ident 紧跟汉字会炸，加门禁钉死
678754c fix(ci): #76 —— compat 容器（root）下权限注入永远不触发，改成 root 感知的 NA
0cd0491 fix(ci): #77 —— bash 3.x 下 source 语法错误会打死整个 CLI；容器补装 python3/git
0841d7d test(skill)+chore(coverage): 代为提交并行会话的 #58/#55 滞留改动

## 0.17.0 — 2026-11-12

6da1e34 docs(release): 补上 Homebrew tap 的回填流程，并修掉生成器里过期的注释
d4473a3 feat(i18n): 加 _tf（译文当 printf 格式串）+ msgmerge 禁用模糊匹配 (#38)
f12a95d fix: #39-#45 收口 —— skill 所有权与边界、repair 状态机、release 质量准入、升级日志可靠性 (#68)

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

