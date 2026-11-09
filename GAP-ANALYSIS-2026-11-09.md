# shellkit 对标调研与差距分析

调研日期：2026-11-09。数据来自 GitHub API（stars / pushed_at / license）与各项目 README 原文；
shellkit 侧结论来自本地源码与门禁实测（`make check` 退出码 0）。

## 一、这个赛道上的项目长什么样

shellkit 的定位是三合一：**Bash 库 + 脚手架生成器 + CLI 框架**，基线 Bash 3.2。这三块分别有成熟玩家。

| 项目 | star | 最近推送 | 许可 | 它解决的是哪一块 |
|---|---|---|---|---|
| niieani/bash-oo-framework | 5621 | 2023-12-15 | MIT | **最接近的对标**：Bash 标准库 + 脚手架框架 |
| bats-core/bats-core | 6345 | 2026-11-07 | MIT | Bash 测试事实标准，TAP 输出 |
| TypedDevs/bashunit | 440 | 2026-11-08 | MIT | 活跃的 Bash 3.0+ 测试框架，93 断言 + mock + snapshot |
| shellspec/shellspec | 1402 | 2025-11-24 | MIT | BDD 测试，带 coverage / mock / parallel / JUnit |
| cookiecutter/cookiecutter | 25180 | 2026-04-01 | BSD-3 | 脚手架标杆：变量声明文件 + pre/post 钩子 |
| copier-org/copier | 3687 | 2026-11-06 | MIT | 脚手架标杆：模板版本化 + 增量重放更新 |
| jdx/mise | 35961 | 2026-11-09 | MIT | 任务 / 版本 / 插件生态，TOML 驱动 |
| mvdan/sh (shfmt) | 9187 | 2026-11-08 | BSD-3 | 格式化与语法 |
| koalaman/shellcheck | 40303 | 2026-11-09 | GPL-3.0 | 静态检查（独立工具） |
| anordal/shellharden | 4803 | 2026-07-09 | MPL-2.0 | shell 加固 |
| **yi-nology/shellkit** | **0** | 2026-11-09 | GPL-3.0 | 本项目，仓库创建于 2026-11-08 |

两个结论先行：

**其一，最接近的对标项目已经死了。** bash-oo-framework 停在 2023-12-15，两年多无提交。它失败的原因不是功能少，而是它堆了 OOP 层——类、类型系统、命名参数、异常、try-catch、函数式链。这条路的终点是"在 bash 里重新造一门语言"。shellkit 现在这套"扁平函数 + 固定退出码 + 不改调用方 shell 选项"的克制路线是对的，**不要因为对手有而补 OOP**。同理，也不要自研 JSON/YAML 解析（用 jq/yq），不要自研 HTTP 客户端（curl 足够）。

**其二，Bash 3.2 基线不是包袱。** shellspec 支持 bash ≥ 2.03，bashunit 支持 ≥ 3.0，shellkit 卡 3.2 处于生态中位偏宽的位置，比 bash-oo-framework（要求 bash 4）的兼容面更好。这一条不用改。

## 二、真正做得不够好的地方

### P0-1　GPL-3.0 与「被别人 vendor 走」的定位互相打架

这是最严重的问题，而且不是功能问题。

shellkit 的核心使用姿势，README 自己写得很清楚：`shellkit vendor .` 把库镜像进用户工程，用户在自己工程里 source 它。**这等于把 GPL-3.0 的传染性带进了用户的代码库**。用户把自己的闭源运维工具拷一份 shellkit 进去，按 GPL-3.0 的条款，整个下游产品必须以 GPL-3.0 开源。对一个「给别人的项目打底」的工具来说，这是把最大的潜在用户挡在门外。

对标项目里所有**作为库被使用**的都是宽松许可：bash-oo-framework MIT、bats MIT、shellspec MIT、copier MIT、cookiecutter BSD-3、shfmt BSD-3、mise MIT。唯一用 GPL-3.0 的是 shellcheck，而它是独立二进制工具，不进别人的代码库——性质和 shellkit 不一样。

**改进**：改成双许可 `GPL-3.0-or-later OR MIT`，或者至少给 `lib/` 开 MIT 例外（保留 GPL 作为整体许可）。这件事越晚改越贵——每多一个 vendor 走库的用户，切换成本就多一分。

顺带一个必须立刻修的**真实缺陷**：README 写「骨架演化自 jumpserver/installer（GPLv3），按同一许可证分发，原署名保留在 LICENSE 里」，但实测 `grep -ci jumpserver LICENSE` 结果是 **0**，仓库里也没有 NOTICE / COPYING 文件。README 的这句自述与事实不符。GPL-3.0 §5(e) 要求保留原作品的署名声明——要么补一个 NOTICE 写明上游与原作者，要么把 README 这句话改成实情。

### P0-2　脚手架只有「生成」，没有「演化」

`shellkit new` 目前只接受 `--name` 和 `--cmd`，模板目录写死在 `shellkit:29` 的 `SK_TPL_DIR="$SELF_DIR/templates"`。没有变量声明文件、没有用户自带模板、没有 pre/post 生成钩子、没有把这次的参数记进生成物。

而 cookiecutter 的核心机制是 `cookiecutter.json` 声明全部变量与默认值 + pre-prompt / pre-generate / post-generate 钩子；copier 的核心机制是模板自带 git 版本 + `copier update` 把新版模板**增量重放到已有工程**上。

对 shellkit 来说这意味着：生成的工程一旦交付，**没有任何办法把 shellkit 后续的模板层改进同步进去**。`shellkit vendor .` 只刷 `lib/` + `locale/` + VERSION，不动 `commands/`、不动模板的 AGENTS.md、不动工程骨架。再跑一次 `shellkit new` 只会覆盖。脚手架的价值在第二、第三次使用，这一点目前是空的。

**改进**（按性价比排序）：

1. **模板变量声明文件**。用 `template.config` 存 `KEY=VALUE` 加默认值，和现有 `conf` 模块天然同构——解析、取值优先级、原子写全部现成。生成时把变量渲染进模板，声明了就必须问，交互读取走已有的 `ask` / `ask_yn` / `ask_choice`。
2. **生成物留档**。在生成的工程里写一份 `.shellkit-manifest`，记录模板版本与本次变量。这份档案是后面所有升级能力的地基。
3. **`shellkit upgrade <dir>`**。读 manifest，比对当前模板版本与本机版本，用 `fs_ensure_line` / `fs_ensure_block` 那套幂等原语做增量重放；用户改过的文件跳过并告警。
4. **`--template <dir>`**（甚至支持 git URL），让用户能自带模板；同时允许 `templates/` 被用户工程覆盖。
5. **pre/post 钩子**：`template.hooks.d/pre` 和 `post`，各是一段 shell，生成前后执行。这是 cookiecutter 最被低估的能力——`git init`、装依赖、设 CI 全靠它。

### P1-1　测试体系是自研孤岛，CI 集成度不够

先说公道话：`tests/test_helper.sh` 里的 `stub()` / `unstub()` / `assert_stub_called()` / `assert_stub_args()` / `assert_stub_not_called()` 是一套真东西——PATH 打桩替身加调用断言，能力上等价于 bats 的 mock 和 bashunit 的 spy。地基是好的，不是玩具。

问题在**输出协议**。`tests/run.sh` 逐文件执行，输出是 `==> test_xxx.sh` 加一句 `All N test files passed.`。bats 输出 TAP，shellspec 能出 JUnit XML 和 TAP，bashunit 有多套 formatter。差别在 CI 里是致命的：现在 CI 只能知道「某个文件挂了」，不知道「哪个用例挂了」，也拿不到任何机器可读的测试报告喂给 GitHub Actions summary、Jenkins 或测试报告平台。

其余缺口：并行执行（shellspec、bashunit 都有）、参数化/数据驱动、快照断言。

另外 `tools/coverage.awk` 名不副实——它检查的是「公开函数上方有没有紧邻注释行」，是**注释覆盖率**，不是代码覆盖率。这个命名会持续误导人。

**改进**：

- `tests/run.sh` 加 `--format tap|junit`（默认保持现状，兼容），JUnit XML 直接被 CI 收集；再加 `--jobs N` 并行。
- 真覆盖率交给 `kcov` / `shcov`——注意 `shcov` 需要 bash 4+，只能作为 3.2 机器上的可选增强，3.2 基线路径不受影响。
- `tools/coverage.awk` 改名 `tools/comment_coverage.awk`，`make docs-check` 里的调用点同步改。

### P1-2　没有 HTTP 客户端，运维最常用的一类动作没有落点

`net` 模块只有 `net_verify` / `net_download` / `net_wait_port` / `net_wait_http`。没有「发一个请求」这个动作：没有方法、没有请求头、没有认证、没有请求体、没有状态码、没有响应体读取。

运维脚本有一大半价值在调 API。现在用户只能自己拼 curl，然后手写错误处理、手写重试分类、手写超时——而 `retry` / `run` / `require_cmd` 全都已经现成了，唯独缺了把 HTTP 当一等公民的那一层落点。

同一处还有个脆弱点：`shellkit:871-872` 用 `sed -n 's/.*"tag_name".../\1/p'` 从 release.json 里抠版本号。GitHub 的 API 格式稳定所以现在没事，但换个 forge 或 GitHub 改一下字段顺序，这行就静默失配。

**改进**：新增 `net_request METHOD URL [--header K:V]... [--data STR] [--json STR] [--timeout N]`，返回码、响应体、响应头分离输出；再薄封装一层 `net_json`，有 jq 用 jq、有 python3 用 python3、都没有就以退出码 3（前置条件不满足）明确报错而不是瞎猜。JSON 解析用现成工具，不要自己写。

### P1-3　没有结构化日志，接入可观测性体系要重写一遍

`log.sh` 六个函数全部是人读的彩色行，写 stderr。没有级别过滤、没有 JSON 行格式、没有时间戳、没有日志文件输出。

运维脚本的终点是 journald / Loki / ELK。现在只能 `2>&1 | grep`，一接就丢字段。`SHELLKIT_DEBUG=1` 这种布尔开关也表达不了「这次跑要 info 以上、这次跑要 JSON」。

**改进**（纯加法，不改既有语义，符合 0.x 兼容约束）：

- `SHELLKIT_LOG_LEVEL=debug|info|warn|error`
- `SHELLKIT_LOG_FORMAT=text|json`
- `SHELLKIT_LOG_FILE=PATH`

默认行为保持今天的样子，既有脚本一行不用改。

### P2-1　配置只支持 KEY=VALUE

`conf` 是 `KEY=VALUE`。copier 用 YAML 答案文件，mise 用 TOML。而 dotenv——`FOO=bar`、`export FOO=bar`、引号包裹、注释、空格——在运维场景极常见，而 dotenv 的语法和 `conf_set` 的写法几乎同构。

**改进**：加 `conf_load_dotenv FILE`（把 dotenv 读进配置层，继续遵守「显式参数 > 环境变量 > 配置文件 > 默认值」的既有优先级）和 `conf_init --format env|dotenv`。JSON / YAML 不建议自己做，交 jq / yq。

### P2-2　CLI 框架没有 shell 补全，也没有 man page

`cli_run` 已经有 `--help` / `--version`、分组、选项解析、前缀建议（`Did you mean`），框架本身是齐的。缺的是交付物：整个 `lib/` 里没有任何 `complete -F` 注册。而 bashunit 干脆把 bash / zsh 的补全脚本直接放在 `completions/` 目录交付。

对一个「给运维用的命令行」，补全是刚需——子命令名和选项名都是自己定的，运维记不住是常态。

**改进**：`shellkit completion bash` 与 `shellkit completion zsh`，从 `cli_cmd` 注册表生成子命令与选项列表。顺带可以生成 man page。

### P2-3　库没有按需加载，也没有用户扩展点

`lib/bootstrap.sh` 一次性按拓扑序 source 全部 15 个模块（合计 2326 行）。bash-oo-framework 有 `import` 关键字可以只加载单个模块，那正是它「plug & play」的核心卖点。shellkit 是全量加载，启动开销和命名空间污染都固定存在。

同时 shellkit 没有「用户自己加模块」的扩展点：模块清单写死在 `lib/bootstrap.sh` 和 `tools/shdoc.sh` 两处，AGENTS.md 自己承认「两处顺序必须一致，少一处就红」。想加一个模块得改四处。

**改进**（二选一）：

- `SHELLKIT_MODULES="log fs net"` 只加载需要的模块（保持默认全量，兼容）；
- 或者 `lib/core/` 改成带数字前缀的文件名（`10-log.sh`、`20-fs.sh`），按序号自动加载——拓扑序变成文件名约定，模块清单不再需要维护，`lib/bootstrap.sh` 和 `tools/shdoc.sh` 各读一遍目录即可，两处顺序一致的问题自动消失。

第二种更彻底：它同时解决了「加模块要改四处」这个维护成本。

### P2-4　没有并发 / 批量原语

批量操作——对 20 台机器并行执行、并发下载多个文件——没有任何落点。用户会自己去写 `xargs -P`，但超时、失败汇总、错误归因都得重写一遍。

**改进**：`run_concurrent N -- cmd...` 或 `parallel_run`，成功/失败分开统计，失败项最后汇总输出。

### P3-1　冷启动期的元数据全是空的

GitHub API 实测：`description: null`、`homepage: null`、`topics: []`、`has_discussions: false`、`has_wiki: false`。仓库建于 2026-11-08，一天内发了 7 个 release，开了 29 个 issue。文档站本身是活的（`https://yi-nology.github.io/shellkit/` 返回 200，VuePress 2 rc.31，中英双语、有搜索）。

**改进**（十分钟内能做完，且是当下投入产出比最高的动作）：填 description / homepage / topics（`bash` `shell` `scaffold` `ops` `cli` `library` `automation`）、开 Discussions、README 顶部加一张「shellkit vs bash-oo-framework / bats / cookiecutter 各自解决什么」的对标表。

### P3-2　名字在 shell 圈不具辨识度

GitHub 上以 shellkit 命名的仓库有 12 个，最高的 macmade/ShellKit（88 star，Objective-C），另有 k6rthik/shellkit——同名同品类，做 bash/zsh 配置框架，MIT。对比 bash-oo-framework、bats、shellspec、cookiecutter，这些名字都有辨识度。

**改进**：不必改名，但要在 README 和 description 里加限定词（"shellkit for ops scripts"），否则搜索会被淹没。GitHub 支持 repo rename 且会留 redirect，真要改也不不可逆。

## 三、已经做得比对标项目好的地方

写改进方案时容易把这些忘了，所以明确列一下——它们不该在后续版本里被改掉：

1. **门禁质量在整个 bash 生态里是独一档**。API 文档从源码注释生成、`docs-check` 拦「公开函数缺注释」和「生成物与源码不一致」、`check-docs` 让 markdown 代码块真过 `bash -n` 且函数名必须在 REFERENCE 里真实存在、`versions-check` 拦裸版本号漏改、`messages-check` 拦 pot 漂移、截图是真跑命令渲染的、示例工程全程离线跑真实二进制。bats / shellspec / bashunit / cookiecutter / copier 一个都没有这一整套。这是 shellkit 真正的差异化资产。
2. **stdout 只给数据、日志一律 stderr**。这条纪律加上 `printf -v` 出参、原子写、幂等 `ensure_*`、mkdir 原子锁、清理栈，构成了一套竞品要么没有、要么各写各的约定。
3. **测试替身机制**（`stub()` 系列）已经是 bats mock / bashunit spy 的等价实现。
4. **退出码作为接口**（0/1/2/3/4/5 各有语义）比竞品普遍的「一律 exit 1」强得多，这直接决定了调用方能不能决定重试。
5. **Bash 3.2 基线**在生态中位偏宽。
6. **不引入 OOP**。bash-oo-framework 的坟碑已经证明这条路的代价。

## 四、建议的执行顺序

如果只能做三件事，按这个顺序：

1. **许可证决策 + 修 NOTICE/LICENSE 与 README 的矛盾**。它是「别人 vendor 走」这个商业模式的前置条件，而且越晚改越贵。改 README 措辞是十分钟的事，双许可是一天的事。
2. **`shellkit new` 的变量声明 + manifest + `shellkit upgrade`**。这决定脚手架是一次性玩具还是能用三次的工具。
3. **`tests/run.sh --format junit` + 仓库元数据 + README 对标表**。前两个让 CI 和 GitHub 页面对得起这套门禁，后一个让潜在用户三分钟内决定要不要试。

P1 的三项（HTTP 客户端、结构化日志、dotenv）是真实需求缺口，但不阻塞前两件——它们是「用了之后会想要」，不是「没有就劝退」。

## 五、证据出处

- GitHub API：`repos/<owner>/<repo>`（stars / pushed_at / license）、`search/repositories`（重名检索），查询时间 2026-11-09。
- 各项目 README 原文：经 `gh api repos/<repo>/readme` 取回，用于功能面核对（bats 的 TAP、bashunit 的 93 断言与 snapshot、shellspec 的 coverage/mock/parallel/junit、cookiecutter 的 hooks 与变量声明文件、copier 的 answers 文件与模板版本化、mise 的 task 与 backend、bash-oo-framework 的 import 机制）。
- shellkit 侧：`lib/core/*.sh` 公开函数清单（grep `^[a-z_][a-z0-9_]*\(\)`，129 个公开函数）、`shellkit` 主脚本、`tests/test_helper.sh`、`tools/check_docs.sh`、`.github/workflows/ci.yml`、GitHub API 仓库元数据。
- 实测：`make check` 退出码 0（2026-11-09，macOS，PATH 已剔除 `~/.minimax/shims`）。