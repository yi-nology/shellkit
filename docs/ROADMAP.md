# ShellKit 路线图：三层架构与版本验收状态

状态：2026-11-21 更新（当前已发布 **v1.4.0**：POSIX/ash 侧的进程与看门狗原语 ——
设备侧那一层终于不用手写了；标签、17 项资产与系统包全部验签通过）。
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
| v0.27.0 | 1.0 契约批：兼容承诺 + 全量分级 + 取消重跑 + 发布自检 + 矩阵 lifecycle | `docs/COMPATIBILITY.md` + `compatibility-check`；162 个公开函数 50 stable / 112 experimental、豁免名单为空；`tests/test_release_gate_cancelled.sh`；`tools/release_selfcheck.sh` + 不可选 self-check job；`upgrade_matrix` lifecycle 一格 |
| v1.0.0-rc.1 | 预发布版本语义（semver 后缀）+ RC 真实验证 | `lib/core/ver.sh` 接受并排序 `x.y.z-pre`；`tools/rc_check.sh`（对输入工程只读、先复制再跑）+ `--test-cmd`；tag 含 `-` ⇒ `--prerelease` 不占 `latest`；RPM 预发布拆 `Version`/`Release` |
| v1.4.0 | POSIX/ash 侧的进程与看门狗原语（#162）：设备侧那一层终于进子集 | `lib/posix/shellkit-posix.sh` 的 `proc_start`/`proc_stop`/`proc_is_running`/`proc_watchdog`（同名同语义、返回码一致）；能力清单这四条 yes + 写清限制；判据 `tests/posix_smoke.sh`（**同一份 POSIX sh 脚本**在 dash 与 busybox ash 上原样跑，CI 必需检查「posix subset on busybox ash」）+ 三处变异自证 |
| v1.1.0 | skill 旧副本的升级通道（#140）：无所有权基线时不再静默不更新 | 措辞区分「用户改过」与「无所有权基线」；装完核对 `VERSION`，没跟上退 5 并点名 N 个文件 + `--force` 逃逸口；「装不成」仍是 3 |

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

### v0.27.0 —— 1.0 契约（已发布 2026-11-17）

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

**结果**：`bbfd9ea` 发车，`v0.27.0` 17 项资产（含 `.deb` / `.rpm`）全部签名，
`tools/verify_release.sh v0.27.0` 逐份验签通过；发布后自检
`tools/release_selfcheck.sh v0.27.0 --require-packages` 通过；从 Release 取回
`install.sh` 端到端装一遍（doctor / new / docs --check）全绿。CI 16/16；
分支覆盖棘轮 `whitelist 1011`、三条 `#42` 守卫臂全命中。

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

### v1.0.0 —— 稳定发行版（已发布 2026-11-18）

只保留六条不能妥协的条件，其余都是加分项：

1. 用户改过的文件在安装、升级、同步、卸载与恢复失败时，不被静默覆盖或删除；
2. 关键故障路径有独立的文件哈希、清单与磁盘终态测试；
3. 已声明的 Stable API 在兼容范围内行为一致（`docs/COMPATIBILITY.md` + `compatibility-check`，
   v0.27.0 起每个公开函数都有等级；承诺面另有可 diff 的快照
   `docs/API-FREEZE.md`，由 `api-freeze-check` 对账 stable 集合 / 返回码 / CLI 形状）；
4. PR 与 Release 对同一类真实发行产物执行验收；
5. 正式发布资产有签名、不可静默替换，且能独立验证；
6. 多平台 CI 持续稳定，真实发行包在目标系统上通过安装、升级、卸载验证
   （v0.27.0：取消自动重跑一次 + 发布后资产自检 + 连续三次全矩阵绿；lifecycle 一格已进矩阵）。
   RC 验证工具 `tools/rc_check.sh` 已就绪（对输入工程只读，先复制再跑；判据见
   `docs/RELEASING.md`）；证据：`~/unix_script`（vendor 0.17.0→RC/GA，含
   `tests/ci_run.sh --phase routing` 全量用例）与 `~/tools`（legacy 0.15.0→RC/GA，
   `vendor --force` 通道），两个真实项目各跑出 install/upgrade/uninstall 证据。

**结果**：`0ed8cd3` 发车，tag `v1.0.0`（GA，`releases/latest` 指向它）；
`v1.0.0-rc.1` 保持 Pre-release（`isPrerelease=true`、`latest=false`）。
17 项资产（含 `.deb` / `.rpm`）全部签名，`tools/verify_release.sh v1.0.0` 逐份验签通过、
`tools/release_selfcheck.sh v1.0.0 --require-packages` 通过；从 `releases/latest` 取回
`install.sh` 端到端安装（doctor / new / docs --check / 工程自测）全绿，且
`SHELLKIT_MINISIGN_PUBKEY` 配了公钥时强制验签通过；发布资产公钥与 `docs/TRUST.md`
钉住值逐字一致（跨渠道核对）。CI：`quality` 全矩阵绿（含 debian:12 / rockylinux:9 /
openeuler amd64+arm64 四个 compat 格），`release` 流水线两个 job 全 success。

### v1.1.0 —— skill 旧副本的升级通道（已发布 2026-11-18）

GA 之后的第一版，只修一个真缺陷：**旧版（清单机制引入前）装的 skill 副本，升级通道被永久冻结**。

| 交付 | 判据 |
|---|---|
| **措辞分类** | 用户改过的报 `modified locally`；**没有所有权基线**的（旧副本 / 基线丢失）报 `no ownership baseline, left alone (use --force to overwrite)` —— 混报会把人指向错误的修复动作 |
| **fail-closed** | 装完核对 `VERSION`：没跟上 ⇒ 退出码 **5** + 点名「N 个文件」+ 给出 `shellkit skill install --force` 逃逸口。**两处路径都查**（「没有要写的文件」的提前返回 + 正常提交路径） |
| **退出码分流** | 「装不成」（软链 / 包残缺 / 目录不可写）仍是 **3**；「装上了但版本没跟上」是 **5**（校验失败） |
| **核对基准** | 用「包里携带的 VERSION」而不是 `$SK_VERSION` —— 发行包里的版本可能与本机 CLI 不同，拿一把尺子量所有副本会把合法安装误判成失败 |

**结果**：PR #141 合并（`b2d4baf`）；判据承重做过反向验证（把两处核对分别撤掉，用例都转红）。
覆盖率棘轮的基线在 **ubuntu 同环境**重生成（分支 ID 含函数内顺序号，改函数里的分支会漂移；
环境分叉臂跨机器对不上），差异只落在 skill 安装相关条目。


### v1.2.0 —— 归档解包 + 演练不落盘（已发布 2026-11-19）

两块能力，都落在 1.x 兼容承诺之外（标 `experimental`）：**安全解包**与**演练不落盘**。

| 交付 | 判据 |
|---|---|
| **`archive` 模块** | `archive_extract`（校验 → 穿越检查 → 软链检查 → 暂存解 → 兜底扫描 → 整体换）与 `archive_list`；按魔数认 tar/tgz/tbz2/txz/zip，v7 老 tar（没有 ustar 魔数）走 `tar -tf` 兜底 |
| **解包的安全语义** | 校验不过 ⇒ 一个字节都不解；成员名带 `..` 或绝对路径 ⇒ 连解都不解；软链按**它自己所在目录**解析目标，解析后逃出归档 ⇒ 连解都不解；解完再扫实际文件系统兜底一遍（这一遍是权威判据） |
| **不留半份** | 解到暂存目录，全部通过才**整体换**进目标目录 —— 两次 rename，目标目录要么是旧的、要么是新的，不会停在新旧混合；包里没有的旧文件保留，包里有的以包为准 |
| **演练不落盘** | `SHELLKIT_DRY_RUN_FILES=1`：`fs_*` 与 `conf_*` 的写原语只把计划打到 stderr，一个字节都不写。**独立开关** —— 不动 `SHELLKIT_DRY_RUN` 的既有语义（默认行为零变化） |
| **退出码口径** | 0/2/3/5 全部写进 `@exitcode`：「包坏了」（列不出成员、解不开）归 **5**，「环境不对」（缺 tar/unzip、文件不存在、格式认不出）归 **3** —— 没有未声明的 1 |

判据承重做过变异验证：**16 个变异点，15 个把用例打红**；剩下 1 个（「提前拒绝对目标的软链」被去掉）
被第三遍兜住 —— 整体行为没变，不算缺口，但那一层是纵深防御不是唯一防线。

**结果**：PR #163 合并（`75d37e1`）。判据承重做过变异验证：拆掉「换上去之后才套权限」
那一行，用例立刻转红（expected 555, got 700）—— 断言有判据能力，不是恒真。

途中被 CI 与三轮独立审查抓出来的真缺陷：

1. **GNU tar 读到 EOF 就当归档结束、照样退出 0** ⇒ 截断的包被静默解成
   「只有前几个成员」，而调用方拿到的是成功 ⇒ 改为自己查 tar 的**结尾标记**，
   结论与 tar 的实现无关（bsdtar 更严、GNU tar 更松，同一个包在两边给出不同
   答案本身就是缺陷）。
2. **macOS 15 上重命名一个不可写的目录会失败**（Linux 不会，内核要改写目录里
   的 `".."` 条目）⇒ 只读目标目录在 macOS 上退 5、好包被判成坏包 ⇒ 改为
   暂存目录全程保持可写、目标目录的权限在**换上去之后**才套、搬走旧目录前
   临时加 `u+w` 并在事后还原（用户的数据不该因为我们搬过它就变了权限）。
3. **root 能绕过权限检查** ⇒「旧内容回填失败」那条用例在 Linux CI 上本是假红
   ⇒ 改为按环境各断言各自的真实结果（不是「看情况放过」），并把 stderr
   塞进断言消息 —— 失败现场能直接看出是哪一步失败。
4. **干跑吞掉前置条件与安全判定** ⇒ 守卫统一后移到检查之后：演练也要把
   「这个包安不安全」判出来。

覆盖率分支基线在**runner 上**重生成（基线是运行时结论，换环境就换一份未覆盖
集合；本地 macOS/arm64 生成的必然对不上），并与 CI 棘轮输出逐条对账：
「不在基线里」的 90 条全部进了新基线，「已被覆盖」的 23 条全部不在了。


### v1.4.0 —— POSIX/ash 侧的进程与看门狗原语（#162，设备侧那一层，已发布 2026-11-21）

设备侧（NAS 的 start/stop、OpenWrt 的 init）是「装机即执行」的：改坏的现场装不了
shellkit 补救 ⇒ 那边的脚本必须是**最保守**的那一份。#144 交付了 POSIX/ash 子集，
但**进程层明确没进子集** —— 而它恰好是设备侧启动脚本的另一半：
「后台引导 + 整组停止 + 探活自愈」这三件事，设备侧至今只能手写。

| 交付 | 判据 |
|---|---|
| **同名同语义的 `proc_*`** | `proc_start` / `proc_stop` / `proc_is_running` / `proc_watchdog` 在 POSIX 子集里**同名**提供，返回码与主库一致（0/1/2/3）⇒ 设备侧脚本与 bash 侧用同一套调用 |
| **后台引导** | 脱离终端三级退化（`setsid` > `nohup` > 子 shell 忽略 SIGHUP）、pid 文件**原子写**（由子进程自己写 ⇒ `setsid` fork 时也不会记错 pid）、日志**追加**不截断 |
| **整组停止** | 拿得到进程组就整组停；拿不到就**明确退化成只停主进程** —— 宁可留子进程，也不能自杀（`kill` 打到自己的组上会静默自杀，退出码 143） |
| **探活判据** | 不能只用 `kill -0`（**僵尸假阳性**：僵尸还在进程表里，`kill -0` 仍然成功）⇒ 读 `/proc/<pid>/stat` 的状态位，`Z`/`X` 判死；查不到状态时退化成 `kill -0`（判据变粗，但不误杀） |
| **看门狗** | 探活失败与超时分开；重启带退避（1→2→4…，上限可配）；连续失败到上限**放弃并返回非 0**（无人值守设备上「放弃了」必须有人看得见） |
| **能力清单** | `lib/posix/capabilities.tsv` 里这四条标 `yes`，且第三列**写清限制**（不再是 `-`）：没有作业控制、靠 setsid 拿进程组、查不到状态时的退化 |
| **真环境验证** | 判据本体是一份 POSIX sh 脚本（`tests/posix_smoke.sh`）⇒ 同一份在 dash 与 **busybox ash** 上原样跑；CI 新增必需检查「posix subset on busybox ash」 |

判据有承重：脚本内做**变异自证**（三处：僵尸判定 / 自杀守卫 / 组长守卫），
每处都带**形状守卫**（变异必须真的落到源码上，否则「断言没变」与「缺陷没造回去」
分不开）；bash 侧再验一层「把库的僵尸判定改坏 ⇒ 判据必须变红」。

途中被实测纠正的三条**原本想当然**的写法（busybox 1.36 容器里逐条验的，不是推测）：

1. `kill -TERM -- -PGID` 在 **busybox 与 dash 上都不成立**（前者报
   `invalid number '--'`，后者报 `Illegal number: -`）⇒ 两种写法都试，
   先带 `--`（bash 认），失败再不带（busybox/dash 认）。
2. **busybox 的 `ps` 不认 `-p`**（`invalid option -- 'p'`），也不认 `stat=`
   的表头抑制 ⇒ 状态与进程组改读 `/proc/<pid>/stat`，`ps` 只当兜底。
3. **`setsid` 在「已经是组长」时会 fork** ⇒ 父进程拿到的 `$!` 可能是
   setsid 的 pid 而不是真正那条命令的 pid ⇒ pid 改为**子进程自己写**
   （exec 不改 pid ⇒ 写的必然是它）。

另有一条**判据自身的假绿**被当场抓住：POSIX 子集自己有一个公开的 `fail()`，
判据脚本再定义一个同名函数 ⇒ 被库的版本覆盖 ⇒ 失败计数永远不增 ⇒ 全绿。
⇒ 判据脚本里的辅助函数必须用**独占前缀**，且不能与被测库的公开函数重名。


### v1.4.1 —— POSIX 子集与 bash core 的语义分叉（#171 / #172 / #173 / #174）

同一套 API 写成两份实现时，**差集就是缺陷清单**。v1.4.0 交付了进程层之后，
POSIX 子集与 bash core 的重叠面变大 ⇒ 用「同一题问两份实现、把输出并排贴在一起」
的方式对拍一遍，挖出四条真分叉：

| issue | 现象 | 修法 |
|---|---|---|
| #171 | `lock_release` 不从 trap 栈摘除 ⇒ 退出清理删掉**别人**持有的锁 ⇒ 互斥静默失效 | 清理栈加「按内容摘除」；`lock_release` 只删自己持有的锁（持有者 pid 不是自己就拒绝，返回 3） |
| #172 | `lock_acquire` 在 mkdir 因别的原因失败时**无限循环且零输出** ⇒ 设备侧静默挂死 | 分开「锁被占」与「建不出来」：后者立刻报错返回 3（不重试） |
| #173 | `ver_cmp` 不认 v 前缀与预发布后缀 ⇒ 同一个调用在两边结果不同 | 补齐：剥 v/V 前缀、核心与预发布分开比、正式版 > 同核心预发布、后缀逐段比 |
| #174 | `retry` 丢了白名单 / 延迟上限 / 超时分类 | 补齐 `SHELLKIT_RETRY_ON` 白名单、退避与上限（**首个延迟也要夹**）、退出码分类、用法错不重试 |

顺带修掉一个**只有真解释器才暴露**的缺陷：POSIX 子集里用了 `$((10#08))`（去前导零，
bash 扩展）—— macOS 的 bash 上一切正常（本机全绿），dash 上却报算术错误、
那一行变成**空字符串**而函数**仍返回 0** ⇒ 版本比较静默返回空。已写进坑表第 32 条。

判据 `tests/posix_semantics.sh`（一份**只用 POSIX sh 语法**的脚本 ⇒ 同一份在 dash
与 busybox ash 上原样跑），四条都有**负对照**：把缺陷造回去，判据全部变红。

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
