# ShellKit 路线图：三层架构与版本验收状态

状态：2026-11-16 按**实际发版**重写（v0.24.1 已发布）。本文是**方向**，不是承诺 ——
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

### v0.24.2 —— 数据安全收口（In Progress）

| 交付 | 判据 |
|---|---|
| `_sk_own_sync` 的暂存/恢复失败不再被 `|| true` 吞掉 | 搬不动 ⇒ 整轮失败；恢复缺件 ⇒ 整轮失败；写回后 `os_sha256` 自检 |
| 故障注入钉住这条路径 | `test_fault_matrix.sh` 的 `vendor|keep-fail` 格：注入点选 `TMPDIR`，只有「搬进暂存区」失败 |
| 自检：把缺陷造回去必须变红 | 还原成 `|| true` 后同一条用例必须报「搬不动却返回 0」 |

退出条件：上述三格全绿，且 `make check` 与 CI 全矩阵通过。

### v0.25.0 —— 发布质量前移（Planned）

v0.24.0 暴露的缺口是：源码矩阵全绿、系统包构建也全绿，但**真产物**解包后跑套件才炸
（tarball 漏了 `.gitignore`）。说明「仓库工作树能跑」不等于「发布包能跑」。

| 交付 | 判据 |
|---|---|
| 产物验收脚本独立成 `tools/package_artifact_smoke.sh` | 与 `tools/package_tarball.sh` 同一真相源；PR 与 Release 调同一份 |
| PR 阶段就验真产物 | `ci.yml` 新增 job：打包 → 解包 → 跑整套 `tests/run.sh` → CLI 三连（doctor/new/demo） |
| 跨版本升级矩阵 | 用已发布旧版本建工程，再用当前 CLI 升级；离线时显式 skip 而不是假绿 |
| DEB/RPM 原生验证 | 已有 `packages.yml` + native smoke；补「装后可执行 / 卸载零残留」的判据引用 |

退出条件：故意漏掉一个打包文件时，**PR 阶段的 CI 必须红**（自证）。

### v0.26.0 —— API 与配置契约冻结（Planned）

当前 162 个公开函数里 37 个是 Stable。目标不是把所有函数都升 Stable（那会锁死演进），
而是把核心能力钉死：Filesystem、Config、Run、Lock、Retry、Error、Validate、OS、CLI。

| 交付 | 判据 |
|---|---|
| 核心模块的 Stable 扩充 | 每个 Stable 函数写明：返回码、stdout/stderr、环境变量、副作用、幂等性 |
| 破坏性行为的契约化 | `fs_*` / `conf_*` 的「失败后磁盘状态」写进 `docs/REFERENCE.md` 并由基线钉住 |
| 清单契约测试 | 三类清单的 schema 版本前向/后向兼容各有一条用例 |

退出条件：Stable 集合的每一次行为变化都必须进 `docs/MIGRATING.md`，否则门禁红（已有机制，
gates 兜底，只需扩集合）。

### v0.27.0 —— 供应链与运维体验（Planned）

| 交付 | 判据 |
|---|---|
| 签名从可选改为必需 | 正式 Release 缺签名直接失败（当前允许无签名发行） |
| 发布后独立验签 | 从 GitHub Release 重新下载资产，用 `docs/TRUST.md` 固定公钥验签 |
| 诊断与恢复体验统一 | `doctor` / `repair` / `doctor --json` 的字段与措辞一致，有对账用例 |

退出条件：一次完整发布里，「下载 → 验签 → 安装 → 升级 → 卸载」全部由脚本自动判过。

### v1.0.0 —— 稳定发行版（Planned）

只保留六条不能妥协的条件，其余都是加分项：

1. 用户改过的文件在安装、升级、同步、卸载与恢复失败时，不被静默覆盖或删除；
2. 关键故障路径有独立的文件哈希、清单与磁盘终态测试；
3. 已声明的 Stable API 在兼容范围内行为一致；
4. PR 与 Release 对同一类真实发行产物执行验收；
5. 正式发布资产有签名、不可静默替换，且能独立验证；
6. 多平台 CI 持续稳定，真实发行包在目标系统上通过安装、升级、卸载验证。

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
