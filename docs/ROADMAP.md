# ShellKit 路线图：三层架构与版本验收状态

状态：2026-11-17 更新（当前 **v0.26.2** 已发布；**v0.27.0「1.0 契约」**已落地，待发版）。
本文是**方向**，不是承诺 ——
每个版本的退出条件写清楚，条件不满足就不进下一个版本（见「迭代节奏」）。

进度只按**验收结果**记，不按日期：标为已完成（Completed）的每一条都能在仓库里指到判据；
未完成的一律留在「计划」里，不写「已完成 90%」这种没法验证的措辞。

## 一、目标架构：三层，单向依赖

    Developer Experience   CLI · Scaffold · AI Skill · Docs · Release
    Engineering Contracts  API Baseline · Security Policy · Ownership · Recovery · Quality Gates
    Bash Runtime Core      Filesystem · CLI · Process · Network · Config · Logging · OS

- **依赖方向只能向下**：上层可以调下层，下层永远不知道上层存在。
- **工程工具不能成为运行库的强制依赖**：`lib/core/*.sh` 被别人的工程 vendor 走时，
  不该因为 `tools/` 里的门禁脚本缺失而跑不起来。门禁只在本仓库的 CI 里存在。
- 这条约束当前是成立的（`lib/` 不引用 `tools/`），写在这里是防止以后被无意破坏。

## 二、版本验收状态

### 已完成（Completed）

| 版本 | 主题 | 验收判据（能在仓库里指到） |
|---|---|---|
| v0.18.0 | 稳定性收口：六个门禁一次落地 | CI 全矩阵可重复通过；#71–#77 各自有回归；`make check` 单命令 |
| v0.19.0 | 工程契约：API 分级 + 清单 schema 版本 | `@stability` 注解 + `tools/api_baseline.sh` 双向棘轮；三类清单带 `manifest_version` |
| v0.20.0 | 性能与开发体验 | `tools/bench.sh`（含 `--profile` 计数基线）、选项级补全、`upgrade --diff` |
| v0.21.0 | 数据安全批（#81–#88） | 删除统一走 `_sk_fs_safe_remove_owned`；prefix 互斥；恢复判据；资产不可变 |
| v0.22.0 | 供应链：正式启用 Minisign | 私钥入 secret、公钥钉进 `docs/TRUST.md`、发布后公钥一致性校验 |
| v0.23.0 | 分支覆盖棘轮 + profile 基线 | `make coverage-branch` 进 CI 双跑；基线按 CI runner 口径重算 |
| v0.24.0 | 偏差表七条全闭（备份原子写 / 暂存单文件写 / http 经 run） | `docs/SECURITY.md` 第 6 节；`test_fault_matrix.sh` 的 `backup` 行；`test_http.sh` 脱敏断言 |
| v0.24.1 | 发布链路修复 | 发布 tarball 带上 `.gitignore`；smoke 由 `release.yml` 在**真产物**上跑 |
| v0.24.2 | 数据安全收口（P0） | `_sk_own_sync` 搬不动就整轮失败、写回后 `os_sha256` 自检；`test_fault_matrix.sh` 的 `vendor\|keep-fail` 格（注入点 `TMPDIR`） |
| v0.25.0 | 发布质量前移 + API 契约 + 供应链（三批合并发布） | `tools/package_artifact_smoke.sh`（PR 与发版同一份）、`tools/upgrade_matrix.sh`、50 个 Stable API、`sign_release.sh --require` + `tools/verify_release.sh` |
| v0.26.0 | 发版原子性 + 卸载所有权（两处 P0） | draft → 独立验签 → 公开；`uninstall-self` 只删「我们装的、内容还是原样」的；`packages` job 自装 minisign + 结构判据 |
| v0.26.2 | 补签语义修复 | `sign_release.sh --file` 不再要求 `SHA256SUMS` 整份齐全（`dist` 只有一部分资产是补签的常态）；17 项资产全签名并经独立验签 |
| v0.26.1 | 系统包 job 的两处附产品：签名工具与补签前提 | `packages` job 自装 minisign；`sign_release.sh --file` 点名模式不再要求 `SHA256SUMS` 整份齐全（`tests/test_release_signing_tool.sh` 盯着签名 job） |

### v0.24.2 —— 数据安全收口（已发布 2026-11-16）

| 交付 | 判据 |
|---|---|
| `_sk_own_sync` 的暂存/恢复失败不再被 `|| true` 吞掉 | 搬不动 ⇒ 整轮失败；恢复缺件 ⇒ 整轮失败；写回后 `os_sha256` 自检 |
| 故障注入钉住这条路径 | `test_fault_matrix.sh` 的 `vendor\|keep-fail` 格：注入点选 `TMPDIR`，只有「搬进暂存区」失败 |
| 自检：把缺陷造回去必须变红 | 还原成 `|| true` 后同一条用例必须报「搬不动却返回 0」 |

退出条件：上述三格全绿，且 `make check` 与 CI 全矩阵通过。

**结果**：本地 `make check` 78 个文件全过、CI 21/21 绿；自检（还原成 `|| true`）实测
`vendor` 返回 0，正是要治的那个静默丢失。

### v0.25.0 —— 发布质量前移（已发布 2026-11-16）

v0.24.0 暴露的缺口是：源码矩阵全绿、系统包构建也全绿，但**真产物**解包后跑套件才炸
（tarball 漏了 `.gitignore`）。说明「仓库工作树能跑」不等于「发布包能跑」。

| 交付 | 判据 |
|---|---|
| 产物验收脚本独立成 `tools/package_artifact_smoke.sh` | 与 `tools/package_tarball.sh` 同一真相源；PR 与 Release 调同一份 |
| PR 阶段就验真产物 | `ci.yml` 新增 job：打包 → 解包 → 跑整套 `tests/run.sh` → CLI 三连（doctor/new/demo） |
| 跨版本升级矩阵 | 用已发布旧版本建工程，再用当前 CLI 升级；离线时显式 skip 而不是假绿 |
| DEB/RPM 原生验证 | 已有 `packages.yml` + native smoke；补「装后可执行 / 卸载零残留」的判据引用 |

退出条件：故意漏掉一个打包文件时，**PR 阶段的 CI 必须红**（自证）。

**结果**：把 `.gitignore` 从 tarball 里删掉，脚本以 `rc=1`、
`FAIL: the release tarball is missing .gitignore` 当场失败；跨版本矩阵实测
`0.20.0 / 0.23.0 / 0.24.1 / 0.24.2 → 当前` 全部通过。

### v0.26.0 —— 发版原子性与卸载所有权（已发布 2026-11-16）

两处 P0 都是「静默」类：发布在验签之前就把资产挂出去、卸载把用户自己的文件一起删掉。

| 交付 | 判据 |
|---|---|
| 发布改成 draft → 独立验签 → 公开 | `tests/test_release_publish_order.sh`：自证分支去掉 `--draft`、对调验签与公开两步，判据必须红 |
| 卸载只删「我们装的、内容还是原样」的 | `tests/test_install_ownership.sh`；`--purge` 整体清理；与 `install-self` 共用 prefix 锁 |
| 签名覆盖全部资产，验签「一个都不能少」 | `tools/verify_release.sh` 逐个验已发布资产，缺一份即红 |
| 签名 job 必须自己装工具 | `tests/test_release_signing_tool.sh`：凡是调用 `sign_release.sh` 的 job，同一 job 内必须先装 `minisign` |

**结果**：v0.26.0（`89ba66e`）13 项资产全部签名，`draft=false` 在验签通过之后才置位；
卸载语义变化按 minor 处理，`docs/MIGRATING.md` 有对照表。

**遗留与后续**：该版缺 `.deb` / `.rpm` —— `packages` job 因缺 `minisign` 失败，
又被 `continue-on-error` 吞掉，发布说明里已如实标注；修法（job 自装工具）+ 结构判据见 #120。

### v0.26.1 —— 系统包 job 的两处附产品（已发布 2026-11-16）

这一版本身只随 `packages` job 的修复出车，但它把「可选 job 也会静默失败」这件事钉住了。

| 交付 | 判据 |
|---|---|
| 每个签名 job 自己装 `minisign` | `tests/test_release_signing_tool.sh`：凡是调用 `sign_release.sh` 的 job，同一 job 内必须先装工具 |
| `sign_release.sh --file` 点名补签不要求清单整份齐全 | 点名模式跳过整份 `SHA256SUMS` 枚举；补签场景下 `dist/` 天然只有一部分资产 |
| 迟到的 deb/rpm 用点名模式补签 | `release.yml` 的 `sign the packages` 传 `--file`；签名覆盖与 tarball 同口径 |

**结果与未完成项**：v0.26.1 的 13 项主资产全部签名、`draft=false` 在验签之后才置位；
但 `packages` job **仍然失败**，原因换成了「`--file` 补签仍在要求 `SHA256SUMS` 整份齐全」
（`SHA256SUMS lists a missing file: shellkit-skill-0.26.1.tar.gz`）—— 该修在 `569df9a` 才进 main，
**0.26.1 的 tag 不含它** ⇒ 这一版依旧没有 deb/rpm。系统包随下一版恢复；
发完必须亲自看一眼 `gh release view` 的资产清单，`continue-on-error` 不会替你看。

### v0.26.2 —— 补签语义修复（已发布 2026-11-16）

| 交付 | 判据 |
|---|---|
| `--file` 点名模式跳过整份 `SHA256SUMS` 枚举 | `tests/test_release_signature.sh` 双向：partial dist + `--file` 必须成功；同一份 dist 不点名仍必须以 `lists a missing file` 拒签 |
| 系统包恢复 | `v0.26.2` 17 项资产（含 `.deb` / `.rpm`）全部签名；`tools/verify_release.sh v0.26.2` 逐项验过，`rc=0` |

`packages` job 三个 job 全绿（quality gate → build/verify/publish → deb/rpm），
两版缺包在 `v0.26.2` 收口：`gh release view v0.26.2` 的资产清单里有 `.deb` / `.rpm` 且各带 `.minisig`。

### v0.27.0 —— 1.0 契约（已落地，待发布）

这一批不加功能，只补「1.0 一发出去就没有回头路」的那几件事：承诺面、取消重跑的
发布门禁、以及「可选 job 失败不许静默」的自检。

| 交付 | 判据 |
|---|---|
| **兼容承诺文档** `docs/COMPATIBILITY.md` | semver 口径、什么算破坏性变更、弃用窗口（至少一个 minor）、experimental 边界；`tools/check_compatibility.sh` 对账小节、分级数量与豁免名单 |
| **每个公开函数都有等级** | 162 个公开函数：50 `stable` / 112 `experimental`；`tools/stability_exempt.txt` 清空并禁止回填；`tools/api_baseline.sh` 三规则 + 基线重生成 |
| **取消检查有限自动重跑** | `tools/release_gate.sh`：`completed/cancelled` 时从 `details_url` 取 run id，每个检查最多重跑一次；重跑后仍取消 ⇒ 失败（fail-closed）。`tests/test_release_gate_cancelled.sh` 十个场景（成功、再次取消、`--no-rerun`、无 URL、绿路径不受影响、查询失败、URL 不是运行页、run id 非法、检查名带路径分隔符、`gh` 不认 `--failed` 退回整轮重跑） |
| **门禁不许「零检查通过」** | 结论不再经临时文件中转 —— 那条路在文件写不出来时会数出 0 条 ⇒ 打出 `verdict: PASSED — all 0 required checks succeeded` 并放行（查不了状态却放行）；清单为空也从「静默通过」改为用法错（退 2）。判据在 `tests/test_release_gate.sh`（含把旧实现放回去必须变红的自证） |
| **可选 job 失败不再静默** | 新增 `tools/release_selfcheck.sh` + `release.yml` 的不可选 `self-check` job：等 `packages` 跑完，逐项点名主资产 / 签名 / deb+rpm，缺一个就红；`tests/test_release_selfcheck.sh` 含结构判据与自证 |
| **升级矩阵加格与生命周期** | 默认版本补 `0.26.2`；每个版本多跑一圈 `install-self → uninstall-self → 重装 → 用装出来的 CLI 再升级`；`docs/RELEASING.md` 要求 1.0 前连续三次全矩阵绿并留证据 |

退出条件：`make check` 全绿（含新增 compatibility-check）、CI 全矩阵绿、
升级矩阵在 `0.20.0 / 0.23.0 / 0.24.1 / 0.26.2` 四格上全部通过且 lifecycle 一圈全过。

### API 与配置契约冻结（已随 v0.25.0 发布）

> **关于版本号**：v0.25 / v0.26 / v0.27 三批改动是同时合入 main 的，而 CHANGELOG 由
> 「距上个 tag 的提交」生成 —— 分别打三个 tag 会让 v0.25.0 的条目包含后两批、后两个变成空条目。
> 所以它们随 **v0.25.0** 一起发布（`ce23822`，13 项资产、全部签名）。本节的「Planned」清单一律按
> 实际代码状态维护，不靠版本号表达进度。

当前 162 个公开函数里 50 个是 Stable。目标不是把所有函数都升 Stable（那会锁死演进），
而是把核心能力钉死：Filesystem、Config、Run、Lock、Retry、Error、Validate、OS、CLI。

| 交付 | 判据 |
|---|---|
| 核心模块的 Stable 扩充 | 每个 Stable 函数写明：返回码、stdout/stderr、环境变量、副作用、幂等性 |
| 破坏性行为的契约化 | `fs_*` / `conf_*` 的「失败后磁盘状态」写进 `docs/REFERENCE.md` 并由基线钉住 |
| 清单契约测试 | 三类清单的 schema 版本前向/后向兼容各有一条用例 |

退出条件：Stable 集合的每一次行为变化都必须进 `docs/MIGRATING.md`，否则门禁红（已有机制，
gates 兜底，只需扩集合）。

### 供应链与运维体验（已随 v0.25.0 发布）

| 交付 | 判据 |
|---|---|
| 签名从可选改为必需 | `sign_release.sh --require`：没配私钥以 **3** 失败，不产出「看起来一样、其实没签」的发行版 |
| 公开前独立验签 | 从 **draft** Release 重新下载资产，用 `docs/TRUST.md` 固定公钥逐份验签并与 `SHA256SUMS` 对账；验不过不置 `--draft=false` |
| 诊断与恢复体验统一 | `doctor` / `repair` / `doctor --json` 的字段与措辞一致，有对账用例 |

退出条件：一次完整发布里，「下载 → 验签 → 安装 → 升级 → 卸载」全部由脚本自动判过。

### v1.0.0 —— 稳定发行版（Planned）

只保留六条不能妥协的条件，其余都是加分项：

1. 用户改过的文件在安装、升级、同步、卸载与恢复失败时，不被静默覆盖或删除；
2. 关键故障路径有独立的文件哈希、清单与磁盘终态测试；
3. 已声明的 Stable API 在兼容范围内行为一致（`docs/COMPATIBILITY.md` + `compatibility-check`，
   v0.27.0 起每个公开函数都有等级）；
4. PR 与 Release 对同一类真实发行产物执行验收；
5. 正式发布资产有签名、不可静默替换，且能独立验证；
6. 多平台 CI 持续稳定，真实发行包在目标系统上通过安装、升级、卸载验证
   （v0.27.0：取消自动重跑一次 + 发布后资产自检 + 连续三次全矩阵绿；lifecycle 一格已进矩阵）。

## 三、战略取舍

**值得继续投入**：Bash 工程标准化 —— 让运维、部署、安装与自动化脚本具备一致的
错误处理、文件安全、测试、升级与发行规范。这是 ShellKit 最清晰的定位。

AI Skill 是重要的分发与开发入口（让 AI 编码工具生成符合 ShellKit 约束的代码），
但**不把 ShellKit 做成通用 Agent 平台或任务编排系统** —— 那会吃掉 Bash 3.2 兼容与
轻量化优势。

**不吸收的能力**：跨主机编排、声明式资源管理、长生命周期控制循环
（Ansible / Taskfile / Go Task / Kubernetes 运维控制器的范畴）——
这些不属于 ShellKit 最有竞争力的范围。

## 四、迭代节奏（教训写成规则）

v0.18.0 一次性引入六个门禁、同时制造 11 个跨平台红灯 —— **速度不能以「跨平台不可复现」
为代价**。以后固定走这条线：

    一个版本确定少量核心目标
      → 先建立可复现测试（本机 + 至少一个容器）
      → 分批合并（每批都能独立回滚）
      → 全矩阵通过
      → 最后发布

配套纪律：

- 新门禁**先在 Linux 与 macOS 各跑一次再合**；失败日志必须能看到第一因；
- 判据不许依赖 Runner 预装的软件集合（#72 就是这么红的）；
- **重活用例在机器负载高时会假红**：单文件时限（默认 300 秒）撞上时表现为没有 `FAIL:`
  明细的 `FAILED: <file>`。判红前先看 `uptime`，并在空闲机或容器里复验一次，
  否则会去修一个不存在的缺陷；
- **本地开发用 `TEST_TIMEOUT=<n>` 放宽单文件时限**，而不是改测试本身；
- 发布前必须验**真产物**（见 v0.25.0），只验工作树是不够的。
