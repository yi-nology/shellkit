<!-- 生成物：由 tools/ai_doc.sh 拼装，请勿手改。改 docs/ai/repo.head.md 再跑 shellkit docs。 -->

# 这个仓库：shellkit 本身

你在改的是一个 Bash 库 + 脚手架生成器，不是业务脚本。改动会被别人 vendor 走，
所以**向后兼容是硬约束**：0.x 内只加不改，改既有函数语义要单独提一个版本并写迁移说明。

## 地图

    shellkit                  生成器 CLI（new / upgrade / doctor / list / vendor / docs / completion /
                              install-self / uninstall-self / update）
    install.sh                一键安装脚本：取版本 → 下载 release → 校验 sha256 → 交给 install-self
    lib/bootstrap.sh          唯一入口：按 lib/modules.txt 的顺序 source lib/core/*.sh
                              SHELLKIT_MODULES="log fs" 只加载这两个模块和它们的传递依赖
    lib/modules.txt           模块清单的唯一真相源：两列 —— 模块名 + 它依赖的模块
                              （bootstrap、shdoc、站点都读它）
    lib/core/<module>.sh      23 个模块，一个模块一个主题
    templates/                shellkit new 的模板（含 __NAME__ / __CMD__ 占位符）
    tests/                    自研断言 + 逐文件执行器 + 每个模块一个测试
    tests/bats/               bats-core 用例（每个 @test 一个独立进程）；不进 make check，
                              单独 `make bats-check` 跑，CI 里有专门的 job
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
2. 在 `lib/modules.txt` 里加一行 —— 两列：**模块名 + 它依赖的模块**（空格分隔，可不写），
   按依赖拓扑序排，不是字母序。
   顺序只有这一份真相源：`lib/bootstrap.sh` 按它加载，`tools/shdoc.sh` 按它生成 API 参考。
   放错位置或漏写依赖不要紧，`make module-order-check` 会指出「哪个模块调用了还没加载的函数」
   或「哪个依赖没声明」。
3. 写 `tests/test_<name>.sh`。测试文件名被 `tests/test_*.sh` 通配到就自动执行。

## 门禁

    make check     # syntax + test + lint + module-order-check + check-exitcode-docs +
                  # local-names-check + module-count-check + pipe-safety-check +
                  # dup-functions-check +
                  # docs-check + versions-check + check-docs +
                  # cookbook-check + messages-check + examples + fmt，CI 也是这组
    make bats-check  # tests/bats 下的 bats 用例（bats 是外部依赖，不进 check）

`docs-check` 会拦两种事：公开函数缺注释、`docs/` 里的生成物与源码不一致。
`lint` 是 `shellcheck -S warning -x`，模板会先渲染再检查（占位符不是合法语法）。
`local-names-check` 拦的是「同名遮蔽」：出参名撞上出参链路上的某个 local 时，
内容会静默写丢（见下面第 4 条）。
`pipe-safety-check` 拦的是「管道早退」：`grep -q` / `head` 命中即退，上游被 SIGPIPE 打死，
调用方开了 `pipefail` 时整条管道误判失败（见下面第 5 条）。
`dup-functions-check` 拦的是「同名函数定义了两遍」：bash 后定义覆盖先定义，
先写的那份悄悄失效 —— 不报错、不崩，只是你以为在跑 A、其实在跑 B。

## 清单里的指纹是「模板基线」，不是「文件当前内容」

`.shellkit-manifest` 里每个文件记的是**上次成功应用的模板内容的 sha256**。
用户改过的文件，基线**不许**推进 —— 推进了就等于把用户改过的内容记成模板基线，
下一次升级会把这份修改当成「没动过」而覆盖掉（0.10.x 的 P0 缺陷）。
只有真正成功应用了模板的文件才能推进基线；跳过的文件保持原基线。
回归用例：`tests/test_upgrade.sh` 与 `tests/bats/scaffold.bats`（都要连升两次以上）。

## 十一个已经踩过的坑

1. **bash 3.2 与 5 的 trap 语义不同**：子 shell 里 `trap -p EXIT`，3.2 读到空，5.x 仍打印
   父 shell 的 trap 但子 shell 退出时不执行。所以幂等不能只查 `trap -p`，看到是自己的
   处理器就重装一遍（重装无害），也绝不把自己的处理器当调用方的捕获下来。
2. **`$(trap -p ...)` 永远读不到东西**：命令替换本身是子 shell。要重定向到文件再 `cat`。
3. **空数组在 `set -u` 下遍历会报 unbound variable**：一律 `${arr[@]+"${arr[@]}"}`。
4. **`printf -v` 写的是「最近一层声明了该名字的作用域」**：出参名一旦和出参链路上某个
   `local` 同名，内容就写回自己那层，调用方拿到的还是原值 —— 不报错、不崩，只是静默失效。
   prompt.sh 曾因此让交互式 `ask` 永远拿不到用户输入。公开出参入口一律先调
   `_sk_check_out_name` 挡住保留名；链路上新增局部变量要同步进那份名单
   （`tools/check_local_names.sh` 会查漂移）。
5. **`grep -q` / `head` 会把管道上游 SIGPIPE 打死**：命中即退，上游还在写就被杀（141）。
   调用方一开 `set -o pipefail`，整条管道按 141 判失败 —— 「查到了」变成「没查到」，
   而且是竞态（本机常绿、CI 必炸）。库里不写这种管道；`tools/check_pipe_safety.sh` 盯着。
6. **赋值右边别留没引号的 `*`**：`__a=${x%%:*}: ***` 会被拆成两个词 —— 前半截是赋值，
   后半截的 `***` 展开成**当前目录里的文件名**并当成命令执行（报 `AGENTS.md: command not found`）。
   右边可能出现通配符的赋值，一律整体加引号：`__a="${x%%:*}: ***"`。
7. **清单里的名字会变成路径**：`.shellkit-manifest` 的 `name` 会被拼进 `bin/<name>`，
   名字带 `../` 就能把文件写到工程目录之外 —— 而且退出码是 0、日志里看不出来。
   凡是从清单读出来的名字，先过 `_sk_valid_name`；凡是拼出来的路径，
   都要判「落在工程目录内」+「目标不是符号链接」。
   回归用例：`tests/test_upgrade_guard.sh`。
8. **`cp` 会跟随目标的符号链接写穿**：dst 是软链时，内容写进**链接指向的那个文件**，
   链接本身纹丝不动，退出码还是 0 —— 表现为「静默写到预期目录之外」。
   要写文件就用「临时文件 + rename」（库里是 `fs_atomic_write`）；或者像 `cmd_upgrade`
   那样先判「目标不是软链」，是就跳过并提示。
9. **写文件要「临时文件 + rename」，不能 `cp -f`**：`cp -f` 先 truncate 目标再写 ——
   写到一半被打断（断电、磁盘满、进程被杀）留下的是**半截文件**（实测 0 字节到 5MB 不等），
   既不是旧内容也不是新内容；进程被杀掉还可能什么都不提示。
   库里写文件一律走 `fs_atomic_write`（写内容）与 `fs_atomic_copy`（搬文件，逐字节一致）：
   同目录落临时文件再 `rename` 过去 —— rename 是原子的，失败要么什么都没发生、
   要么整体换新；而且它替换的是符号链接**本身**，不会顺着链接写到别处。
   副作用：被杀可能留下 `<目标>.tmp.XXXXXX` 残留。
   回归用例：`tests/test_upgrade_atomic.sh`。
10. **文档注释里的裸尖括号会炸站点构建**：生成的 reference 页是 markdown，VuePress 把它
    当 markdown 解析 —— `<模块名>`、`<DST>` 这样的占位符会被当成 HTML 标签，
    报 `Element is missing end tag`，站点构建整个红（`<目标>` 这种尖括号紧跟中文
    尤其容易漏）。占位符一律包进反引号：渲染成行内代码，含义不变。
11. **vendor 目录要整体换，不要就地改**：就地改（先 `rm -rf` 再 `cp -R`）中途失败会留下
    **半份库** —— 工程的脚本当场就找不到 `vendor/shellkit/lib/bootstrap.sh`，整套东西都坏了。
    现在是「先铺到 `vendor/.shellkit-new`，再整体换上去」：中途失败旧副本完好无损。
    换的动作是两次 rename，中间有一个极短的窗口；窗口里被打断会留下 `vendor/.shellkit-old`，
    下次同步会把它清掉。

## 本场景的验证

    make check
    bash tests/run.sh                # 只看测试
    ./shellkit docs --check          # 只看文档产物是否最新
    bash tools/check_versions.sh     # 只看版本引用是否一致
    bash tools/check_docs.sh         # 只看文档里的示例是否仍然成立
    bash tools/check_module_order.sh  # 只看模块加载顺序对不对
    bash tools/check_local_names.sh  # 只看命名空间与出参保留名单对不对
    bash tools/check_exitcode_docs.sh # 只看公开函数有没有写明返回码
    bash tools/check_cookbook_count.sh # 只看文档里说的场景数对不对
    bash tools/check_pipe_safety.sh  # 只看管道里有没有会提前退出的消费者
    make site                         # 构建文档站（先从 docs/ 同步，再查产物内部链接）

## 发版

`VERSION` 是唯一真相源，pot 头、README、`site/index.md` 与 `site/en/index.md` 都是它的**手抄投影**。所以发版不许手工改：

    make release-dry VERSION=x.y.z   # 先空跑：升版本→重生成→门禁，然后还原工作树
    make release VERSION=x.y.z       # 真发：commit + tag + push，tag 触发 release.yml

改了既有函数的结果（返回码、产出文件名、输出文本）就要升 **minor**，并在
`docs/MIGRATING.md` 加一张「会改变结果的行为变化」表。只加不改的可以升 patch。
