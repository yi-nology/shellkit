<!-- 生成物：由 tools/ai_doc.sh 拼装，请勿手改。改 docs/ai/repo.head.md 再跑 shellkit docs。 -->

# 这个仓库：shellkit 本身

你在改的是一个 Bash 库 + 脚手架生成器，不是业务脚本。改动会被别人 vendor 走，
所以**向后兼容是硬约束**：0.x 内只加不改，改既有函数语义要单独提一个版本并写迁移说明。

## 地图

    shellkit                  生成器 CLI（new / upgrade / doctor / list / vendor / docs / completion /
                              install-self / uninstall-self / update）
    install.sh                一键安装脚本：取版本 → 下载 release → 校验 sha256 → 交给 install-self
    lib/bootstrap.sh          唯一入口：按 lib/modules.txt 的顺序 source lib/core/*.sh
    lib/modules.txt           模块加载顺序的唯一真相源（bootstrap 与 shdoc 都读它）
    lib/core/<module>.sh      17 个模块，一个模块一个主题
    templates/                shellkit new 的模板（含 __NAME__ / __CMD__ 占位符）
    tests/                    自研断言 + 逐文件执行器 + 每个模块一个测试
    tools/                    shdoc.awk / comment_coverage.awk / ai_doc.sh / check_docs.sh / term_shot.py
                              check_module_order.sh（模块依赖顺序门禁）
                              release.sh（一条命令发版）/ check_versions.sh（版本引用一致性）
                              site_sync.sh（docs/ → 站点页面）/ site_links.sh（产物链接门禁）
    docs/                     README 之外的深度文档；REFERENCE.md 与 AGENTS.md 是生成物
    docs/shots/*.shot         截图源：每行 `$ ` 是真要跑的命令，svg 由 make shots 渲染
    examples/                 两个能直接跑的工程，测试全程走真实二进制
    site/                     VuePress 2 文档站（手写页 + docs/ 同步页；Actions 构建，产物不进 git 历史）
    locale/{en,zh_CN,zh_Hant} gettext 目录，msgid 一律英文

## 加一个模块要改三处，少一处就红

1. 写 `lib/core/<name>.sh`：公开函数上方**必须**紧邻注释行，否则 `make docs-check` 红。
2. 在 `lib/modules.txt` 里加一行 —— 按依赖拓扑序，不是字母序。
   顺序只有这一份真相源：`lib/bootstrap.sh` 按它加载，`tools/shdoc.sh` 按它生成 API 参考。
   放错位置不要紧，`make module-order-check` 会指出「哪个模块调用了还没加载的函数」。
3. 写 `tests/test_<name>.sh`。测试文件名被 `tests/test_*.sh` 通配到就自动执行。

## 门禁

    make check     # syntax + test + lint + module-order-check + docs-check + versions-check +
                  # check-docs + messages-check + examples + fmt，CI 也是这组

`docs-check` 会拦两种事：公开函数缺注释、`docs/` 里的生成物与源码不一致。
`lint` 是 `shellcheck -S warning -x`，模板会先渲染再检查（占位符不是合法语法）。

## 三个已经踩过的坑

1. **bash 3.2 与 5 的 trap 语义不同**：子 shell 里 `trap -p EXIT`，3.2 读到空，5.x 仍打印
   父 shell 的 trap 但子 shell 退出时不执行。所以幂等不能只查 `trap -p`，看到是自己的
   处理器就重装一遍（重装无害），也绝不把自己的处理器当调用方的捕获下来。
2. **`$(trap -p ...)` 永远读不到东西**：命令替换本身是子 shell。要重定向到文件再 `cat`。
3. **空数组在 `set -u` 下遍历会报 unbound variable**：一律 `${arr[@]+"${arr[@]}"}`。

## 本场景的验证

    make check
    bash tests/run.sh                # 只看测试
    ./shellkit docs --check          # 只看文档产物是否最新
    bash tools/check_versions.sh     # 只看版本引用是否一致
    bash tools/check_docs.sh         # 只看文档里的示例是否仍然成立
    bash tools/check_module_order.sh  # 只看模块加载顺序对不对
    make site                         # 构建文档站（先从 docs/ 同步，再查产物内部链接）

## 发版

`VERSION` 是唯一真相源，pot 头、README、`site/index.md` 与 `site/en/index.md` 都是它的**手抄投影**。所以发版不许手工改：

    make release-dry VERSION=x.y.z   # 先空跑：升版本→重生成→门禁，然后还原工作树
    make release VERSION=x.y.z       # 真发：commit + tag + push，tag 触发 release.yml

改了既有函数的结果（返回码、产出文件名、输出文本）就要升 **minor**，并在
`docs/MIGRATING.md` 加一张「会改变结果的行为变化」表。只加不改的可以升 patch。

## 通用规则：用 shellkit 写 Bash

shellkit 是一个 Bash 库加脚手架：日志、配置、下载校验、重试、单实例锁、CLI 框架、i18n
都已经写好且测过。**你要做的是装配，不是重新实现一遍。**

### 三条硬事实

1. **基线是 Bash 3.2+**（macOS 自带的 /bin/bash 就是 3.2.57）。不是 4.x，不是 5.x。
2. **stdout 只给数据，日志一律 stderr。** 所以 `v=$(conf_get KEY)` 永远是干净的。
3. **出参用 `printf -v "$var"`，函数不直接改调用方变量。** 3.2 没有 nameref。

### 禁用语法对照

写之前先看这张表。左边这些**在 3.2 上直接崩**，不是风格问题。

| 别写 | 写这个 | 在 3.2 上会怎样 |
|---|---|---|
| `declare -A m` | `case` 分派，或两个平行数组 | 报 `declare: -A: invalid option` |
| `${v^^}` / `${v,,}` | `printf '%s' "$v" \| tr a-z A-Z` | `bad substitution` |
| `local -n ref=$1` | 出参：`printf -v "$outvar" '%s'` | 报无效选项 |
| `mapfile -t a < f` | `while IFS= read -r l; do ...; done < f` | `command not found` |
| `[[ -v x ]]` | `[ -n "${x:-}" ]` | 条件表达式语法错 |
| `"${arr[@]}"`（数组可能为空） | `${arr[@]+"${arr[@]}"}` | `set -u` 下 unbound variable |
| `arr+=(x)` | `arr[${#arr[@]}]=x` | 能跑，但别和空数组展开混用 |

其余注意：`local -a` 声明数组可以，但未赋值的空数组在 `set -u` 下遍历会报错，
一律写成 `${arr[@]+"${arr[@]}"}`。

### 动手前

1. **先找现成的。** 需要的能力大概率已经在 `lib/core/` 里：日志、配置、下载、校验、
   重试、锁、清理、交互、CLI、i18n。不要先写一版再想着替换。
2. **不确定签名就查 `docs/REFERENCE.md`，不要发明函数名。** 幻觉出来的 API
   （比如 `conf_require`、`log_success`）会让脚本在运行时才炸，而且错误信息看不懂。
3. **写完就跑验证命令**（见下）。不要声称"应该能跑"。

### 常见任务的落点

| 你想到的事 | 用什么 |
|---|---|
| 打一条日志 | `log_info` / `log_ok` / `log_warn` / `log_error` / `log_debug` / `log_section` |
| 失败就退出并给退出码 | `die` / `fail` / `require_cmd` / `require_root` / `require_file` |
| 读配置，环境变量优先 | `conf_init` 之后用 `conf_get_any KEY DEFAULT` |
| 改配置且要幂等 | `conf_set`；改任意文件用 `fs_ensure_line` / `fs_ensure_block` |
| 写文件不想写坏 | `fs_atomic_write`；备份用 `fs_backup` |
| 下载并校验 | `net_download URL DEST [SHA256]`，镜像回退已内置 |
| 等端口 / 等 HTTP | `net_wait_port` / `net_wait_http` |
| 跑命令，失败即停 | `run systemctl restart nginx`；`SHELLKIT_DRY_RUN=1` 只打印 |
| 跑命令但要自己判成败 | `run --no-die cmd`（默认的 `run` 失败即 `die`，`die` 的 `exit` 不受 `if`/`||` 约束） |
| 失败重试几次 | `retry 5 curl -fsS "$url" -o x` |
| 保证同时只跑一个实例 | `lock_acquire deploy 30`，拿到即入清理栈 |
| 退出时一定要收尾 | `trap_push 'rm -rf "$workdir"'` + `trap_install` |
| 问用户一个问题 | `ask` / `ask_yn` / `ask_choice` / `confirm`（都支持超时与默认值） |
| 加一个子命令 | `cli_cmd` 注册 + `cmd_<name>` 实现，分发器不用动 |
| 输出中文/英文 | `_t 'english msgid'`，译文在 `locale/` |

### 交付前自检

    bash -n 改过的脚本            # 语法
    shellcheck -S warning -x ...  # 有则跑
    make test                     # 工程里的测试
    ./bin/<name> --help           # 帮助能不能出来

三条判据要同时成立才算过：**退出码为 0**、**没有 FAIL 行**、**你自己看过输出**。
只看退出码会漏掉"命令根本没跑"，只看输出会漏掉静默失效。

### 退出码

| 码 | 含义 |
|---|---|
| 0 | 成功 |
| 1 | 一般错误 |
| 2 | 用法错（参数不对） |
| 3 | 前置条件不满足（缺命令、非 root、该交互却没有默认值） |
| 4 | 网络失败 |
| 5 | 校验失败（sha256 不匹配、文档与代码不一致） |

返回码就是接口的一部分：**不要用 `exit 1` 糊弄所有失败**。
