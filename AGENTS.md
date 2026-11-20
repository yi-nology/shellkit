<!-- 生成物：由 tools/ai_doc.sh 拼装，请勿手改。改 docs/ai/repo.head.md 再跑 shellkit docs。 -->

# 这个仓库：shellkit 本身

你在改的是一个 Bash 库 + 脚手架生成器，不是业务脚本。改动会被别人 vendor 走，
所以**向后兼容是硬约束**：0.x 内只加不改，改既有函数语义要单独提一个版本并写迁移说明。

## 地图

    shellkit                  生成器 CLI（new / demo / upgrade / doctor / list / vendor / docs / man /
                              completion / install-self / uninstall-self / update / skill 共 13 个子命令）
    install.sh                一键安装脚本：取版本 → 下载 release → 校验 sha256 → 交给 install-self
                              （配了 SHELLKIT_MINISIGN_PUBKEY[_FILE] 时再验 minisign 签名，见 docs/TRUST.md）
    repair.sh                 独立修复脚本：不依赖已安装的库，检查 .old/.new 残骸并恢复启动能力
    lib/bootstrap.sh          唯一入口：按 lib/modules.txt 的顺序 source lib/core/*.sh
                              SHELLKIT_MODULES="log fs" 只加载这两个模块和它们的传递依赖
    lib/modules.txt           模块清单的唯一真相源：两列 —— 模块名 + 它依赖的模块
                              （bootstrap、shdoc、站点都读它）
    lib/core/<module>.sh      27 个模块，一个模块一个主题
    lib/posix/                POSIX 子集（设备侧）：busybox ash / dash 上能跑的那一小撮
                              shellkit-posix.sh（只写 POSIX 语法的库）
                              capabilities.tsv（能力清单：哪些函数设备侧有、哪些没有；机器生成）
                              含进程层（proc_* 同名版：后台引导 / 整组停止 / 看门狗）
    templates/                shellkit new 的模板（含 __NAME__ / __CMD__ 占位符）
    tests/                    自研断言 + 逐文件执行器 + 每个模块一个测试
    tests/bats/               bats-core 用例（每个 @test 一个独立进程）；不进 make check，
                              单独 `make bats-check` 跑，CI 里有专门的 job
    tools/                    shdoc.awk / comment_coverage.awk / ai_doc.sh / check_docs.sh / term_shot.py
                              check_module_order.sh（模块依赖顺序门禁）
                              check_security.sh（安全边界门禁）/ api_baseline.sh（公开 API 行为基线）
                              check_tree_clean.sh（工作树残留门禁：被打断的运行留下的临时文件）
                              check_ident_boundary.sh（$ident 紧跟非 ASCII 的边界检查，issue #73）
                              bench.sh（性能基准，基线在 tools/bench_baseline.txt）
                              package_tarball / package_syspkg / package_smoke（deb/rpm 打包与冒烟）
                              sign_release.sh（minisign 签名；--require 供正式发布，--file 供事后补签）
                              verify_release.sh（从 Release 重新取回资产、按钉住公钥逐份验签）
                              release_assets.sh（不可变上传：同摘要跳过、异摘要拒绝覆盖）
                              check_trust_pin.sh（TRUST.md 钉的公钥与本次签名钥一致性）
                              release.sh（一条命令发版）/ check_versions.sh（版本引用一致性）
                              site_sync.sh（docs/ → 站点页面）/ site_links.sh（产物链接门禁）
    docs/                     README 之外的深度文档；REFERENCE.md 与 AGENTS.md 是生成物
                              SECURITY.md（安全边界规范）/ JSON.md（doctor --json 字段契约）
                              COMPATIBILITY.md（1.0 兼容承诺：分级、破坏性变更、弃用窗口）
                              TRUST.md（安装信任链：验什么、不验什么、离线怎么验）
                              ROADMAP.md（三层架构与四阶段：退出条件、战略取舍、迭代节奏）
    docs/shots/*.shot         截图源：每行 `$ ` 是真要跑的命令，svg 由 make shots 渲染
    examples/                 两个能直接跑的工程，测试全程走真实二进制
    site/                     VuePress 2 文档站（手写页 + docs/ 同步页；Actions 构建，产物不进 git 历史）
    .github/workflows/        quality（16 项必需检查）/ packages / pages / release
                              bench.yml = 性能基准的**定时**运行（PR 上只量不含套件的快路径）
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
                  # local-names-check + ident-boundary-check + module-count-check +
                  # pipe-safety-check + assert-usage-check +
                  # check-tree-clean + dup-functions-check +
                  # security-check +
                  # api-baseline-check + api-freeze-check + compatibility-check +
                  # docs-check + versions-check + check-docs + posix-check +
                  # cookbook-check +
                  # messages-check + examples + fmt，CI 也是这组
                  # 步骤清单的唯一真相源是 Makefile 的 check 目标（上面这份是投影）
    make bats-check  # tests/bats 下的 bats 用例（bats 是外部依赖，不进 check）
    make check-fast  # 快通道：只跑静态门禁（= check 去掉 test 与 examples），几十秒出结果
                      # 刻意**不改** check 的语义：check 仍是唯一的完整门禁，CI 也只跑 check

`docs-check` 会拦两种事：公开函数缺注释、`docs/` 里的生成物与源码不一致。
`lint` 是 `shellcheck -S warning -x`，模板会先渲染再检查（占位符不是合法语法）。
`local-names-check` 拦的是「同名遮蔽」：出参名撞上出参链路上的某个 local 时，
内容会静默写丢（见下面第 4 条）。
`pipe-safety-check` 拦的是「管道早退」：`grep -q` / `head` 命中即退，上游被 SIGPIPE 打死，
调用方开了 `pipefail` 时整条管道误判失败（见下面第 5 条）。
`assert-usage-check` 拦的是「断言把提示文案当成被测命令的参数」：
`assert_true` / `assert_false` 把**全部**参数交给命令，多一个字符串就多一个参数
⇒ `test` 报「binary operator expected」并退出 2 ⇒ `assert_false` 看到「失败」
就通过 ⇒ 这条断言从无判据能力（见下面第 28 条）。
`dup-functions-check` 拦的是「同名函数定义了两遍」：bash 后定义覆盖先定义，
先写的那份悄悄失效 —— 不报错、不崩，只是你以为在跑 A、其实在跑 B。
`compatibility-check` 拦的是「承诺文档说了却没兑现」：`docs/COMPATIBILITY.md` 声称
每个公开函数都有等级，就要求 `tools/stability_exempt.txt` 为空、文档里的
stable / experimental 数量与源码一致、四个必备小节都在。
`posix-check` 拦的是「POSIX 子集里混进 bash 专有语法」：设备侧脚本跑在
busybox ash 上，混进一个 `local` 或 `[[ ]]` 不是报错，是**整个脚本起不来**
（现场装不了 shellkit 补救）。它同时对账能力清单 `lib/posix/capabilities.tsv` ——
清单与源码漂了就红。
`api-freeze-check` 拦的是「承诺面悄悄变了」：`docs/API-FREEZE.md` 是 1.0 的快照
（50 个 stable 的返回码、退出码表、CLI 子命令形状），源码变了没重生成清单就红；
新增语义未知的 `SK_*` 常量也红（宁可失败，也不静默漏写进承诺表）。

`main` 有分支保护：PR 进 `main` 必须跑满 **16 个必需检查** —— 那份清单就是
`tools/release_gate.sh` 的 `DEFAULT_CHECKS`（job 名逐字一致；改 ci.yml 的 job 名
要同步改两处，否则 PR 永远卡在等一个不会来的检查）。**没有 review 要求**
（agent 驱动、链路上没有人审）；`main` 不可强推、不可删；owner 直推仍然允许
（发版链要把 release 提交推上去）。细节见 `docs/RELEASING.md` 的「main 的保护规则」。

## 清单里的指纹是「模板基线」，不是「文件当前内容」

`.shellkit-manifest` 里每个文件记的是**上次成功应用的模板内容的 sha256**。
用户改过的文件，基线**不许**推进 —— 推进了就等于把用户改过的内容记成模板基线，
下一次升级会把这份修改当成「没动过」而覆盖掉（0.10.x 的 P0 缺陷）。
只有真正成功应用了模板的文件才能推进基线；跳过的文件保持原基线。
回归用例：`tests/test_upgrade.sh` 与 `tests/bats/scaffold.bats`（都要连升两次以上）。

## 三十一个已经踩过的坑

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

12. **输出类断言有三个前提：文案要断全、事实要落到结构上、语言要固定**：
    - 只断一个单词 ⇒ **输出里的路径也算输出**。工程路径里带 `symlink` 时，
      `assert_contains "$out" "symlink"` 恒真 —— 断言被路径白送，判据能力没了，
      而且**不会报错**。断完整文案（`the target is a symlink`），再补一条结构事实
      （`[ -L 目标 ]`、链接还指着原来那个地方）。
    - 临时目录名只能用编号：目录名会出现在被测用例的输出里，带意义的词
      会撞上目标用例的断言关键词（同一个坑，元测试里也踩过一次）。
    - 输出会被**本地化** ⇒ 中文 locale 的机器上，英文文案断言整片炸红
      （国产系统默认 `zh_CN.UTF-8`，正是要上流水线的那批）。所以
      `tests/test_helper.sh` 统一 `export SHELLKIT_LANG=en`，要测本地化行为的
      用例自己写 `SHELLKIT_LANG=''` 放开。
    - 自检：把缺陷造回去，这条用例必须变红；不变红 ⇒ 它没有判据能力。

13. **`--body` 里一个 `exit` 能把整个测试杀成假绿**：stub 的 body 是原样拼进
    shell 函数的，body 里的 `exit` 退出的是**测试脚本自己** —— 退出码恰好 0 ⇒
    runner 判「全过」，后面的断言根本没跑过（`test_svc.sh` 后半段真的消失过）。
    现在 body 在「子 shell 里的函数」中执行：`exit` / `return N` 都只表示
    「stub 的退出码」。自证用例在 `tests/test_stub.sh`。
    写 stub body 设退出码用 `return N`，别用 `exit`。

14. **升级崩在「文件换了、清单没提交」⇒ 那些文件被永久冻结**：
    升级是「换文件」和「改清单」两件事。清单记的是模板基线，判据是
    「磁盘指纹 == 基线」。崩在中间就留下「文件已是新版、清单还记着旧指纹」，
    下次升级看到「磁盘 != 基线」，一律当成「用户改过」——
    那些文件从此再也拿不到模板更新（冻结）。
    解法是 write-ahead journal（升级日志）：动第一个文件之前把
    「这些文件该换成什么指纹」落盘（原子写），清单提交成功后删掉；
    重跑时按磁盘实际指纹比对日志，命中就说明「这是上一轮换上去的」，
    基线推进到它。回归在 `tests/test_upgrade_crash.sh`：每次文件提交后强制
    杀进程，重跑后清单基线必须与磁盘一致，再跑一次必须是「0 left alone」。
    ★ 边界：日志落盘后会对文件与所在目录做一次 `sync`（Linux 按操作数刷，
    macOS 刷全盘）—— 比以前强，但 **sync 不是 fsync 的硬保证** ⇒ 掉电时
    仍可能连日志一起丢，那种情况下仍会冻结；纯 bash 拿不到 fsync，
    要彻底闭环需要外部工具级别的持久化边界。

15. **白名单写成「曾经没覆盖」就会永远掩盖覆盖回退**：覆盖率棘轮原来只做两条
    规则（未覆盖的必须在名单里、名单里的必须还是公开函数），没管第三种情况：
    名单里的函数**已经被覆盖**了却还留着 ⇒ 将来测试被误删、覆盖消失，
    棘轮一声不吭，CI 照样绿。
    现在白名单的正确定义是「当前确实未覆盖的集合」，棘轮要**双向**：
    已覆盖的必须移出（`bash tools/coverage.sh --write-baseline` 一键重生成）。

16. **覆盖率基线是「运行时」的结论，换个环境就是另一份**：分支覆盖基线记的是
    「哪些分支臂**这次跑**没被走到」，而库里有两类分叉：
    ① 按外部工具分叉（`http.sh` 有 jq ⇒ python3 ⇒ 兜底三条路）—— 装了 jq 走 jq
    臂、没装走 python3 臂；
    ② 按平台分叉（`lib/core/os.sh` 按 `uname -s` / `-m` 分叉）—— Linux 与 macOS
    走的不是同一条臂，x86_64 与 arm64 也不是。
    ⇒ **同一份源码在不同环境下得到不同的未覆盖集合**。
    基线在 A 环境生成、门禁在 B 环境跑 ⇒ 棘轮**双向都红**：
    「不在基线里」（B 有 A 没有的臂）+「基线列的分支已被覆盖」（A 有 B 已覆盖的臂）。
    看着像代码坏了，其实是环境不同 —— 这个坑已经踩了三次
    （#145 的 retry 臂、#143 的 http.sh 臂、#150/#151 的棘轮）。
    ⇒ GitHub 的 ubuntu-latest runner 是 x86_64，**预装 jq**（也预装 python3）：
    容器里只装 gettext 是不够的，那个环境生成出来的基线必然对不上。
    基线文件头现在记着「生成环境: os=… arch=… jq=… python3=…」——
    头与当前环境不一致时，门禁**先红并说清是环境不同**（退出码 5），
    别急着怀疑代码；重生成要在与 runner 同环境的容器/CI 里做。

17. **变异测试的 100% 只对「计分位点」负责**：跳过的位点不进分母 ——
    「12 个位点里 5 个计分、7 个跳过」的 100% 不是「全都验过了」。
    报告与 stdout 必须写清四层口径：枚举到多少、campaign 窗口多大、
    计分多少、白名单跳过多少（逐条列出）。否则 100% 会被读成「全都验过了」。

18. **发布顺序和「可选 job」都会让失败静默**：
    `gh release create` 不带 `--draft` 时，资产在验签**之前**就挂在网页上了 ——
    验签失败时用户已经能下到没通过校验的版本。顺序固定为
    draft → `verify_release.sh`（从 draft 重新下载、用 TRUST.md 钉住的公钥逐份验、
    并与 `SHA256SUMS` 对账）→ `gh release edit --draft=false --latest`。
    判据在 `tests/test_release_publish_order.sh`：去掉 `--draft`、或把验签与公开对调，
    用例必须红。
    另一头是 `continue-on-error: true` 的可选 job：`packages` 红了，整个 run 仍显示绿。
    v0.26.0（job 没装 `minisign` ⇒ `exit 3`）与 v0.26.1（`--file` 补签仍要求
    `SHA256SUMS` 整份齐全）都因此**静默缺 deb/rpm**。所以：① 凡是调用 `sign_release.sh`
    的 job，必须在同一 job 内先装 `minisign`（`tests/test_release_signing_tool.sh` 扫
    workflow 文件，不靠人记得）；② 发完必须 `gh release view --json assets` 亲眼看资产清单 ——
    「run 是绿的」不等于「包发了」。

19. **用 `find . -type f` 生成 MANIFEST = 把用户放进去的文件记成自己的**：
    安装清单若按「目录里现在有什么」生成，用户自己放进安装目录的文件会被记成
    「我们装的」⇒ 卸载时连同用户文件一起删（0.26.0 修的 P0）。
    正解：装的时候记「我们装的 + 内容指纹」（`.shellkit-install-manifest`），
    卸载逐条比对 —— 用户新增的文件不在清单里、用户改过的文件指纹对不上，
    都保留并告警；整体清理只在 `--purge`。故意保留用户文件不算失败（退出码 0），
    只有真的删不掉才是非 0。回归用例：`tests/test_install_ownership.sh`。

20. **重命名一个不可写的目录，在 macOS 上会失败（Linux 不会）**：
    macOS 的内核要改写目录里的 `..` 条目 ⇒ 源目录不可写（555）时
    `rename()` 失败 ⇒ `mv` 失败。Linux 不需要改写 `..` ⇒ 同样的操作成功。
    ⇒ 同一份代码在两个平台上给出不同结果：只读目标目录在 macOS 15 上被
    判成「装不上」（退 5，好包被判成坏包），在 Linux 上正常。
    凡是「解包 / 同步 / 替换目录」这类要用 rename 的地方：**要 rename 的
    那个目录必须可写**，目标权限在 rename **之后**再套；必须先挪走的旧目录，
    挪之前临时加 `u+w`，事后把权限改回原样（用户的数据不该因为我们搬过它
    就变了权限）。
    回归用例：`tests/test_archive.sh`（CASE 8b：只读目标目录必须装得上）。

21. **用 `chmod 555` 造「不可写」现场，在 root 下根本不成立**：root 能
    绕过权限检查 ⇒ 造出来的现场不会触发 ⇒ 用例在 Linux CI（root）上是假红，
    在 macOS（非 root）上才是真红 —— 同一个用例在两个平台红得不一样，排查
    起来最费时间。
    ⇒ 断言要按环境各写各的**真实**结果（不是「看情况放过」），或者干脆别用
    权限造现场。
    回归用例：`tests/test_archive.sh`（CASE 8e：旧内容回填失败必须退 5）。

22. **门禁里的 O(N²) 次 fork，在机器忙时会放大成几十倍**：
    三道静态门禁原本是「纯 bash 逐行扫 + 每问一句就 fork 一次」
    （`check_local_names.sh` 对每个函数重扫一遍文件、`check_docs.sh` 对每个
    代码块跑十几次管道再对每个候选名两次 grep）。
    本机**空闲**时它们分别要 5.4s / 9.8s / 3.0s；同一台机器**负载高**的时候
    分别变成 76s / 88s / 88s —— 放大 15~30 倍。放大的是 **fork 的等待**：
    机器忙时每次 fork 都要排队，几千次 fork 就变成几十秒。
    ⇒ 扫描一律改成**一次 awk 扫完**（把「文件 × 函数」两层循环压成一次遍历），
    名字对账改成纯 bash 的模式匹配（不 fork grep）：改完之后同一台机器
    0.08s / 0.46s / 1.4s，**输出文案与退出码逐字不变**。
    ⇒ 但「跑一遍是绿的」**不能**证明重写没写坏判据：重写最容易把判据能力
    一起写没（本轮就真出现过一次：拼名单的字符串少了开头的换行 ⇒ 第一个
    名字永远匹配不上 ⇒ 门禁把「块内自己定义过的函数」误报成未知函数）。
    ⇒ 改写后必须做**差分验证**：拿旧实现与新实现在一批变异树上逐字比
    输出与退出码（本轮：25 棵变异树 + 39 行管道探针 + 22 棵 markdown 树），
    再做**变异自证**（把实现改坏 ⇒ 用例必须变红）。
    ⇒ 顺便补上门禁的自测：`tools/check_docs.sh` 原来**没有自测**
    （它守着「文档里的示例还能不能跑」，自己静默失效没人会发现），
    本轮补了 `tests/test_check_docs.sh`。

23. **容器里「装包慢」的病根常常是元数据，不是包**：dnf 为了解析依赖，会把
    **每个**启用源的 repodata 都拉下来 —— openEuler 的镜像默认开 8 个源，
    逐源实测：update 184 MB、everything 41 MB、EPOL 11 MB、debuginfo 10 MB
    ⇒ 合计约 268 MB。共享 runner 在美国、镜像站在国内 ⇒ 实测装包 27~45 分钟，
    撞 2700 秒内层超时 ⇒ 偶发被判失败（v1.3.0 发版现场连撞 3 次，最后一次
    重跑才绿）。
    ⇒ 先量「**每个源**的 metadata 有多大」，再决定是**少开源**还是**加超时**：
       只留 OS/everything/EPOL/EPOL-update 四个源就够（bash/gettext/make/
       python3/git/msgfmt/tar/xz 全到位），metadata 降到 60 MB（-78%）。
       「加超时」只是把失败推后，「少开源」才是把问题解决。
    ⇒ 少开源只对**匹配的发行版**生效：Rocky 的源 ID 完全不同，拿一个发行版的
       经验去改另一个，等于把假设套到别人的发行版上。
    ⇒ 判据：`tests/test_ci_openeuler_repos.sh`（四个重源必须被禁 + 禁用必须
       被 openEuler 判定护住 + 弱依赖/文档必须关；注释里写对不算数）。

24. **macOS 上进程创建贵一个量级 ⇒ 性能判据要用「fork 次数」，不能用耗时**：
    实测（同一份代码，macOS `/bin/bash` 3.2 vs Debian bash 5.2，各跑 102 个
    测试文件，全绿）：macOS 22.6 分钟 vs Linux 7.8 分钟 = **2.9 倍**。
    逐文件量下来，慢的那几个**不是算法慢**，是被 fork 次数堆出来的：
      test_coverage_branch.sh 7039 次 fork（其中 5779 次是 grep）
      test_upgrade_crash.sh   6153 次 fork（其中 2054 次来自 `_t` 的域名后缀转换）
      test_skill.sh           2329 次 fork
    根因是**进程创建成本**：macOS 上 `fork+exec` 约 43ms/次，Linux 约 2~3ms/次
    （纯子 shell 也要 10ms ⇒「少 fork 一次」比「少写一次循环」值钱得多）。
    ⇒ 判据口径一律用 **fork 次数**：次数与机器快慢无关 ⇒ 门槛在任何机器上
      都一样；慢机器只会被次数放大，不会把门槛也放大。
      **拿耗时当门槛 = 拿机器当判据**（慢机器上门槛自动变松 ⇒ 缺陷在慢机器
      上就漏过去了）。
    ⇒ 热路径不许起外部进程：`tests/test_no_hot_fork.sh` 钉住「装载库 0 次 exec」
      「`_t` 0 次 exec」+「后缀转换与改前逐字一致」+ 三条变异自证。
    ⇒ 改热路径前先**数 fork**（别先优化算法）：bash 3.2 没有 `${v,,}` ⇒
      「大写转小写」只能 fork `tr`；但**恒等变换**可以纯 bash 化 ——
      「域名本身就是合法标识符时，`tr` 的两步（大写转小写 + 非白名单换 _）
      都不会碰它 ⇒ 输出逐字等于输入」⇒ 纯 bash 快路 + 原有 `tr` 兜底，
      **输出逐字一致**（19 个域名 × 3 个 locale 实测全等），且零 fork。
    ⇒ 判据自己也会空转：本轮真踩了 —— 批量 `ln` 的参数序错了（BSD 的 `ln`
      没有 GNU 那个「目标+目录+多源」形式）⇒ 一个包装器都没建 ⇒「零调用」
      **恒真** ⇒ 判据必须先自证包装器真的在记（跑一个被盯住的命令，看日志里
      有没有它）。同一个命令里的多个赋值还是**按顺序生效**的：
      `PATH="$BIN:$PATH" SPAWN_REAL_PATH="$PATH"` 里后者展开到的是**新** PATH
      ⇒ 包装器会把自己当成真命令 ⇒ 无限递归 ⇒ 判据挂死。

25. **门禁的「单文件上限」要按那个文件自己的预算算，文案也要报那个数**：
    `tests/run.sh` 早就支持在文件头写「# TEST_TIMEOUT: 900」单独放宽
    （只放宽那一个文件，不拖累其他文件的卡死检测），但有两处没做：
      ① 超时文案写死全局的 300 ⇒ 撞了 900 秒预算的文件被报成
         「timed out after 300s」⇒ 人会去改全局 ⇒ 全局一改，**所有**文件的
         卡死检测都跟着变慢（正是这个机制要避免的）。
      ② 「确定但重」的文件没有单独预算 ⇒ 慢机器上撞全局 300 ⇒「机器慢」
         被误读成「测试坏了」⇒ 随机红灯 ⇒ 很快被忽略，连真红灯都看不见。
    ⇒ 文案改报**该文件自己的预算**（并区分「默认预算」与「自己的预算」），
      plain 路径也补一句原因（超时是唯一「屏幕上什么也看不出来」的失败）。
    ⇒ 判据：`tests/test_runner.sh` —— 声明 1 秒的 fixture 必须**真的**在
      1 秒左右被掐掉（不是 300 秒）+ 文案必须报 1s 且不得出现 300s +
      **变异自证**（把文案改回报全局 ⇒ 判据必须红）+「声明集合不得静默扩大」
      （谁放宽了哪个文件必须登记在册，预算有 1800 秒上限）+ 全局默认不得低于 300。

26. **locale 的排序规则会污染「范围」判定**：`case "$x" in *[!a-z0-9_]*)` 里的
    `[a-z]` 是**范围**，按当前 locale 的排序规则解释 —— 在 en_US.UTF-8 下它连
    **大写字母**都算 ⇒ 「这个域名是不是已经规范的小写标识符」这类判定会在
    某些机器上给出相反的答案。
    实测：/bin/bash 3.2 + en_US.UTF-8 ⇒ `case UPPER_case9 in *[!a-z0-9_]*)`
    **不匹配** ⇒ 大写域名被当成「已经规范」⇒ 原样返回 ⇒ 译文函数名带着大写
    ⇒ 永远查不到译文（症状：界面不跟着 locale 变，而且只在部分机器上出现）。
    ⇒ 判定「某个字符是否属于某个集合」**不许用范围**：用**字面量**
      （`a|b|c|…`）—— 字面量匹配是精确匹配，与排序规则无关。
      ⚠️ POSIX 字符类（`[[:lower:]]`）是 ctype 语义、不受排序规则影响，但它在
      UTF-8 locale 下**包含非 ASCII 小写字母**（如 é）⇒ 要「纯 ASCII」还得再挡一层。
    ⇒ 判据不许「碰运气」靠当前 locale：显式找一个 UTF-8 排序规则的 locale
      **点名**跑一遍；找不到就**明说这条没跑**，不许静默跳过
      （Linux 容器是 C.UTF-8 ⇒ 同一个缺陷在 Linux 上完全测不出来；
      macOS runner 是 en_US.UTF-8 ⇒ 红灯只在部分机器上亮 ⇒ 很快被忽略）。
    ⇒ 回归：`tests/test_no_hot_fork.sh`（差分判据点名跑 UTF-8 locale +
      变异自证「让快路接受大写」——后者在**任何** locale 下都让差分有牙齿）。

27. **`local a=$x b=$a` 不串联**：同一个 `local`/`declare` 语句里，**词展开
    先于赋值** ⇒ `b` 拿到的是**旧的**（多半是空的）`$a`，不是刚赋的值。
    实测：`local __d=${1:-} __rest=$__d` ⇒ `__rest` 是空 ⇒ 后面所有基于它的
    判定都变成「恒真」⇒ 代码**静默失效**（不报错、不崩，只是永远走那条路）。
    ⇒ 一行只声明一个变量；确要多声明就分行写。
    ⇒ 与坑 4（`printf -v` 写回最近一层作用域）同族：都是**静默失效**类。

28. **断言把提示文案当成参数传给被测命令 ⇒ 断言变假绿**：
    `assert_true`/`assert_false` 把**全部**参数交给被测命令 ⇒
    `assert_false test -e "$p" "说明"` 实际执行的是 `test -e <路径> "说明"`
    ⇒ test 报「binary operator expected」并退出 **2**（非 0）⇒
    `assert_false` 看到「失败」就**通过**了 ⇒ 这条断言从头到尾没有判据能力：
    目录真的被创建出来时，它照样绿。
    ⇒ 给 `test` 传第三个参数时，它必须是**运算符**；要带说明就自己写
      `if ...; then _fail "..."; fi`。
    ⇒ 回归：`tests/test_scaffold.sh`（那条「被拒的工程不许被创建」）。
    ⚠️ 更隐蔽的一层：这类假绿**不会让 CI 红**，只在日志里留一行 test 的报错
      ⇒ 要**扫**全仓的用法，而不是只修被抓到的那一处。
    ⇒ 现在有门禁兜住：`tools/check_assert_usage.sh`（`make assert-usage-check`）
      扫全仓 `tests/` 与 `examples/`，按 test/[ 的**参数个数与位置**判定
      （引号感知切分 —— 说明文案里通常带空格，按空白切会把一条参数
      切成好几段，参数个数就数错了，判据会失灵还不报错）。
      门禁自己的自测：`tests/test_assert_usage.sh`（真树合格 / 假树坏用法
      必被点名 / 合法人用不误伤 / 变异自证）。

29. **整组停的那一行写法，在三种 shell 上三种结果**：
    「kill 整个进程组」看着只有一种写法，其实是三种：
    - `kill -TERM -- -1234`：**bash 只认这一种**；
      busybox 报 `invalid number '--'`（它把 `--` 当成 pid 了），
      dash 报 `Illegal number: -` ⇒ 两边都**没杀成**，退出码非 0。
    - `kill -TERM -1234`（不带 `--`）：**busybox / dash 认**；
      bash 会把 `-1234` 当成信号名 ⇒ 报错。
    ⇒ 库里两种都试（先带 `--`，失败再不带），且**绝不**只靠一种写法。
    ⚠⚠ **信号名必须带前导 `-`**（`kill -TERM`，不是 `kill TERM`）：
      busybox 的 kill 认不带横杠的信号名（把 `TERM` 当信号），
      而 dash 与 bash 会把它当成**一个 pid** ⇒ `TERM: Illegal number`
      ⇒ 整组杀**根本没发生** ⇒ 进程停不掉（退出码 3），而日志里只有一行
      被吞掉的报错。
      ⇒ 更狠的是：这条错**只在有 setsid 的机器上才走到**
      （macOS 没有 setsid ⇒ 走「只停主进程」的降级 ⇒ 本机永远是绿的）
      ⇒ 判据必须在**目标环境**（busybox ash + dash）里跑，本机跑绿不算数。
    ⚠ 同一批实测还发现：**busybox 的 `ps` 不认 `-p`**
      （`invalid option -- 'p'`），也不认 `stat=` 的表头抑制
      ⇒ 进程状态与进程组要读 `/proc/<pid>/stat`（Linux 上到处都有），
      `ps` 只当兜底。
    ⚠ 还有一条：**`setsid` 在「已经是组长」时会 fork** ⇒ 父进程拿到的
      `$!` 是 setsid 的 pid，不是真正那条命令的 pid ⇒ pid 让**子进程自己写**
      （exec 不改 pid ⇒ 写的必然是它）。
    ⇒ 回归：`tests/posix_smoke.sh`（同一份判据在 dash 与 busybox ash 上跑；
      证据是 busybox:1.36 容器里的逐条实测，不是推测）。
30. **判据脚本里起名叫 `fail` / `die` 这类通用名 ⇒ 顶掉被测库的同名函数 ⇒ 整份判据变假绿**：
    POSIX 子集自己有一个公开的 `fail()`（与 `die()` 一对）⇒ 判据脚本
    在 source 之后**再定义**一个 `fail()`，被测库那份会覆盖脚本的
    （bash 与 ash 都是后定义覆盖先定义）⇒ 脚本自己的失败计数**永远不增**
    ⇒ 判据全绿，而失败信息只是库里打的一行错误日志（看起来像「库报了错」，
    不是「判据抓到了缺陷」）。
    ⇒ 判据脚本里的辅助函数必须用**独占前缀**（本轮用的是 `smoke_fail`），
      且**不能**与被测库的公开函数重名。
    ⇒ 这正是 `tools/check_dup_functions.sh` 门禁防的那类事故 ——
      但那道门禁只扫 `lib/core/`，扫不到 `tests/` ⇒ 判据脚本要自己长记性。
    ⇒ **推论**：判据脚本 source 被测库之后，要检查自己的辅助函数名有没有被顶掉
      （或反过来：先定义、再 source 也不行 —— 后 source 的会覆盖先定义的）。
31. **进程状态要按**前缀**认，不能精确匹配**：
    僵尸在各家的 `ps` 里写法不一样：Linux 常见 `Z`、macOS/BSD 常见 `Z+`，
    还有 `Z<` ⇒ 写成 `case "$st" in Z) ...` 只能认中一种 ⇒ 另一种机器上
    僵尸被当成**活进程** ⇒ pid 文件永远清不掉、看门狗永远以为进程还在
    （正是这一层要根治的坑）。
    ⇒ 一律用前缀（`Z*`），并且把「各种写法」写进**不依赖平台的断言**
      （直接喂 `_sk_posix_proc_state_is_dead "Z+"`），
      否则判据会跟着平台的 ps 写法一起漂 —— 本机绿、CI 红。

32. **bash 扩展在 POSIX 子集里不是「报错」，是**静默失效** ⇒ 设备侧拿到空结果**：
    POSIX 子集（设备侧那套 busybox ash / dash）只能写 POSIX sh 语法。
    本轮在语义分叉的修复里用了 `$((10#08))`（去前导零）—— **bash 扩展**，
    POSIX 没有。
    ⇒ 在 **macOS 的 bash 上**：一切正常（本机全绿）。
    ⇒ 在 **dash 上**：`arithmetic expression: expecting EOF: "10#1"`
      ⇒ 那一行的输出变成**空字符串**，而函数**仍然返回 0**
      ⇒ 版本比较静默返回空（不是报错！）。
    ⇒ 这类缺陷**在 macOS 上根本测不出来**（本机默认 `/bin/bash`）——
      只有把同一份判据真的丢给 dash / busybox ash 跑才会暴露。
    ⇒ POSIX 子集里禁止用：`10#`、数组、`[[ ]]`、`local`、`printf -v`、
      `${var^^}`、`mapfile`、`source`（用 `.`）。
    ⇒ **判据必须点名跑真解释器**：`tests/posix_semantics.sh` 是一份 POSIX sh
      脚本 ⇒ 同一份在 dash 与 busybox ash 上原样跑（CI 的
      「posix subset on busybox ash」job）。本机没装 dash/busybox 时，
      **明说没跑**，不许静默跳过。
    ⇒ 附带一条：`[ a \< b ]`（字符串比较）在 POSIX 里是**未定义行为**
      （shellcheck SC3012）⇒ 改用 `sort` 的字典序判定。

## 本场景的验证

    make check
    make check-fast                  # 只看静态门禁（几十秒；改代码时的快速反馈）
    bash tests/run.sh                # 只看测试
    ./shellkit docs --check          # 只看文档产物是否最新
    bash tools/check_versions.sh     # 只看版本引用是否一致
    bash tools/check_docs.sh         # 只看文档里的示例是否仍然成立
    bash tools/check_module_order.sh  # 只看模块加载顺序对不对
    bash tools/check_local_names.sh  # 只看命名空间与出参保留名单对不对
    bash tools/check_ident_boundary.sh # 只看 $ident 紧跟非 ASCII 时的边界（issue #73）
    bash tools/check_exitcode_docs.sh # 只看公开函数有没有写明返回码
    bash tools/check_cookbook_count.sh # 只看文档里说的场景数对不对
    bash tools/check_pipe_safety.sh  # 只看管道里有没有会提前退出的消费者
    bash tools/check_security.sh     # 只看安全边界（路径/软链/权限/脱敏/锁/原子写）
    bash tools/api_baseline.sh       # 只看公开 API 的承诺与基线、MIGRATING 声明是否一致
    bash tools/bench.sh              # 只看性能基准（--check 跟基线比；--write-baseline 重写基线）
    bash tools/coverage.sh --write-baseline  # 按真实覆盖率重生成白名单（只记当前未覆盖的）
    bash tools/mutation.sh --target lib/core/fs.sh --test "bash tests/test_upgrade_guard.sh" \
      --from-line $(grep -n '^_sk_fs_rel_safe()' lib/core/fs.sh | cut -d: -f1) \
      --to-line $(grep -n '^_sk_fs_no_symlink_below()' lib/core/fs.sh | cut -d: -f1)  # 变异位点
    make site                         # 构建文档站（先从 docs/ 同步，再查产物内部链接）

## 发版

`VERSION` 是唯一真相源，pot 头、README、`site/index.md` 与 `site/en/index.md` 都是它的**手抄投影**。所以发版不许手工改：

    make release-dry VERSION=x.y.z   # 先空跑：升版本→重生成→门禁，然后还原工作树
    make release VERSION=x.y.z       # 真发：commit + tag + push，tag 触发 release.yml

改了既有函数的结果（返回码、产出文件名、输出文本）就要升 **minor**，并在
`docs/MIGRATING.md` 加一张「会改变结果的行为变化」表。只加不改的可以升 patch。
什么算「结果」、弃用要提前多久、哪些函数不承诺 —— 见 `docs/COMPATIBILITY.md`（v0.27.0 起生效）。

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
3. **想知道「有没有现成的」⇒ 扫一眼 `references/capabilities.md`**（全部公开函数，
   一行一个）。下面的落点表覆盖的是**常用路径**，索引覆盖的是**全部** ——
   「表里没写」不等于「库里没有」：`str_suggest` 早就在库里，多个工程还是
   自己写了一遍编辑距离（issue #161 的实证）。
4. **写完就跑验证命令**（见下）。不要声称"应该能跑"。

### 常见任务的落点

| 你想到的事 | 用什么 |
|---|---|
| 打一条日志 | `log_info` / `log_ok` / `log_warn` / `log_error` / `log_debug` / `log_section` |
| 失败就退出并给退出码 | `die` / `fail` / `require_cmd` / `require_root` / `require_file` |
| 读配置，环境变量优先 | `conf_init` 之后用 `conf_get_any KEY DEFAULT` |
| 改配置且要幂等 | `conf_set`；改任意文件用 `fs_ensure_line` / `fs_ensure_block` |
| 写文件不想写坏 | `fs_atomic_write`（写内容）；搬文件用 `fs_atomic_copy`（逐字节一致）；备份用 `fs_backup` |
| 下载并校验 | `net_download URL DEST [SHA256]`，镜像回退已内置 |
| 解开 tar / zip 包 | `archive_extract ARCHIVE DEST [SHA256]`（挡路径穿越与软链逃逸，失败不留半份）；先看内容用 `archive_list` |
| 只想演练不想落盘 | `SHELLKIT_DRY_RUN_FILES=1`：`fs_*` / `conf_*` 的写原语只打印计划不写盘（`SHELLKIT_DRY_RUN` 只管 `run` / `svc`） |
| 等端口 / 等 HTTP | `net_wait_port` / `net_wait_http` |
| 跑命令，失败即停 | `run systemctl restart nginx`；`SHELLKIT_DRY_RUN=1` 只打印 |
| 命令行里有口令/令牌 | `run` 的日志自动脱敏；启发式认不出来的用 `run --secret-arg N` / `run --redact-value V` 显式声明 |
| 跑命令但要自己判成败 | `run --no-die cmd`（默认的 `run` 失败即 `die`，`die` 的 `exit` 不受 `if`/`||` 约束） |
| 失败重试几次 | `retry 5 curl -fsS "$url" -o x` |
| 保证同时只跑一个实例 | `lock_acquire deploy 30`，拿到即入清理栈 |
| 退出时一定要收尾 | `trap_push 'rm -rf "$workdir"'` + `trap_install` |
| 问用户一个问题 | `ask` / `ask_yn` / `ask_choice` / `confirm`（都支持超时与默认值） |
| 加一个子命令 | `cli_cmd` 注册 + `cmd_<name>` 实现，分发器不用动 |
| 输出中文/英文 | `_t 'english msgid'`，译文在 `locale/` |
| 调 HTTP 接口 | `net_request GET URL [--header 'K: V'] [--json BODY]`（`SK_HTTP_CODE` / `SK_HTTP_BODY` / `SK_HTTP_HEADERS`）；要 JSON 就 `net_json ... --path a.b.c` |
| 读 dotenv | `conf_load_dotenv FILE`（只进配置层）；要导出给子进程用 `conf_source FILE` |
| 同一条命令并发跑 N 份 | `run_concurrent 8 -- ./deploy.sh`（stdout 给成功数，stderr 逐实例标注） |
| 起/停/查系统服务 | `svc_start` / `svc_restart` / `svc_is_active`（写类动作吃 `SHELLKIT_DRY_RUN`；macOS 上写类动作返回 3） |
| 比较版本号 | `ver_cmp` / `ver_gt` / `ver_lt` / `ver_eq`（纯 bash 分段比较，别用 `sort -V`；非法输入返回 2，不伪装成「相等」） |
| 输出机器可读状态 | `SHELLKIT_STATUS_MODE=machine` + `status_emit STATE 人类文案`（再按需 `status_version` / `status_extra`） |
| 日志要能进采集系统 | `SHELLKIT_LOG_FORMAT=json`；按级别过滤用 `SHELLKIT_LOG_LEVEL=warn`；落文件用 `SHELLKIT_LOG_FILE=/var/log/x.log` |
| 输错的命令名给个建议 | `str_suggest "cmd" "cmd1 cmd2"`（编辑距离；**库里早就有**，别再自己写一遍） |
| 字符串的小判断 | `str_contains` / `str_starts_with` / `str_ends_with` / `str_trim` / `str_lower` / `str_upper` / `str_repeat` |
| 校验用户输入 | `validate_not_empty` / `validate_single_line` / `validate_key` / `validate_port` / `validate_ip` / `validate_url` / `validate_version` / `validate_abs_path` / `validate_enum` |
| 一批命令并发跑 | `parallel_map 4 -- cmd args...`（逐条标注，汇总成功数） |
| 命令/函数要超时 | `run_timeout 30 cmd` / `run_func_timeout 30 my_func args` |
| 进程组与看门狗 | `proc_start` / `proc_stop` / `proc_is_running` / `proc_watchdog`（bash 侧靠作业控制；**POSIX/ash 侧有同名版本**：无作业控制 ⇒ 靠 setsid 拿进程组，拿不到时只停主进程） |
| 查发行版与包管理器 | `os_distro_id` / `os_distro_name` / `os_pkg_manager` / `os_pkg_install` / `os_pkg_update` / `os_has_cmd` / `os_is_root` |
| 原地改文件里的字符串 | `os_sed_i FILE PATTERN REPL`（带备份） |
| 算文件哈希 | `os_sha256 FILE` / `os_md5 FILE` |
| 退出时按顺序收尾 | `trap_push 'rm -rf "$workdir"'` + `trap_install`；另有 `trap_list` / `trap_pop` / `trap_cleanup` |
| 读写键值文件 | `profile_write` / `profile_append` / `profile_parse` / `profile_env` |
| 操作 Git 仓库 | `git_is_dirty` / `git_default_branch` / `git_fetch` / `git_fast_forward` / `git_tag` / `git_worktree_add` |
| 解包前先看看内容 | `archive_list ARCHIVE`（`archive_extract` 会挡路径穿越与软链逃逸） |
| 找库副本在哪 | `vendor_dir` / `vendor_dir_detect` / `vendor_dir_source`（doctor / upgrade / repair 读同一个答案） |
| 查上游最新版本 | `http_github_latest_tag REPO` / `http_github_release_asset REPO TAG PATTERN` |
| 改配置里的某一项 | `conf_set KEY VALUE` / `conf_unset KEY` / `conf_disable KEY` / `conf_keys` |
| 管理 systemd 单元 | `svc_enable` / `svc_disable` / `svc_reload` / `svc_is_enabled` / `svc_daemon_reload` / `svc_install_unit` |
| 新工程要带自定义变量 | `shellkit new ./x --set KEY=VALUE`；变量声明在模板的 `template.config` |
| 已有工程跟上模板更新 | `shellkit upgrade ./x`（本地改过的文件会跳过并告警） |

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
