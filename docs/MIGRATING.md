# 把 shellkit 接进既有项目

不要求你先重写脚本。三种接入姿势从"零承诺"到"全套"，按你能接受的风险选。

## 三分钟决策

| 姿势 | 改动量 | 适合 | 代价 |
|---|---|---|---|
| **A. 只借测试** | 拷 2 个文件 | 已有脚本能跑但没测试 | 拿不到 log/config/prompt |
| **B. vendor 整个库**（推荐） | 一条命令 + 每个脚本 2 行 | 绝大多数项目 | 库里镜像进仓库（约 120KB） |
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
   ├─ lib/           11 个模块（bootstrap.sh + core/*.sh）
   ├─ locale/        gettext 译文（en / zh_CN / zh_Hant）
   └─ VERSION        锁定的版本号
```

脚本里两行接入：

```bash
#!/usr/bin/env bash
set -euo pipefail

. "$(cd "$(dirname "$0")/.." && pwd)/vendor/shellkit/lib/bootstrap.sh"
```

就这些。`bootstrap.sh` 会按拓扑序把 11 个模块加载好，设置 `SK_*` 常量与退出码，
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

**收益**：`--help` 自动生成、未知命令按前缀给候选、`log_error` 只报一次
（`cli_run` 兜底补印），新增命令零改分发器——命令名甚至可以带短横，
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
