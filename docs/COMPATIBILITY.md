# 兼容性与弃用政策

状态：自 **v0.27.0** 起生效，v1.0.0 发布时冻结。本文回答三件事：
**什么算破坏性变更**、**弃用要提前多久**、**哪些函数根本没有承诺**。

规则不是靠自觉：每一条都指得到机器判据（见文末「判据在哪」）。
判据与本文冲突时以判据为准，并修本文 —— 一份没人执行的承诺等于没有承诺。

## 一句话

- **1.0 之后**：`stable` API 在同一个 major 内行为不变；破坏性变更只能进 major。
- **0.x 期间**：默认只加不改；一旦**改变既有结果**，升 **minor** 并在
  `docs/MIGRATING.md` 的「会改变结果的行为变化」表格里声明 —— 这条已有门禁兜底。
- **`experimental` 面**：不承诺兼容，随时可变；但**不许静默消失**（删除/改名仍要声明）。

## 版本号语义

| 位 | 允许装什么 | 判据 |
|---|---|---|
| **patch** | 只修缺陷，且**不改变任何公开函数的结果**（退出码、stdout 数据、产出文件名、配置键、清单 schema、CLI 形状） | 行为基线对不上就红（`tools/api_baseline.sh`） |
| **minor** | 新增能力；或**改变既有结果**并写进迁移表；或把 `experimental` 升为 `stable` | 迁移表声明与基线声明版本对账 |
| **major** | 删除/改名 stable 函数、收紧参数、改清单 schema、换默认值 | 1.0 起才存在；0.x 无 major 位可用，等价变化走 minor + 迁移表 |

**预发布版本**（`x.y.z-rc.N`）：比同核心的正式版旧；`ver_cmp` 按 semver 口径比较
（同核心时正式版 > 预发布，`rc.2 > rc.1`，数字段按数值、数字段 < 字母段）。
预发布**不占用** `releases/latest` —— `install.sh` 的默认路径永远指向正式版，
装 RC 要显式给 `VERSION=x.y.z-rc.N`。

**「行为」的边界**（这些算结果，改了就要按上表处理）：

- 退出码集合（`@exitcode` 承诺的那组）；
- **stdout** 的内容与格式（stdout 只给数据，`v=$(conf_get KEY)` 必须干净）；
- 产出的文件名、路径、目录布局（vendor 副本、安装清单、man 页、脚手架产物）；
- 配置键、环境变量名、清单 schema 键；
- CLI 子命令名、选项名、参数个数与顺序。

**不算结果的东西**（允许在 patch 里改）：

- **stderr 的日志措辞**与译文（日志是给人看的；本仓库内断言日志文案的用例不外泄）；
- 内部私有函数（`_` 开头）、模块内部的变量名；
- 性能、内存占用（只承诺「跑得完」，除非迁移表另说）。

## 每个公开函数都有承诺等级

源码注释里紧邻函数定义的 `@stability` 行就是**唯一真相源**，两个取值：

| 等级 | 含义 | 当前 |
|---|---|---|
| `stable` | 行为、返回码、产出物在兼容范围内保持不变；变化要 major（0.x 走 minor + 迁移表） | 78 个 |
| `experimental` | 可以用，但**不承诺兼容**：签名、返回码、产出物都可能在下个版本变；变更仍写迁移表 | 106 个 |

投影（都能用命令重算，别手改）：

- `tools/api_baseline.txt` 的第 8 列是分级投影；
- `docs/REFERENCE.md` 每个函数末尾都有「稳定性：」一行，由 `./shellkit docs` 生成；
- `tools/stability_exempt.txt` **必须为空** —— 空表示「没有未分级的公开函数」。

> 表里数的是**主库**（`lib/core/`）的公开函数。POSIX 子集（`lib/posix/`）的函数
> 不在这个分级里 —— 它们不在承诺面内，理由见上一节的「1.0 的承诺边界」。

**从 experimental 升 stable** 是承诺扩张：必须走一个 minor，写进迁移表，并补齐该函数的
`@exitcode`、探针与 `docs/STABLE-CANDIDATES.md` 的三条入选标准。
晋升之后还要重生成 [`docs/API-FREEZE.md`](https://github.com/yi-nology/shellkit/blob/main/docs/API-FREEZE.md) —— 那是 1.0 承诺面的快照
（表内函数的返回码、退出码表、CLI 形状），门禁会要求它与源码一致。
**反向（stable → experimental）在 1.0 后等于破坏承诺**，只能 major；0.x 期间允许，但要声明。

## 弃用流程

弃用不是删除的同义词。顺序固定：

1. **先声明**：在源码注释里写 `@deprecated`（说明替代方案）并同步 `docs/MIGRATING.md`；
   `./shellkit docs` 会把注释放进 REFERENCE —— 用户查函数时能看到。
2. **保留至少一个已发布的 minor**：弃用声明进入某个 minor 之后，**至少再过一个 minor**
   才允许移除。0.27 声明、0.29 才删 —— 中间任何一个版本上，旧函数都必须照常工作。
3. **移除必须声明**：删除公开函数会让 `tools/api_baseline.sh` 变红，除非迁移表里有
   该函数的目标版本行。这一步是机器强制的，不靠评审记得。

窗口是「至少一个 minor」而不是日历时间：用户按版本升级，不按日期。

> 诚实的边界：**「弃用满一个 minor」这条靠迁移表与评审守**，没有自动判据 ——
> 纯 bash 拿不到「这个注解是哪天加的」这种历史。机器强制的只有两件事：
> 删除必须声明、每个公开函数必须有等级。

## 1.0 的承诺边界

发布 v1.0.0 即冻结当时 `stable` 的集合与本文的规则：

- **承诺**：Bash 3.2+ 基线、已测平台矩阵（macOS / Ubuntu / Debian / Rocky / openEuler）、
  退出码表、stdout 只给数据、日志只进 stderr、安装与卸载的所有权语义；
- **不承诺**：`experimental` 面、stderr 措辞、性能指标、`docs/` 里明确标注「计划」的能力；
- **不在承诺面内**：**POSIX 子集**（`lib/posix/`）—— 它是给设备侧（busybox ash / dash）
  的附属实现，与主库不共享代码。子集的契约是**能力清单**
  （`lib/posix/capabilities.tsv`）与它自己的测试，不是主库的稳定承诺。
  主库的承诺不自动延伸到子集；反过来，改主库的行为也**不承诺**同步改子集。
- **不在范围内**：跨主机编排、声明式资源管理、长生命周期控制循环（见 `docs/ROADMAP.md`）。

## 贡献者清单：改了一个公开函数之后

1. 判断是否改了「结果」（上表）；
2. 改了 ⇒ 升 **minor**，在 `docs/MIGRATING.md` 的「会改变结果的行为变化」表格加一行；
3. 跑 `bash tools/api_baseline.sh` —— 它会点名哪个函数没声明、哪份基线没重生成；
4. 跑 `./shellkit docs` 重生成 REFERENCE（否则 `make docs-check` 红）；
5. 跑 `bash tools/check_compatibility.sh` —— 本文的事实与源码对不上就红。

## 判据在哪

| 承诺 | 判据 |
|---|---|
| 每个公开函数都有分级，没有豁免 | `tools/api_baseline.sh`（三种取值规则）+ `tools/check_compatibility.sh`（豁免名单必须为空） |
| 返回码承诺与源码一致 | `tools/api_baseline.txt` 对账 + 探针实测 |
| 行为变化必须有迁移声明 | `_sk_ab_scan_migrating`：只认迁移表里反引号包住的函数名，版本必须新于上次声明 |
| 删除公开函数必须声明 | 同上（基线里 `removed` 状态只能在声明之后出现） |
| 本文与源码不漂移 | `tools/check_compatibility.sh` |
| 1.0 承诺面有可 diff 的快照 | `tools/api_freeze.sh --check`（`docs/API-FREEZE.md`） |
| 版本号投影一致 | `bash tools/check_versions.sh` |
