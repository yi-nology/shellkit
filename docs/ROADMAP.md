# ShellKit 路线图：三层架构与四个阶段

状态：2026-11-13 起草。本文是**方向**，不是承诺 —— 每个阶段的退出条件写清楚，
条件不满足就不进下一阶段（见「迭代节奏」）。

## 一、目标架构：三层，单向依赖

    Developer Experience   CLI · Scaffold · AI Skill · Docs · Release
    Engineering Contracts  API Baseline · Security Policy · Ownership · Recovery · Quality Gates
    Bash Runtime Core      Filesystem · CLI · Process · Network · Config · Logging · OS

- **依赖方向只能向下**：上层可以调下层，下层永远不知道上层存在。
- **工程工具不能成为运行库的强制依赖**：`lib/core/*.sh` 被别人的工程 vendor 走时，
  不该因为 `tools/` 里的门禁脚本缺失而跑不起来。门禁只在本仓库的 CI 里存在。
- 这条约束当前是成立的（`lib/` 不引用 `tools/`），写在这里是防止以后被无意破坏。

## 二、四个阶段

### 阶段一 · v0.18.0 —— 稳定性收口（当前阶段）

这一阶段**不加新功能**，目标只有一个：让全部 CI 恢复稳定。

背景：v0.17.0 → v0.18.0 一次性引入了 API 基线、安全扫描、性能基准、JSON 诊断、
错误上下文、故障注入六件事，结果 2026-11-12 的质量矩阵从 13/13 掉到 **3/14**
（[run 43238779798](https://github.com/yi-nology/shellkit/actions/runs/43238779798)）。
五条根因已定位并提单：

| issue | 失败签名 | 影响 job |
|---|---|---|
| #71 | `tar: This does not look like a tar archive` / `cannot create the repo copy` | compat ×4、coverage ratchet |
| #72 | `expected the optional dependencies to be reported missing, got <1>` | test on ubuntu ×3 |
| #73 | `expected <5>, got <1>`（门禁契约里没有 1） | test on macos ×2 |
| #74 | `perm.mode: ... File: "/tmp/..."`（GNU `stat -f` 的文件系统输出当权限） | performance bench |
| #75 | 性能 Job 与功能测试耦合，结论易误读 | 报告口径 |

**退出条件**：

- 14 个质量 Job 全部通过，且是**连续多次**通过（一次绿不算数）；
- Pages 部署独立恢复；
- 关键门禁在 macOS Bash 3.2、Ubuntu、Debian、Rocky、openEuler 上有可重复的通过记录；
- 每条红灯都能指到「第一因」，不再出现被二次错误掩盖的日志（#71 的教训）。

以上满足后才正式发布 v0.18.0。

### 阶段二 · v0.19.0 —— 工程契约稳定化

把已经建好的质量体系转成**长期兼容承诺**：

- **Public API 分级**：Stable / Experimental / Internal。
  Stable 明确函数签名、返回码、stdout/stderr、环境变量、副作用与兼容性策略；
  只有 Stable 进入 `docs/MIGRATING.md` 的行为变化表。
- **Manifest Schema 版本管理**：`.shellkit-manifest`、`.shellkit-skill-manifest`、
  vendor 清单都要有版本号与迁移路径 —— 老版本生成的工程、vendor 副本、skill
  必须能安全升级到新 schema，而不是「认不出来就当没装」。

### 阶段三 · v0.20.0 —— 性能与开发体验

- 四条高频路径优化：**启动、scaffold 生成、vendor 同步、upgrade**。
  已有收益来自 registry 内存快照（48ms/次 → 0.9ms/次）；后续**不盲目缓存全部模块**，
  用 `tools/bench.sh` 定位频繁 fork、重复读盘、模块加载成本，按数据决定。
- 开发体验：CLI 自动补全、诊断导出（`doctor --json` 已有基础）、项目自检、
  升级差异预览。

### 阶段四 · v1.0.0 —— 稳定发行版

不以模块数量为门槛，满足以下条件才发：

- 核心公共 API 进入明确的稳定性承诺；
- Install / Upgrade / Vendor / Skill / Repair 的文件保护机制完成统一
  （已经统一在 `fs_*` 原语与所有权清单上，v1.0 前把残余的重复实现收干净）；
- 故障注入覆盖关键数据修改与恢复路径；
- 各平台完整测试矩阵**持续**稳定；
- Release 可追溯到经过验证的源码、构建环境与资产校验记录；
- 文档、示例与迁移指南和代码保持一致。

## 三、战略取舍

**值得继续投入**：Bash 工程标准化 —— 让运维、部署、安装与自动化脚本具备一致的
错误处理、文件安全、测试、升级与发行规范。这是 ShellKit 最清晰的定位。

AI Skill 是重要的分发与开发入口（让 AI 编码工具生成符合 ShellKit 约束的代码），
但**不把 ShellKit 做成通用 Agent 平台或任务编排系统** —— 那会吃掉 Bash 3.2 兼容与
轻量化优势。

**不吸收的能力**：跨主机编排、声明式资源管理、长生命周期控制循环
（Ansible / Taskfile / Go Task / Kubernetes 运维控制器的范畴）——
这些不属于 ShellKit 最有竞争力的范围。

## 四、迭代节奏（本轮的教训写成规则）

前几轮证明 ShellKit 能快速补齐评审发现的缺陷；但 v0.18.0 一次性引入六个门禁，
同时制造了 11 个跨平台红灯 —— **速度不能以「跨平台不可复现」为代价**。

以后固定走这条线：

    一个版本确定少量核心目标
      → 先建立可复现测试（本机 + 至少一个容器）
      → 分批合并（每批都能独立回滚）
      → 全矩阵通过
      → 最后发布

配套纪律：新门禁**先在 Linux 与 macOS 各跑一次再合**；失败日志必须能看到第一因；
判据不许依赖 Runner 预装的软件集合（#72 就是这么红的）。
