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
   ├─ lib/           23 个模块（bootstrap.sh + core/*.sh）
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

就这些。`bootstrap.sh` 会按拓扑序把 23 个模块加载好，设置 `SK_*` 常量与退出码，
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


### 0.13.0 → 0.14.0：会改变结果的行为变化

这一版按第三方技术评审修了一批**可靠性与接口语义**问题。凡是行为变了的地方都列在下表里。

| 变化 | 以前 | 现在 | 你会在哪里撞到 |
|---|---|---|---|
| `svc_install_unit` 的 NAME | 任意字符串直接拼进 `/etc/systemd/system/` 后面 —— 带 `../` 能把 unit 文件写到那个目录之外（还是用 root 权限写） | 必须是单个合法文件名（字母数字与 `:_.@+-`）；带路径组件返回 2 并说明原因 | 用目录形态或奇怪字符当 unit 名的调用方 |
| `svc_install_unit` 在 root 下 | 仍然强制调 `sudo` —— 极简容器里常有 root 但没有 sudo 命令，明明有权限却失败 | root 直接写、不套 sudo | 无 sudo 的容器、root 用户 |
| `ver_cmp` / `ver_gt` / `ver_lt` / `ver_eq` 的非法输入 | 「当相等」：`ver_cmp` 返回 0、`ver_eq` 判真 ⇒ **没法比较与版本相等混为一谈** | 返回 2（用法错），不输出比较结果；判否仍是 1 —— 「不等」与「没法比较」可区分 | 依赖「非法当相等」的调用方（合法输入的行为一字未变） |
| `registry_deps` / `registry_topo` 遇到未注册的依赖 | 把缺失的依赖当**普通节点**混进排序结果 —— 照着结果执行的顺序是错的 | 报 `missing dependency` 并返回非 0 | 依赖图里有悬空引用的注册表 |
| 旧清单（v0.10 时代）里「旧模板校验通过」的文件 | 第一次升级**不更新文件**、却把清单升成新版格式，第二次升级才真正更新 | 第一次升级就更新到位 | 从 0.10.x 升上来、文件没被改过的工程 |
| 旧清单里「对照渲染不出来」的文件 | 基线照记旧指纹 ⇒ 第二次升级把它当「没动过」而**覆盖** | 与「对不上」同款处置：不动 + 基线清空，永远不覆盖 | 旧工程里模板渲染不出来的文件 |
| 同一个工程并发跑升级 / vendor | 两个进程互踩固定的暂存目录名（`.shellkit-new` / `.shellkit-old`） | 拿不到工程锁就拒绝（退出码 3，提示 another instance）；`upgrade --check` 只读不抢锁 | 有并发跑升级的脚本 / CI |
| 升级 / `install-self` 被杀在两次 rename 之间 | 下次运行把唯一完整的旧副本当残骸**删掉**，工程从此没有库 | 先把旧副本恢复回去，再继续安装；用户在副本里自加的文件不丢 | 断电、SIGKILL 后重跑 |
| 生成工程的 Makefile 用户可见文案（`make help` 说明行、找不到 shellkit / 生成不了补全 / 没有库副本等报错） | 一律硬编码中文 —— 英文用户拿到中文提示 | 按**生成 / 升级工程那一刻**的语言定下来：zh 译文与旧文案逐字一致（中文用户零变化），en 拿到英文；可用 `--set MSG_*=...` 逐条覆盖 | 用新版重新生成或升级工程后，Makefile 文案跟着那次命令的语言走 |

只加不改的部分：正常升级路径、单文件原子写的语义、`--check` 的输出口径都没变。
测试基建顺带修了一个假绿（stub 的 `--body` 里 `exit` 会杀掉整个测试脚本且退出码为 0），
这不影响库的使用者。

### 0.14.0 → 0.15.0：会改变结果的行为变化

这一版按第四轮技术评审收口了**崩溃一致性**与**质量门禁的有效性**。
凡是行为变了的地方都列在下表里。

| 变化 | 以前 | 现在 | 你会在哪里撞到 |
|---|---|---|---|
| 升级中途被 SIGKILL 之后重跑 | 文件已经换成新版、清单还记着旧指纹 ⇒ 下次升级把这些文件判成「用户改过」，**从此再也拿不到模板更新**（冻结） | 升级前先写升级日志（`.shellkit-upgrade-journal`），重跑时按磁盘实际指纹比对日志，命中就说明「这是上一轮换上去的」，基线推进到它，文件解冻 | 在升级中途被杀的工程（断电、SIGKILL、磁盘满） |
| 工程目录里的新文件 | —— | 升级进行中会有 `.shellkit-upgrade-journal`；升级成功（清单提交后）自动删除。升级被中断时它会留下 —— 那是恢复的依据，不是垃圾，可以手工删 | 升级被中断后重跑成功，文件自动消失 |
| `upgrade --check` 的输出 | —— | 命中恢复时会多一行 `recovered from an interrupted upgrade` | 断言升级输出行数的脚本 |
| 安装目录里的新文件 | —— | 装好的副本里多一份 `repair.sh`，`PREFIX/bin/` 下多一个 `shellkit-repair` 软链 | 卸载会按 MANIFEST 一并删掉；`install-self` 的 MANIFEST 里多一行 |

只加不改的部分：正常升级路径的判定与输出、单文件原子写的语义、`--check` 的口径都没变。
另外三条只动工具与门禁，不影响库的使用者：

- `tools/coverage.sh` 的白名单棘轮改成**双向**：未覆盖的函数必须在名单里，
  **已经覆盖的必须不在名单里**（否则将来测试被误删、覆盖消失，CI 照样绿）。
  新增 `--write-baseline`：按本次结果一键重写白名单。
- `tools/mutation.sh` 的报告与 stdout 多写明四层口径（枚举 / campaign 窗口 /
  计分 / 白名单跳过）。得分仍然只对计分位点负责 —— 100% 不等于「全都验过了」。
- `tests/run.sh` 支持在文件头写 `# TEST_TIMEOUT: 900` 单独放宽某个文件的时间上限
  （变异测试的 campaign 天然就慢），全局上限不变。

### 0.16.0 → 0.17.0：会改变结果的行为变化

这一版把「不误删用户数据」「不越界写入」「不静默覆盖」三条契约补到 skill
安装/卸载与 repair 上，发版流水线加了质量准入（#39-#45）。四处会让既有
操作算出**不一样但更安全**的结果：

| 变化 | 以前 | 现在 | 你会在哪里撞到 |
|---|---|---|---|
| `skill uninstall` 的删除判据 | 按「文件名对得上」删：用户自加的文件被静默删除、用户改过的 `SKILL.md` 一并没了，退出码 0 | 只删「所有权清单（`.shellkit-skill-manifest`）里有、且内容指纹一致」的文件；清单缺失的旧安装退化到「与当前 skill 包逐字节一致才删」。有保留项时退出码仍为 0，但输出列出保留了什么 | 0.16.x 装过 skill 且在目录里加过东西的人：重装一次（`skill install`）就有清单了 |
| `skill install` 的覆盖判据 | 目标目录里已有同名文件一律覆盖，无任何提示 | 目标内容 == 模板原文（含上次安装的基线）才覆盖；用户改过的**默认跳过并告警**，`--force` 才覆盖。内容已是目标内容时不再重复写（幂等） | 手改过已装 skill 的人：更新会被跳过并告警，确认要覆盖就 `skill install --force` |
| `skill install` 的路径边界 | `references/` 预置一个软链，安装会把文件写到目标根之外（退出码 0） | 目标根之下每一级**已存在的目录**都必须是真目录 —— 是符号链接（无论指向根内还是根外）就拒绝安装，退出码 3 | 用软链共享 skills 目录的人：改用 `--dir` 指到真实目录，或用硬目录 |
| `repair.sh` 的完整性判据 | 只有 `lib/bootstrap.sh` 在就算「完整」—— 会把唯一的完整备份删掉，再报告「已恢复可用」 | 判据升级为「这份副本能不能真的跑起来」（bootstrap + `lib/modules.txt` + 清单点名的每个模块 + VERSION + 可执行 CLI）；恢复改成状态机：旧副本挪回去**验证通过**才清坏副本，两份都坏就明说要重装、什么都不删 | 主副本半份、旧副本完整时：现在会真的把好副本恢复回来 |
| `repair.sh` 对符号链接 | 会跟着链接判完整性 | 目标本身是符号链接一律判不完整（不跟随） | —— |
| 升级日志（write-ahead journal） | 损坏静默跳过；记录只增不减 | 损坏行逐条计数并告警；旧记录只留「指纹还与磁盘对得上」的（反复升级失败不再无限累积）；落盘后对文件与目录做一次 `sync` | 反复升级失败的工程：`.shellkit-upgrade-journal` 不再长尾巴；日志坏过会有 WARN |

只加不改的部分：`lib/core/fs.sh` 新增的路径校验与所有权清单函数都是私有内部能力
（`_sk_fs_*`），公开 API 一律未动；`vendor` / `install-self` 的目录换名收敛成同一个
内部实现，行为（含恢复提示文案）与 0.16.0 一字不差。`skill list` 新增「已被改动」
状态标注（有清单时指纹对不上才显示），既有输出格式不变。

### 0.15.0 → 0.16.0：会改变结果的行为变化

这一版做的是**让别人更容易用起来**：AI skill 装进客户端、一条命令试一遍、
Homebrew 分发、站点给 AI 直读的 llms.txt。

| 变化 | 以前 | 现在 | 你会在哪里撞到 |
|---|---|---|---|
| AI skill 包 | 只有 `skills/shellkit/SKILL.md` 一个文件 | 整目录：`SKILL.md` 是入口，细节在 `references/`（完整 API / 场景手册 / Bash 3.2 写法 / CLI 速查） | 拷过或 vendor 过 `skills/` 的人：内容与目录结构都变了，重新拷一次 |
| `shellkit docs` 的产物 | 四个**文件**（REFERENCE / AGENTS / templates AGENTS / skill） | 多一种产物类型：**整目录**。skill 包整目录生成、整目录校验（`diff -r`），不再逐文件比对 | 自己改过 `skills/shellkit/` 里文件的人：`shellkit docs --check` 会报 out of date |
| Bash 3.2 指南的真相源 | `site/guide/bash32.md`（手写） | `docs/BASH32.md`；站点页与 skill 的 `references/bash32.md` 都是它的投影 | 直接改站点页的人：那次改动会被下次 `site_sync` 覆盖，要改 `docs/BASH32.md` |
| release 资产 | tarball、SHA256SUMS、install.sh、repair.sh | 多两个：`demo.sh`（一条命令试一遍）、`shellkit-skill-<版本>.tar.gz`（skill 包，解开即装） | 按固定资产列表取文件的脚本 |
| 站点 | —— | 多一份 `/llms.txt`（中英各一份），导航栏与每页页脚各挂一个入口 | —— |

只加不改的部分：库函数的行为、退出码、`new` / `vendor` / `upgrade` 的语义都没变；
已有的 `install.sh` 与 `repair.sh` 照旧。

新命令（纯加法，不影响既有路径）：

- `shellkit skill <list|install|uninstall|print>`：把 skill 装进 AI 客户端
  （只往已存在的客户端目录装；目标已是软链就跳过并报错，退出码 3）。
- `shellkit demo [DIR]`：生成一个工程、跑它自己的测试、打印导览。
  目标目录已存在时退出码 3（不搅乱用户已有的东西）。

### 0.12.1 → 0.13.0：会改变结果的行为变化

这一版修一批**静默失效/自毁**：模板变量的值里带了换行时，值会被悄悄丢掉一半，
而 `shellkit new` 照样退出 0、照样报「project created」。

| 变化 | 以前 | 现在 | 你会在哪里撞到 |
|---|---|---|---|
| 模板变量的值里有换行（`--set "DESC=第一行\n第二行"`、`scaffold_vars_set`） | 收下这个值，但变量表是「换行分隔」的 —— 值的后半截变成一行垃圾，渲染时整段被丢掉：生成的工程**少了内容却看不出来**，`new` 退出码 0 | 直接拒绝：退出码 2，并说明是值里有换行；`new` 失败，且**不留下半成品工程** | 用 `--set` 传多行描述、从别处粘来一段说明的人 |
| `shellkit new` 的交互提问（模板变量默认值为空时） | 提问循环挂在 heredoc 上，fd 0 被抢走：**真终端里也永远不提问**，变量静默留空、`{{KEY}}` 渲染成空串，`new` 退出码 0 | 提问真的发生（两阶段：先快照要问的键，再在没有重定向的循环里问）；非交互且没有默认值时，明确 warn 哪个变量保持为空 | 模板里声明 `GREETING=` 这类「生成时问一次」的变量、在终端里跑 `new` 的人 |
| `install-self --prefix <正在运行的那个 prefix>` | 逐棵树先删后拷，删掉的正是运行中的 `lib/`：`cp` 报 No such file or directory，安装当场半残且无回滚 | 整份副本先铺进 `<dest>.new` 再原子换名：自装成功且安装全程可用；失败时旧副本留在原位 | 用装好的副本「重装/修复」同一 prefix 的人 |
| `SHELLKIT_MODULES` 设在环境里时跑 CLI（如 `shellkit doctor`） | CLI 跟着只加载部分模块：`os_has_cmd` 全部 command not found，doctor 把它伪装成「缺 sha256sum/curl/xgettext」的假诊断 | CLI 恒定全量加载，该变量只影响「直接用库」的脚本；doctor 的诊断与不设时一字不差 | 直接用库（设了按需加载）又同一台机器上跑 CLI 的人 |

值里带换行本来就装不下：变量表是一行一个 `KEY=VALUE`，而模板里的 `{{KEY}}`
是一次 sed 替换 —— sed 的替换侧放不下一段真实换行（GNU sed 能、BSD sed 不能，
两边行为还不一样）。所以这里选择**明确报错**，而不是悄悄丢一半。

### 0.12.0 → 0.12.1：不改变结果的改进
这一版只做了一件事：**把热路径上的 fork 砍掉**。
函数的行为、输出、退出码一个都没变 —— 生成出来的工程逐字节相同。

| 改进 | 以前 | 现在 | 你会看到 |
|---|---|---|---|
| `shellkit new` | 渲染每个模板文件都要对每个变量做一次命令替换（6 个变量 × 8 个文件 = 48 次），还要为每个文件建一个 sed 脚本临时文件（`mktemp` + `rm` 各一次） | 替换规则直接交给 `sed -e`，转义改成出参形式（零 fork） | 本机实测 6~8 秒 → **约 1 秒**（绝对值随机器而变） |
| `shellkit upgrade --check` | 每个文件要算两次摘要，每次 `sha256sum \| awk` 两次 fork | 算摘要改成一次命令替换、不接管道 | 本机实测 0.76 秒 → **0.47 秒** |

除此之外没有别的变化：没有新增公开函数，没有新增命令，
`docs/REFERENCE.md` 不变，退出码与输出文本都不变。

### 0.11.0 → 0.12.0：会改变结果的行为变化

> 0.11.1 是维护版（只改了 `trap_install` 的临时文件清理），升级行为与 0.11.0 一样 ——
> 这一节对 0.11.0 与 0.11.1 的用户同样成立。

这一版修的是**升级会把文件写到工程之外**、以及**写盘失败时直接崩掉**这两类问题。
凡是行为变了的地方都列在下表里。

| 变化 | 以前 | 现在 | 你会在哪里撞到 |
|---|---|---|---|
| `shellkit upgrade` 读清单里的工程名 | 不校验，直接拼进 `bin/<name>` 这样的相对路径 | 名字不合法（带 `../`、带路径分隔符）就报错退出（码 5），**一个文件都不写** | 清单是别人给的、或手工改过 `.shellkit-manifest` 的工程 |
| `shellkit upgrade` 写目标文件时 | `cp -f` 跟随目标的符号链接 ⇒ 内容被写到工程之外，退出码还是 0 | 目标是符号链接就**跳过并提示**（`--force` 也不写穿），工程外的文件不动 | 工程里 `README.md` 是指向别处的软链 |
| `shellkit upgrade` 写盘失败时 | bash 崩在 `unbound variable`：退出码 1 但 stderr 看不懂，清单不落盘，临时目录留在 `$TMPDIR` | 报出是哪个文件写失败，退出码 1，**清单照落盘**（与磁盘实际状态一致），临时目录清干净 | 磁盘满、权限不足、目录只读 |
| `shellkit upgrade` / `shellkit vendor` 里的 vendor 目录 | `vendor/` 是指向工程外的软链时，`rm -rf` 与拷贝都发生在工程之外 | 拒绝安装并报错退出 | `vendor/` 被软链到共享目录的工程 |
| `shellkit upgrade` 的临时目录清理 | 每条 return 路径各写一遍 `rm -rf`，漏一条就泄漏一份工程副本 | 统一走一个清理函数，失败路径也清 | — |
| `shellkit upgrade` 写盘的方式 | `cp -f` 逐个覆盖：先 truncate 目标再写 —— 写到一半被打断（断电、磁盘满、进程被杀）留下的是**半截文件**（实测 0 字节到 5MB 不等），既不是旧内容也不是新内容 | 走新增的 `fs_atomic_copy`：同目录落临时文件再 `rename` —— 失败要么什么都没发生、要么整体换新；目标始终是**完整的旧内容或完整的新内容** | 磁盘满、断电、升级中途被 kill |
| `shellkit upgrade` 写盘失败的报错文案 | 更新路径：`failed to update the file`；补文件路径**一声不吭**（只有退出码 1） | 两条路径统一成 `failed to write the file: <文件>` | 有脚本在 grep 旧文案 |
| `shellkit upgrade` 撞上写不下去的目标时 | 边判边写：撞上问题时前面的文件已经改了 —— 工程停在**半升状态**，清单也对不上磁盘 | 先把所有目标判完、校验完（**一个文件都不动**）：目标是目录、父路径建不出来、目录不可写 ⇒ 报错退出（码 5），**一个文件都不改** | 工程里有目录占了模板文件的位置、目录权限不对 |
| `shellkit upgrade` 同步 `vendor/shellkit` 时 | 先 `rm -rf` 再 `cp -R`：中途失败留下**半份库** —— 工程的脚本当场就找不到 `vendor/shellkit/lib/bootstrap.sh` | 先铺到 `vendor/.shellkit-new` 再整体换上去：中途失败**旧副本完好无损**，工程照常能跑 | vendor 同步失败（磁盘满、权限不足、被中断） |
| `shellkit upgrade` 中途失败后的清单 | vendor 同步失败时清单不落盘 —— 已改的文件在下次升级里被判成「用户改过」，**永远冻结** | 清单按磁盘的实际状态落盘（vendor 同步失败也落盘） | 上一次升级失败过、想重试 |
| `run` 的日志脱敏 | 只认三种形态：`KEY=VALUE`、`--password VALUE`、`Authorization:` 头 | 扩到：头名以 key/token/secret/password 结尾（`X-Api-Key:`…）、`Cookie:` / `Set-Cookie:` / `Proxy-Authorization:`、短选项 `-u` / `-uVALUE` / `--user` / `--token` | 日志里有 `-u user:pass`、`-H 'X-Api-Key: …'` 这类写法 |
| `run` 声明「这个参数是敏感的」 | 没有这个接口 —— 启发式没认出来的就漏了 | 新增 `run --secret-arg N`（第 N 个参数必遮，命令名不算）、`run --redact-value V`（按值遮，令牌夹在参数中间也遮得到）、环境变量 `SHELLKIT_SECRET_ARGS="2,3"`（对所有 run 生效） | 令牌藏在参数中间、名字看不出敏感 |
| `run` 的参数解析 | 没有 `--` 分隔符（`run -- foo` 会把 `--` 当成命令去执行） | 支持 `--` 分隔符 | 命令本身以 `-` 开头 |

只加不改的部分（不用改代码就能升）：新增公开函数 `fs_atomic_copy SRC DST [MODE]`
（写文件不写坏：同目录临时文件 + rename，逐字节一致），没有新增命令；
`--check` 与 `--force` 的语义不变。

> 脱敏是**宁枉勿纵**的：认不准的形态会遮掉，代价是日志里少几个字。
> 但过度脱敏也是回归 —— 名字看不出敏感的东西照原样打印
> （`monkey=banana`、`--username=john`、`--count 3` 都不会被遮），
> 否则日志没了细节就没法排障。

> 升级被打断（SIGTERM / 断电）时，**每个文件要么是完整的旧内容、要么是完整的新内容**
>（不会再留半截文件），已经换新的保持新版、没换的保持旧版；
> 清单按磁盘的实际状态落盘，所以下次升级能接着走，不会把这些文件当成「用户改过」。
>
> 但**跨文件没有原子性**：多个文件不是一次换上去的，也不做回滚 ——
> 被打断时工程会停在「一部分新版、一部分旧版」的状态。
> 想要「要么全旧、要么全新」，目前只能先 `--check` 看清楚再跑。
>
> 这套机制的准确名字是**「预检查 + 单文件原子提交 + 可恢复的部分升级」**，
> 不是全局事务 —— 做回滚和故障处置方案时按「部分升级」来设计，
> 别按 ACID 式事务的预期去等「要么全成、要么全不发生」。

### 0.11.0 → 0.11.1：不改变结果的修复
这一版只有一个修复，但它摊在每一个脚本的启动开销上。

| 变化 | 以前 | 现在 | 你会在哪里撞到 |
|---|---|---|---|
| `trap_install` 读 trap 定义 | EXIT / INT / TERM / HUP 四个信号各读两遍，每读一遍新建 + 删除一个临时文件 ⇒ **8 次 `rm`** | 一次读完所有信号，临时文件只建一个、只删一次 ⇒ **1 次 `rm`** | `rm` 走回收站包装器、审计钩子或网络文件系统的机器上，光「装一次 trap」就要白等几秒到几十秒 |

行为不变：调用方自己装的 EXIT / INT / TERM / HUP handler 仍然被链式保留，子 shell 里的
「trap 残影」仍然不会被当成调用方的 handler，退出码与信号语义一字未动。

回归用例 `tests/test_trap.sh` 用替身数 `rm` 的调用次数：旧实现 8 次必红，新实现 1 次必绿。

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
