# 把 shellkit 接进既有项目

不要求你先重写脚本。三种接入姿势从"零承诺"到"全套"，按你能接受的风险选。

## 三分钟决策

| 姿势 | 改动量 | 适合 | 代价 |
|---|---|---|---|
| **A. 只借测试** | 拷 2 个文件 | 已有脚本能跑但没测试 | 拿不到 log/config/prompt |
| **B. vendor 整个库**（推荐） | 一条命令 + 每个脚本 2 行 | 绝大多数项目 | 库里镜像进仓库（约 400KB，含 CLI 与模板） |
| **C. 全局安装** | 一条命令，脚本靠 PATH 找库 | 只在自己机器上跑的脚本 | 别人/CI 必须先装，版本不可控 |

一句话：**要分发给别人的项目一律选 B**，因为库跟着代码走，git 里能 diff、能回滚、离线能跑。

## A. 只借测试（最小侵入）

只拷两个文件，不碰业务代码，立刻有断言能力和逐文件执行器：

```bash
mkdir -p tests
cp <shellkit>/tests/test_helper.sh <shellkit>/tests/run.sh tests/
```

然后照着它写第一个测试：

```bash
#!/usr/bin/env bash
. "$(cd "$(dirname "$0")" && pwd)/test_helper.sh"

out=$(bin/mytool --version 2>/dev/null)
assert_ne "" "$out" "--version 不该为空"
assert_exit_code 2 bin/mytool no-such-command
```

`tests/run.sh` 会自动发现 `tests/test_*.sh` 并逐个 `@bash` 执行，
每个文件固定从 `/dev/null` 取 stdin（不会因为等输入挂死），有 `timeout` 就给单文件上限。

**这一步的收益**：你现在就能对既有脚本做回归，不用先引入任何依赖。

## B. vendor 整个库（推荐）

```bash
cd /path/to/your-project
shellkit vendor .
```

产出：

```
your-project/
└─ vendor/shellkit/
   ├─ lib/           18 个模块（bootstrap.sh + core/*.sh）
   ├─ locale/        gettext 译文（en / zh_CN / zh_Hant）
   ├─ templates/     脚手架模板（副本自己就能 new / upgrade）
   ├─ tests/         测试基建（test_helper.sh + run.sh）
   ├─ shellkit       CLI 本身（副本自己就能升级工程）
   └─ VERSION        锁定的版本号
```

副本自带 CLI 与模板，所以工程被拷到一台**没装 shellkit 的机器**上时，
`./vendor/shellkit/shellkit upgrade .` 照样能离线升级。

脚本里两行接入：

```bash
#!/usr/bin/env bash
set -euo pipefail

. "$(cd "$(dirname "$0")/.." && pwd)/vendor/shellkit/lib/bootstrap.sh"
```

就这些。`bootstrap.sh` 会按拓扑序把 18 个模块加载好，设置 `SK_*` 常量与退出码，
**不改你的 shell 选项、不改 cwd**——你的脚本还是你说了算。

### 为什么是 `vendor/` 而不是装到系统里

- **可复现**：CI 不用先装东西，`git clone` 完就能跑。
- **可追溯**：库的每次升级都是一个可以 diff 的提交，不是"某天机器上的版本变了"。
- **可共存**：不同项目可以锁不同版本，互不影响。

## C. 全局安装（自用脚本可以）

```bash
shellkit install-self --prefix ~/.local
```

脚本里就得靠 PATH 找库（脆弱，不推荐给要分发的项目）：

```bash
SHELLKIT_HOME=${SHELLKIT_HOME:-$(cd "$(dirname "$(command -v shellkit)")/../share/shellkit" && pwd)}
. "$SHELLKIT_HOME/lib/bootstrap.sh"
```

## 升级与防漂移

库更新后，把新版本同步进项目：

```bash
shellkit vendor .            # 幂等：整目录替换，模块被删掉也不留残骸
shellkit vendor . --check    # 只比对，不写盘
```

`--check` 是**逐字节 diff**（不是比版本号），任何漂移都会报出来并返回 `5`。
把它放进 CI，就再也不会出现"仓库里是旧版、本机是新版"：

`@yaml
      - name: vendored shellkit is in sync
        run: shellkit vendor . --check
```

（CI 里没有 `shellkit` 命令时，用 `diff -r` 直接比等价内容也行。）

### 0.4.x → 0.5.0：会改变结果的行为变化

0.5.0 修了 19 个缺陷。其中七处会让既有代码算出不一样的结果，升级后**先跑一遍你自己的测试**，
下面逐条给判据：

| 变化 | 以前 | 现在 | 你会在哪里撞到 |
|---|---|---|---|
| `conf_get` 区分空值与缺失 | 键存在但值为空时回落到默认值 | 只有键不存在才回落默认值 | 以前靠「空值→默认值」兜底的代码，现在拿到空串 |
| `validate_ip` | 接受 `010.1.1.1`、`1.2.3.256` | 只接受 0-255 且无前导零 | 带前导零的历史配置会被判非法 |
| `die` / `fail` 校验退出码 | `die abc` 以 255 退出 | 非法码按用法错 `2` 退出 | CI 里断言过 255 的地方要改 |
| `trap_install` 接管 INT/TERM/HUP | 只保留 EXIT | 三个信号也接管：先清理栈、再跑你的 handler、最后 `exit 128+sig` | 自己另装信号 handler 的，改走 `trap_push` 或接受这个顺序 |
| `cli_opt` 查重 | 重名静默只命中最后一个 | 报 `duplicate option` 并返回 2 | 原来靠「后注册覆盖前一个」的用法会当场失败 |
| `cli_opts` 布尔选项带值 | `--verbose=1` 静默写进变量 | 报 `option does not take a value` 并返回 2 | 给开关传值的调用方要删掉 `=值` |
| `fs_backup` 校验保留份数 | 非数字时 bash 报错且静默不轮转 | 报 `invalid keep count` 并返回 2 | 传 `$KEEP` 前先确认是纯数字 |

不会改变结果的修复（可以直接升）：`fs_ensure_line` / `fs_ensure_block` 对含反斜杠的文本不再
重复追加；`net_wait_port` 不再关调用方的 fd 3、也不再永久改掉 stderr；`_tn` 的复数分支真的
走 gettext 了；`shellkit list` 列全 9 个子命令；`docs --check` 缺 `tools/comment_coverage.awk` 时
不再静默变绿；`install-self` 补装 `tools/`、`docs/`、`AGENTS.md`。`cli_run` 里那段「补印
`SK_ERRMSG`」的死代码删掉了 —— `log_error` 本来就打印过，这份永远不触发，`SK_ERRMSG` 仍然
保留为「最后一条错误」。

新增门禁：`make messages-check`（pot 与源码一致性，缺 `xgettext` 时跳过）已并入 `make check` 与 CI。

### 0.5.0 → 0.6.0：会改变结果的行为变化

0.6.0 修了 10 个缺陷。其中五处会让既有代码算出不一样的结果，升级后**先跑一遍你自己的测试**：

| 变化 | 以前 | 现在 | 你会在哪里撞到 |
|---|---|---|---|
| `run` 的打印文本 | dry-run 与失败消息用 `$*` 拼接，引号丢失 | 逐参数引号化，带空格的参数会打印成 `'a b'` | 断言过 `[dry-run] touch /a b` 字面量的测试 |
| `fs_backup` 的文件名 | `FILE.bak.YYYYmmddHHMMSS` | `FILE.bak.YYYYmmddHHMMSS.$$[.N]` | 用正则从备份名里抠时间戳的要改；`*.bak.*` 与「按名升序 == 时间序」不变 |
| `lock_acquire` 对无 pid 的锁目录 | `SHELLKIT_LOCK_STALE` 默认 0 ⇒ **永不回收**，锁名永久不可用 | 默认 5 秒宽限，超过即回收 | 以前靠「永不回收」当互斥标记的用法会失效 |
| `retry` 的首次延迟 | 只夹紧后退后的值，首次按原值睡 | 首次也吃 `SHELLKIT_RETRY_MAX_DELAY` | 拿「初始延迟 >> 上限」当一次性等待的用法会变快 |
| 少传参数 | 零参的 `require_cmd` / `os_has_cmd` 返回 0；其余被 `set -u` 打死成 `1` | 一律返回用法错 `2` | `case "$rc" in 2)` 分流的地方；`require_cmd "$EMPTY"` 不再静默通过 |

只加不改的部分（不用改代码就能升）：`run` 新增 `--no-die`，让 `if run --no-die ...` 与
`run --no-die ... || ...` 真的成立（默认行为仍是「失败即 die」）；`install-self` 补装 `tests/`，
装好的副本 `new` 出来的工程 `make test` 不再 127；`shellkit new` 落盘失败时返回非 0 且不再打印
`[ OK ] project created`；pot 里不再有 `#:` 位置注释（行号注释每改一次代码就整片漂移），
因此也不再有本机绝对路径。

新增门禁：`make versions-check`（`VERSION` 与 pot 头、README、站点的版本引用是否一致）已并入
`make check`。新增命令：`make release VERSION=x.y.z` / `make release-dry VERSION=x.y.z`。


### 0.10.0 → 0.11.0：会改变结果的行为变化

这一版修的是**升级会覆盖用户修改**这一类问题，顺手把「写回与读取不一致」「日志泄密」
两处一起收掉。凡是行为变了的地方都列在下表里。

| 变化 | 以前 | 现在 | 你会在哪里撞到 |
|---|---|---|---|
| `shellkit upgrade` 覆盖用户改过的文件 | 第一次升级跳过（提示「modified locally」），**第二次升级就会覆盖掉** —— 清单里记的是「文件当前内容」，不是「模板基线」 | 跳过的文件基线不动，**连续升多少次都保留用户的修改** | 改过 `README.md` / `AGENTS.md` / `bin/*` 等模板自有文件的工程 |
| 旧清单（0.10.x 及以前生成）的升级 | 直接按清单里的指纹判断 | 指纹可能已被旧版写成「用户改过的内容」，无法与旧模板核对的文件**一律保持原样**并给出提示；确认过再用 `--force` 覆盖 | 0.10.x 时代生成、并且升过级的工程 |
| `.shellkit-manifest` 的内容 | 无版本标记 | 多一行 `manifest_version=2`（基线可信的标记） | 直接读这个文件的脚本 |
| `conf_unset` / `conf_disable` / `conf_set` 对 dotenv 文件 | 只认 `KEY=` 开头的行：`export API_KEY=secret` **删不掉**，下次读取又拿回旧值 | 与读取端同一套规则：`export` 前缀、引号、格式语义都认 | 用 `--format dotenv` 的工程 |
| `run` / `run_concurrent` 失败时的日志 | 完整打印命令行 —— 口令与令牌会进日志文件 | 敏感参数脱敏成 `***`（`KEY=VALUE`、`--password VALUE`、`Authorization:` 三种形态）；普通参数照原样打印 | 任何会把命令行写进日志的脚本 |
| `run_concurrent` 里被信号杀死的实例 | 没留下退出状态 ⇒ **当成成功**（成功数虚高） | 判定为失败，并说明是哪个实例没有状态 | 实例被 OOM killer 或超时信号杀掉的场景 |

新增的能力（都是加法，既有行为不变）：

- `parallel_map N [--timeout SEC] -- CMD...` —— 条目从标准输入读（一行一个），每个实例
  跑一条**不同的**目标（条目作为最后一个参数）。与 `run_concurrent` 明确分工：后者跑的是
  同一条命令 N 份。stdout 一行一条结果 `<条目>\t<退出码>`，stderr 是各实例的输出。
- 日志脱敏可以用 `SHELLKIT_REDACT=0` 关掉 —— 调试时用；关掉的这一刻起，口令就会进日志。
- 新增 `tests/bats/` —— bats-core 用例，每个 `@test` 一个独立进程；
  `make bats-check` 跑它（bats 是外部依赖，不进 `make check`；CI 里有专门的 job）。
- CI 的门禁统一走 `make check`（本地与 CI 同一组检查），工具版本全部钉死；
  兼容矩阵扩到 Debian 12 与 Rocky Linux 9（容器里跑同一组门禁）。

### 0.9.0 → 0.10.0：会改变结果的行为变化

这一版修的是**一类静默失效的缺陷**。Bash 的 `printf -v` 写的是「最近一层声明了该名字的
作用域」：出参名一旦和出参链路上某个局部变量同名，内容就写回库自己那层 —— 你的变量
还是旧值，**不报错、不崩**。其中一处已经害得交互式问答**永远拿不到用户输入**。

| 变化 | 以前 | 现在 | 你会在哪里撞到 |
|---|---|---|---|
| 交互式 `ask` / `ask_yn` / `ask_choice` / `confirm` | 在真终端里也永远回退默认值，用户输入被丢弃 | 正常拿到用户输入 | 用交互问答的脚本：以前问一百遍拿到的都是默认值 |
| 出参名撞上内部保留名 | 静默失效：结果写丢，函数却返回 0 | 返回 2（用法错），并说明撞了哪个名字 | 只有用了保留名单里那些名字的调用方会变 —— 那些名字以前就是不工作的 |
| 模板里 `cli_opt __target` | `--target` 的值写进库内部变量，调用方永远读到空 | 正常写进调用方的变量 | 生成的工程里用了 `--target` 选项的脚本 |

保留名单是**精确**的：只有真正会撞车的名字在里面，不是「`__` 前缀一律拒绝」。
用别的名字（哪怕带 `__` 前缀）照常能用 —— `ask __my_answer` 不受影响。
名单由 `tools/check_local_names.sh` 守着：库内部新增局部变量却忘了进名单，门禁就红。

新增的能力（都是加法，既有行为不变）：

- `shellkit man` —— 生成 man page：第 1 节是命令总览，第 3 节每个模块一页（函数签名、
  返回码、交叉引用）。数据来自 CLI 注册表与函数注释，**不另维护一份清单** —— 加一个命令、
  改一句函数说明，man 页自动跟着变。`shellkit man --out DIR` 把 `shellkit.1` 与每个模块的
  `shellkit-<模块>.3` 写进目录（vendor 副本里也能生成：副本自带库与清单）。
- `man` 模块 —— `man_page` / `man_module_page` / `man_write_all` / `man_modules` /
  `man_count_functions`，库函数层面也能用。
- `shellkit list` 增一段**能力概览**（模块数、公开函数数、命令数）——数字全部现算，
  不写死。
- 新门禁 `tools/check_module_count.sh` —— 文档里手抄的「N 个模块」必须与 `lib/modules.txt`
  一致（模块数在六个地方手抄，加一个模块必然漂移）。
- 新门禁 `tools/check_local_names.sh` —— 库内部局部变量一律 `__` 前缀；出参链路上的局部
  变量必须进保留名单；公开出参入口必须挡住保留名。
- 新门禁 `tools/check_pipe_safety.sh` —— 管道里不能有会提前退出的消费者（`grep -q` / `head`）。
  它们会把管道上游 SIGPIPE 打死（141），而调用方常开着 `set -o pipefail`：整条管道于是
  按 141 判失败，「查到了」变成「没查到」。库内部已经全部改掉，门禁盯着不再犯。


### 0.8.1 → 0.9.0：会改变结果的行为变化

0.9.0 补的是「生态缺口」：模块按需加载、`shellkit doctor` 自检、vendor 副本自带 CLI。
**库函数的行为一个字没改**（返回码、产出文件名、输出文本都没动），但命令行与工具链有四处
会改变结果，升级后先跑一遍你自己的测试：

| 变化 | 以前 | 现在 | 你会在哪里撞到 |
|---|---|---|---|
| `shellkit vendor` 的产物 | 只有 `lib/` + `locale/` + `VERSION` | 额外带 `templates/`、`tests/`（test_helper.sh 与 run.sh）与 **CLI 本身** | 断言 vendor 目录内容清单的脚本要改；vendor 目录从约 120KB 变成约 400KB |
| `shellkit vendor --check` | 只比 lib / locale / VERSION | 多比 templates / tests / CLI | **老工程第一次跑会返回 5**（副本里还没有 CLI）：先跑一次 `shellkit vendor .` 再把它放进 CI |
| `tests/run.sh --filter` | 匹配不到文件时退出 0（报「All 0 test files passed.」） | 退出 2，并把可用的测试文件列出来 | 靠「filter 没匹配到就算全过」判断的 CI 会红 —— 那本来是假绿 |
| `shellkit docs`（在 vendor 副本里跑） | 跑到一半报「No such file」 | 明确报前置条件错（退出码 3） | 副本里本来就没有文档源（有意为之：副本的职责是「库跟着走 + 工程能自己升级」） |
| `lib/modules.txt` 的格式 | 一行一个模块名 | 两列：**模块名 + 它依赖的模块**（空格分隔，可不写） | 自己往清单里加过模块的脚本或补丁要改；顺序与依赖从此只有这一处真相源 |
| `lib/modules.txt` 读不到 | 静默加载零个模块 | 打印 `cannot read module list` 并返回 1 | 以前「清单读不到 ⇒ 一个模块都不加载」的用法会改成报错 —— 那本来是坏的 |

新增的能力（都是加法，既有行为不变）：

- `SHELLKIT_MODULES="log fs"` —— 只加载需要的模块，依赖会自动带上；不设这个变量时仍是全量加载。
- `shellkit doctor` —— 三类检查：运行环境、库完整性（模块文件齐不齐）、vendor 漂移（逐字节比对）。
- **vendor 副本自带 CLI** —— 工程被拷到一台没装 shellkit 的机器上时，
  `./vendor/shellkit/shellkit upgrade .` 照样能离线升级。

### 0.7.0 → 0.8.0：会改变结果的行为变化

**先说最重要的一条：许可证从 GPL-3.0-or-later 换成了 MIT。**

这一条影响的是**你能不能把 shellkit 放进闭源工程**。GPL-3.0 的传染性会要求你的整个下游产品
也以 GPL-3.0 开源；MIT 没有这个约束。vendor 进来的库不再传染。

| 变化 | 以前 | 现在 | 你会在哪里撞到 |
|---|---|---|---|
| 许可证 | GPL-3.0-or-later | MIT（见 `LICENSE`），原上游署名保留在 `NOTICE` | 闭源工程 vendor `shellkit` 时不再被传染；已经按 GPL-3.0 发行的下游**不需要**改（MIT 兼容 GPL-3.0，许可可以并存） |
| `tools/coverage.awk` | 名字叫 coverage，实际查的是注释覆盖率 | 改名 `tools/comment_coverage.awk` | 自己写过引用这个文件名的脚本要改；它从来不是代码覆盖率工具 |
| 模块清单 | `lib/bootstrap.sh` 与 `tools/shdoc.sh` 各有一份，漏一处就红 | 唯一真相源 `lib/modules.txt`，两处都从它读 | 打过 `lib/bootstrap.sh` 补丁的脚本要改；新增 `make module-order-check` 门禁自动查依赖顺序 |
| `_t` 传参 | gettext 直接收 msgid | msgid 以 `-` 开头时自动补 `--` | 只有形如 `--set expects KEY=VALUE` 的提示受影响；其余 msgid 行为不变 |
| `log_debug` 出声条件 | 只有 `SHELLKIT_DEBUG=1` | `SHELLKIT_DEBUG=1` **或** `SHELLKIT_LOG_LEVEL=debug` | 之前设了 `SHELLKIT_LOG_LEVEL=debug` 却没有效果的人现在会看到 debug 输出（这本来就是那个变量的意图） |
| `shellkit list` | 列 9 个子命令 | 列 11 个（多 `upgrade` 与 `completion`） | 拿 `list` 输出做断言的脚本会看到多两行 |
| `shellkit new` | 只有 `--name` / `--cmd` | 多 `--template` / `--set` / `--yes` | 旧调用完全不受影响 |
| `shellkit upgrade` | 不存在 | 新增：把生成的工程升级到当前模板 | 新命令，不影响旧代码 |
| `shellkit completion` | 不存在 | 新增：输出 bash / zsh 补全脚本 | 新命令，不影响旧代码 |

新增的库能力（都是加法，既有函数的行为一个字没改）：

- `net_request` / `net_json` / `net_escape_json` —— HTTP 客户端。`net_request` 把状态码、响应体、
  响应头分开给出；`net_json` 用 jq（没有就 python3）解析，不自己手写 JSON 解析器。
- `run_concurrent N [--timeout SEC] -- CMD...` —— 同一条命令并发跑 N 份。stdout 给成功数，
  stderr 给逐实例标注的输出，返回第一个失败实例的退出码。
- `conf_load_dotenv` / `conf_source` / `conf_init --format env\|dotenv` —— dotenv 解析。
  `conf_load_dotenv` 只进配置层（不 export，避免盖掉调用方自己的环境变量）；要 export 用 `conf_source`。
- `SHELLKIT_LOG_LEVEL` / `SHELLKIT_LOG_FORMAT=json` / `SHELLKIT_LOG_FILE` —— 结构化日志。
  默认值保持今天的样子，既有脚本一行不用改。
- `scaffold_*` —— 脚手架的变量渲染、清单与钩子，被 `shellkit new` 与 `shellkit upgrade` 共用。

### 0.6.0 → 0.7.0：会改变结果的行为变化

**没有会改变结果的行为变化。** 0.7.0 的库函数行为与 0.6.0 完全一致：返回码、产出文件名、
输出文本、退出码语义都没动。所以升级不需要改任何代码。

这次改的是**文档站**与**文档本身**：

| 变化 | 以前 | 现在 | 你会在哪里撞到 |
|---|---|---|---|
| 站点 | 单页手写落地页 | VuePress 文档站，中英双语、带站内搜索、按模块分页 | 书签了 `https://yi-nology.github.io/shellkit/` 的人会看到新界面；URL 前缀不变，深链接不受影响 |
| API 参考 | 83 个公开函数里 37 个只有一行签名 | 每个函数都有中文摘要（做什么、失败返回什么） | 从 `docs/REFERENCE.md` 抄注释的人会看到更长的摘要行 |
| `cli_opts` 的签名注释 | 写的是 `cli_opts NAME ARGS...` | 改成 `cli_opts ARGS...`（实现本来就不接 NAME） | 按注释猜签名的人会发现注释以前是错的；**代码行为没变** |

站点里那四类同步页（Cookbook、迁移、发版、API 参考）由 `tools/site_sync.sh` 从 `docs/`
生成，**不要在 `site/` 里直接改** —— 下次构建会被覆盖。

新增门禁与命令：

- `bash tools/site_links.sh [dist]` —— 构建产物上的内部链接校验。主题自带的 links-check
  不会让坏链导致构建失败，所以另有一道这道门；退出码 5 表示有坏链。
- `make site` / `make site-serve` / `make site-deps` / `make site-sync` —— 构建与本地预览文档站。
  刻意**不进** `make check`：库的门禁不依赖 Node，没装 npm 的机器上也该能全绿。
- `make versions-check` 现在多管四处：两个首页与两个安装页的钉版本示例。

## 渐进迁移：5 步，每步都能单独上线

顺序按"收益 / 风险"排，**不要跳着一次全换**。

### 第 1 步：先杀 stdout 污染（收益最大、风险最低）

你项目里大概率有这种函数：

```bash
log_info()  { echo "[INFO] $*"; }        # ← 写到了 stdout
log_error() { echo "[ERROR] $*" >&2; }
```

只要 `log_info` 走 stdout，`v=$(your_fn)` 就会拿到 `[INFO] ...` 这种脏值，
而这类 bug 通常在几百行外的 `$(...)` 里才炸。

换成：

```bash
. "$PROJECT_ROOT/vendor/shellkit/lib/bootstrap.sh"
# 直接用 log_info / log_ok / log_warn / log_error / log_debug / log_section
```

**判据**：`out=$(你的命令 2>/dev/null)` 里不再出现 `[INFO]`/`[ERROR]`。
加一条测试固定住它：

```bash
out=$(bin/mytool deploy 2>/dev/null)
assert_not_contains "$out" "[INFO]" "日志不能污染 stdout"
```

### 第 2 步：替换配置读写

| 你手写的 | 换成 | 你免费得到的 |
|---|---|---|
| `get_config KEY` | `conf_get KEY [DEFAULT]` | 只输出值；未初始化不报错 |
| 三处分别读 env/文件 | `conf_get_any KEY DEFAULT` | 环境变量 > 配置 > 默认值，一处实现 |
| `set_config K V`（`>>` 追加） | `conf_set K V` | 原子写 + `600` + 值未变不写盘 |
| 手写 `grep` 判断有没有 | `conf_has KEY` | 返回码而不是 `echo 1/0` |
| 注释掉一行禁用 | `conf_disable KEY` | 保留原值，可逆 |

**注意**：`conf_set` 是**幂等**的（值没变就跳过写盘），所以可以放心每次启动调一遍。

### 第 3 步：替换交互

`read -p` / `read -t` 手搓的那套换成 `ask` / `ask_yn` / `ask_choice` / `confirm`，
它们自带三个你在别处一定会漏掉的行为：

- **非交互自动取默认值**（`-y` / `SHELLKIT_NONINTERACTIVE=1` / stdin 不是 tty），
  没默认值则返回 `3` 而不是静默返回空串；
- **真超时才回退默认值**，EOF 算错误（手写实现常把两者混同，于是 `</dev/null` 被当成"用户按了回车"）；
- **`ask_choice` 会校验默认值在选项集里**，写错当场 `2`。

### 第 4 步：接 CLI 框架

把 `case "$1" in` 那张表换成注册式：

```bash
cli_group "运维"
cli_cmd deploy "部署服务" "deploy [--force] <target>"

cmd_deploy() {
  local force=""
  cli_opt_init
  cli_opt force --force -f
  cli_opts "$@" || return $?
  local target="${SK_OPTS_LEFT[0]:-}"
  [ -n "$target" ] || { log_error "缺 target"; return "$SK_USAGE"; }
}

cli_run "$@"
```

**收益**：`--help` 自动生成、未知命令按前缀给候选、`log_error` 只报一次（打印即记录），
新增命令零改分发器——命令名甚至可以带短横，
`install-self` 会自动派发到 `cmd_install_self`。

**代价**：退出码语义要统一。如果你的旧脚本用 `exit 1` 表示"用法错"，
先在外层保持兼容，内层用 `2`（用法）/`3`（前置）/`4`（网络）/`5`（校验），
等调用方都改完再收口。

### 第 5 步：接测试

`tests/run.sh` + 断言库，然后**每迁一类函数就加一个 `test_*.sh`**：

```bash
assert_eq "${expected}" "${actual}"
assert_contains "${haystack}" "${needle}"
assert_exit_code 3 your_command --bad
assert_file_mode config 600
assert_stdout_empty your_command --quiet
```

## 迁移时容易踩的坑

1. **别同时改行为和改库**。一次只迁一类函数，每步跑一遍测试。混着改，
   出问题时分不清是库的锅还是你的锅。
2. **`set -euo pipefail` 只由你的入口开**。库不碰你的选项；但如果你原来的脚本
   依赖 `set -e` 下的隐式退出，换成 `|| return $?` 后语义会变，要显式处理。
3. **Bash 3.2 的边界只约束库，不约束你的业务代码**。库里不用关联数组/nameref/
   `${var^^}`，但你的脚本只要目标平台 bash ≥ 4，继续用没问题，混着用也不冲突。
4. **`source` 之后 `$0` 和 cwd 都没变**——这是刻意的（不少安装脚本一进来就 `cd`，
   把调用方的相对路径全带偏了）。所以路径请自己算，别指望库替你 cd。
5. **i18n 是可选的**。不接 gettext 就只有英文，不会有额外依赖；
   要中文就编 `locale/zh_CN` 的 `.mo`（`bash po/messages.sh`）。

## 一个真实的最小改造

改造前（典型手写版，三个隐患都占全了）：

```bash
#!/bin/bash
log() { echo "[$(date +%T)] $*"; }            # 隐患 1：stdout
get() { grep "^$1=" config | cut -d= -f2; }   # 隐患 2：值空就崩，且不校验键名
set() { echo "$1=$2" >> config; }             # 隐患 3：追加写，重复键越来越多

. ./lib/config.sh
log "deploying to $(get TARGET)"
set TARGET "$1"
```

改造后：

```bash
#!/usr/bin/env bash
set -euo pipefail

APP_ROOT="$(cd "$(dirname "$0")" && pwd)"
. "$APP_ROOT/vendor/shellkit/lib/bootstrap.sh"

conf_init "$APP_ROOT/config" || exit $?

log_section "deploying to $(conf_get_any TARGET localhost)"   # 日志走 stderr
conf_set TARGET "$1"                                          # 原子写、600、幂等
```

同样的功能，但 `$(...)` 干净了、配置写坏了不会半截、非法键名当场报错。

## 最小可用清单

想按最短路径吃满红利：

1. `shellkit vendor .` —— 库进项目（1 分钟）
2. 每个脚本顶部加 2 行 `source`（10 分钟）
3. 把所有写 stdout 的日志函数改到 `log_*`（半天，收益最大）
4. `get_config/set_config` 换 `conf_get/conf_set`（半天）
5. 加 `tests/test_*.sh`，把第 3、4 步的行为固定住（持续）
