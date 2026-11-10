# 批次 4 收口：把「测什么」变成可测量的

- 依据：`reports/ROADMAP-0.12.0.md` 批次 4 的 4.2 / 4.3 / 4.4（评审 P2）
- 版本口径：**patch 够用**。这三项只加工具、测试与流水线，**不改任何既有公开函数的
  结果**（退出码 / 产出文件名 / 输出文本都不变）⇒ 不需要升 minor，不进 `docs/MIGRATING.md`。
  ⚠️ 若实施过程中发现必须改既有行为，**停下来报给协调者**，不要自行升版本。
- 为什么不升版本：`VERSION` 当前是 0.12.1（已发布）。本计划的产物是「开发者工具」，
  对库的使用者零影响。

## 目标（一句话）

三件事，缺一不可：

1. **知道哪块没被测到**（4.3 覆盖率）—— 出报告，不靠猜。
2. **知道回归网有没有判据能力**（4.4 变异测试）—— 把已修的缺陷造回副本，回归用例必须变红。
3. **知道换台机器还成不成立**（4.2 ARM64 + 国产系统流水线）。

## 全局约束（每个任务都必须遵守）

- **Bash 3.2 基线**：禁 `declare -A`、`${v^^}`、`local -n`、`mapfile`；
  空数组遍历写 `${arr[@]+"${arr[@]}"}`。
- **stdout 只给数据，日志一律 stderr**。
- **出参用 `printf -v "$outvar"`**，函数不直接改调用方变量；出参名要过
  `_sk_check_out_name` / `_sk_is_name` 守卫。
- **公开函数上方必须紧邻注释块**（空行会被 shdoc.awk 丢弃）；结构化标签
  `@param` / `@exitcode` / `@see` / `@example`。
- **用户可见文案走 `_t 'english msgid'`**；本计划原则上不新增用户可见文案
  （工具的输出是给开发者的，走 stderr）。
- **不引入新的运行时依赖**（不许 jq / python3 / 其它二进制）。
- **shellcheck `-S warning -x` 干净；shfmt `-i 2 -ci` 干净。**
- **每个测试文件跑完 < 300 秒**（runner 的每文件上限；超时会被判失败）。
- **输出类断言三前提**：断完整文案而不是单词（否则路径会把断言白送）；
  临时目录名只用编号（如 `case.1`）；断言输出语言固定 `SHELLKIT_LANG=en`。
- **改坏文件一律用 bash 字符串替换**，不用 `sed -i`。
- **每道新门禁必须配自测**：造坏树必须变红；门禁自己崩了不能等于「一切正常」。
- **不碰别人的文件**：本计划的文件归属见下表；越界即失败。
- **提交逐路径 `git add`**，绝不 `git add -A`。

## 文件归属（互斥）

| 任务 | 独占文件 |
|---|---|
| T3 流水线 | `.github/workflows/ci.yml` |
| T2 覆盖率 | `tools/coverage.sh`、`tests/test_coverage.sh`、`tools/coverage_baseline.txt`、`Makefile` |
| T1 变异测试 | `tools/mutation.sh`、`tests/test_mutation.sh`、`Makefile`、`reports/PLAN-BATCH4-CLOSURE.md` |

**别人正在改、本计划一律不碰的文件**：
`lib/core/scaffold.sh`、`docs/MIGRATING.md`、`docs/REFERENCE.md`、`locale/**`、
`tests/test_scaffold.sh`、`docs/ai/repo.head.md`、`AGENTS.md`、`README.md`、`site/**`。

> `Makefile` 被 T2 与 T1 共用 ⇒ **两个任务必须串行执行**，后一个动手前先读前一个的改动。

## 共享工作树的纪律

同一个工作树里还有别的会话在改 `lib/core/scaffold.sh` 与 `locale/**`：

- **验证一律在隔离副本里做**：`git archive HEAD | tar -x -C <dir>` 起一份干净树，
  把自己的改动拷进去再跑。共享树上跑全量测试会读到别人的中间态 ⇒ 假红。
- **不要在共享树上跑 `make check`** 作为验收依据。
- macOS 上 `/tmp` 是 `/private/tmp` 软链 ⇒ 用 `/private/tmp/...` 真实路径。
- 本机 `~/.minimax/shims` 的 `rm` 是慢速回收站包装器 ⇒ 跑测试前
  `export PATH="$(echo "$PATH" | tr ':' '\n' | grep -v '.minimax/shims' | paste -sd: -)"`。

---

## Task 3（先做）：ARM64 + 国产系统流水线

### 为什么先做

它只需要 CI 才能验证（本地没有容器守护进程），而 CI 是异步的 ⇒ 先把它推上去跑，
等它出结果的同时做本地任务。

### 已核实的事实（不要重新查，直接用）

- 仓库是 **PUBLIC** ⇒ GitHub 托管的 ARM64 runner 免费可用。
- ARM runner 标签**确实存在**：`ubuntu-24.04-arm`、`ubuntu-22.04-arm`、`ubuntu-26.04-arm`。
  用 `ubuntu-24.04-arm`（GA 最久）。
- 镜像的架构清单（已用 registry API 逐个查过，manifest 里确实带这些架构）：
  - `openeuler/openeuler:24.03-lts-sp4` → **amd64 / arm64 / loong64**（龙芯 LoongArch）
  - `openeuler/openeuler:22.03-lts-sp4` → 同上
  - `openeuler/kylin:5.0.5-oe2403sp4` → amd64 / arm64（麒麟 Kylin V10）
- **Anolis OS 与 Kylin 官方镜像不在 Docker Hub**（`openanolis/anolis`、`openanolis/anolis8`、
  `anolisos/anolis`、`linuxdeep/kylin10`、`kylinsec/kylin` 全是 404）⇒ 不要引用它们。
- 现成的 `compat` job 已有的机制可复用：`container: ${{ matrix.image }}` + dnf 分支 +
  `sk_fetch` 下载器兜底（curl / wget / python3 任选其一）。

### 要做什么

1. `test` 矩阵加一行 `ubuntu-24.04-arm`（真 ARM64 硬件 runner，跑同一组 `make check`）。
   该 job 的装工具步骤已经有 `arm64 | aarch64) arch=aarch64` 分支，**不用改**。
2. `compat` 矩阵加三行：`openeuler/openeuler:24.03-lts-sp4`、
   `openeuler/openeuler:22.03-lts-sp4`、`openeuler/kylin:5.0.5-oe2403sp4`。
3. 装工具步骤要覆盖 openEuler/Kylin 的包管理器差异：这两个发行版是 **dnf 系**，
   但与 Rocky 不完全一样：
   - openEuler / Kylin 基础镜像**自带 curl** ⇒ 不要走 Rocky 那条「curl-minimal 冲突」的绕法；
   - 包名按 openEuler 官方仓核对过再写：`gettext`、`ca-certificates`、`tar`、`xz`、
     `make`、`grep`、`sed`、`gawk`、`findutils`、`diffutils`、`coreutils`、`gmp`、
     `ncurses-libs`。
   - **写之前用仓库元数据核对包名**（不要凭记忆）：
     `https://repo.openeuler.org/openEuler-24.03-LTS-SP4/everything/x86_64/Packages/` 里 grep。
   - `--allowerasing` 在 dnf4 上可用（openEuler 24.03 是 dnf4）⇒ 可以沿用 Rocky 那条写法。
4. **可选加分项（做不了就不做，别硬来）**：LoongArch（龙芯）跑测试需要 QEMU 用户态模拟
   （`docker/setup-qemu-action` + `docker run --platform linux/loong64`），不是
   `container:` job 能表达的 ⇒ 要单独开一个 job。模拟很慢且容易超时，**做不了就不做**。

### 验收

- `make check` 在共享树上**不要跑**；验证用隔离副本 + 本地 `bash -n` + `actionlint`（若有）。
- **真正的验收是 CI**：推上去后 `gh run watch` 看新 job 的结论。
- 新 job 红了**不要猜**：`gh run view <id> --log-failed` 看真实日志再改。
- 若某个镜像在 CI 里拉不动（网络/配额），**降级为「该发行版跳过并说明原因」**，
  不要让主分支常绿但 job 永远红。

---

## Task 2：覆盖率 —— 出「哪块没覆盖」

### 要做什么

- **函数级覆盖率**，不是行级。bash 的行级覆盖率要么靠 `set -x`（会污染 stderr，
  改行为，且 BASH_XTRACEFD 要 bash ≥ 4.1 而基线是 3.2），要么靠插桩；
  **函数级插桩最稳**：在每个公开函数体第一行插一句记录调用。
- `tools/coverage.sh`：
  - 用法：`bash tools/coverage.sh [--out FILE] [--suite CMD] [--min PCT]`
  - 做法：把库拷到临时目录 → 对**公开函数**插桩 → 跑测试套件 → 收集被调用过的函数名 →
    报「覆盖 M/N 个公开函数」+ 列出没被调到的。
  - 退出码：0 正常出报告；`--min` 不达标 ⇒ 1；用法错 ⇒ 2。
- **棘轮（ratchet）**：`tools/coverage_baseline.txt` 是「已知没被覆盖的公开函数」白名单。
  报告里出现的未覆盖函数**超出白名单** ⇒ 失败。这样「新加了一个没人测的公开函数」
  会被抓住，而「已知的老债」不阻塞。
- `tests/test_coverage.sh`（进 `make check`，必须快）：
  1. **机制自测**：造一个合成库（两个公开函数）→ 只调一个 → 报告必须显示 1/2 且点名另一个。
  2. **棘轮负对照**：白名单被人为删掉一条 ⇒ 必须变红。
  3. **白名单不腐烂**：白名单里的每个名字都必须是**现存的公开函数**（否则判红）。
  4. **对真库跑一遍**（只跑一个快的测试文件）⇒ 报告能生成、格式正确。
- `Makefile` 加 `coverage` 目标（**不进 `check`**，因为跑全套很慢）。
- CI 里可以加一个独立的 coverage job 跑全套并上传报告（本任务可选，冲突归 T3 后继）。

### 验收

- `make coverage` 能出一份可读的报告。
- `tests/test_coverage.sh` 自己跑完 < 300 秒，且**每道断言都有负对照**
  （造坏 ⇒ 必须变红）。
- 报告里未覆盖的函数名必须**逐字**对得上真实函数名（不许模糊匹配）。

---

## Task 1（最后做）：变异测试 —— 只做升级路径

### 为什么最后做

升级路径的代码在 `shellkit`（CLI 的 `cmd_upgrade`）与 `lib/core/scaffold.sh` 里，
而 `lib/core/scaffold.sh` **正被别的会话改** ⇒ 最后做，等对方提交完再动。

### 要做什么

- `tools/mutation.sh`：
  - 用法：`bash tools/mutation.sh --target FILE --test "CMD" [--min-score N] [--report FILE]`
  - 做法：把仓库拷到临时目录 → 枚举**变异位点**（目标文件里可安全改写的行）→
    逐个应用变异 → `bash -n` 校验（解析不过的变异**跳过**，不算分）→
    跑 `--test` 命令 → 非 0 退出码 ⇒ **KILLED**，0 ⇒ **SURVIVED**。
  - 输出：一张表（位点 / 运算符 / 结论）+ 变异得分 = KILLED / (KILLED + SURVIVED)。
  - 退出码：得分达标 ⇒ 0；不达标 ⇒ 1；用法错 ⇒ 2。
- **变异算子必须安全且确定**（只改语义，不改语法）：
  - 条件取反（`[ x = y ]` ⇒ `[ x != y ]`）
  - `||` ⇄ `&&`
  - `return 0` ⇒ `return 1`、`return 1` ⇒ `return 0`
  - 去掉一次 `local x=...` 的赋值（改成空）
  - 交换两个常量
  - **不允许**的：删函数、插 `exit 1`、改路径、改超时 —— 那些会让「变异」变成「破坏」，
    测出来的是「用例会不会崩」而不是「用例有没有判据能力」。
- `tests/test_mutation.sh`：
  1. **引擎自测**：合成目标 + 合成测试 ⇒ 引擎必须能报出 KILLED。
  2. **负对照**：引擎必须**也能报出 SURVIVED**（否则工具永远说「都杀死了」= 假绿）。
  3. **真campaign**：对升级路径跑一批**有界**的变异（≤ 12 个，保证 < 300 秒），
     断言杀灭率达标。
- `Makefile` 加 `mutation` 目标（**不进 `check`**）。

### 验收

- `make mutation` 能出一张表 + 一个分数。
- 三个断言都有负对照。
- 变异位点的选取是**确定性的**（同一份树跑两次，位点集合完全一样）。

---

## 不在本计划内

- **模板 i18n 缺口**（`templates/Makefile` 的 `make help` 与几条报错硬编码中文）：
  要动 `locale/**`，而 `locale/**` 正被别的会话改 ⇒ 等对方提交后再单开一轮，
  且那轮要升 minor（输出文本变了 ⇒ 进 `docs/MIGRATING.md`）。
- 不新增公开函数、不扩 CLI 命令面。
- 不做自动回滚、不引入新依赖。
