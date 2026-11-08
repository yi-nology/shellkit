# shellkit 设计文档

- 日期：2026-11-08
- 状态：待实现
- 来源：从 [jumpserver/installer](https://github.com/jumpserver/installer) 的脚本体系抽取可复用骨架
- 基线：Bash 3.2+（Linux 全系 + macOS 原生 bash）

## 1. 目标与非目标

### 目标

让不熟悉 shell 细节的人也能一次写对运维脚本。做到这一点的不是"函数多"，而是**把上游那些从没写下来的硬约定变成库的默认行为**：

1. 交互问答不用自己拼提示词、默认值、超时、非交互降级。
2. 配置文件读写是原子的、权限对的、值可以直接嵌进 `$(...)`。
3. 命令行工具不用重写分发和 help。
4. 日志永远不污染数据输出。
5. 跨平台差异（Darwin/Linux、Bash 3/4、arm64/x86_64、五种包管理器）只写一次。

### 非目标（防过度设计）

- 不封装 Docker / Compose / systemd。
- 不做配置 schema 校验、多环境配置管理。
- 不做插件系统、命令别名系统、依赖注入。
- 不替代 bats-core；测试只用自研极小断言。
- 不搬运 upstream 的 jdmc / openbao / kotl / virtualapp 等专有业务模块。

## 2. 关键决策与依据

| 决策 | 选择 | 依据 |
|---|---|---|
| 交付形态 | 库 + 脚手架 + CLI 框架 | 用户明确选 C；防过度设计靠护栏（见 §6） |
| Bash 基线 | 3.2+ | Linux 全系 + macOS 原生。代价：无关联数组、无 `local -n`、无 `${var^^}`、无 `mapfile` |
| 子命令分发 | `declare -F "cmd_${name}"` | 3.2 可用；新增命令不必改分发器 |
| i18n | 完整 gettext，msgid 写英文 | 与 upstream 一致；缺失 gettext 时降级为英文原样输出 |
| 测试 | 自研极小断言 | 与 upstream 一致，零依赖 |
| 日志输出 | 一律 stderr | 修正 upstream 的 `echo_red` 污染 `$(...)` 问题 |
| 库的 shell 选项 | 库不设 `set -euo pipefail` | source 一个库不该改变调用方行为；由模板入口统一开启 |

## 3. 架构

### 3.1 目录结构

```
shellkit/
├─ shellkit                     # 生成器入口：new / doctor / install-self / list
│                               # 自身也 source lib/bootstrap.sh，吃自己造的库
├─ lib/
│  ├─ bootstrap.sh              # 唯一入口
│  └─ core/
│     ├─ error.sh  i18n.sh  log.sh  str.sh  validate.sh
│     ├─ fs.sh  os.sh  net.sh  config.sh  prompt.sh  cli.sh
├─ templates/                   # shellkit new 的模板
│  ├─ bin/__NAME__
│  ├─ lib/app.sh
│  ├─ commands/__CMD__.sh
│  ├─ config.example
│  ├─ tests/test_smoke.sh
│  ├─ .shellcheckrc
│  └─ Makefile
├─ tests/
│  ├─ test_helper.sh  run.sh
│  └─ test_{error,log,str,validate,fs,os,config,prompt,net,cli}.sh
├─ po/messages.sh               # xgettext → msginit → msgmerge → msgfmt
├─ locale/{en,zh_CN,zh_Hant}/LC_MESSAGES/shellkit.{po,mo}
├─ docs/
└─ Makefile                     # test / lint / fmt / messages / help
```

### 3.2 加载顺序（拓扑序，非字母序）

`error → i18n → log → str → validate → fs → os → net → config → prompt → cli`

依赖关系：`log` 依赖 `i18n._t`；`prompt` 依赖 `log` + `validate`；`cli` 依赖 `i18n` + `log`。

### 3.3 bootstrap 职责

```bash
SHELLKIT_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SHELLKIT_HOME

: "${SHELLKIT_DEBUG:=0}"
: "${SHELLKIT_COLOR:=auto}"
: "${SHELLKIT_NONINTERACTIVE:=0}"

SK_OK=0 SK_ERR=1 SK_USAGE=2 SK_PRECOND=3 SK_NET=4 SK_VERIFY=5
```

- 不改 cwd（upstream 的 `jmsctl.sh` 一进来就 `cd`，作为库会静默吃掉调用方的相对路径）。
- 不设置 shell 选项。
- 导出 `TEXTDOMAIN=shellkit`、`TEXTDOMAINDIR="${SHELLKIT_HOME}/locale"`，并一次性解析 `SK_GETTEXT`。
- 加载完成后 unset 内部临时变量。

## 4. 核心契约（全库强制）

1. **stdout 只给数据，日志一律 stderr。** 所有 `log_*` 写 fd 2。测试 `test_log` 断言"只调用日志的函数 stdout 为空"。
2. **出参用 `printf -v "$outvar" '%s' "$val"`。** 函数不得直接给调用方变量赋值。调用方显式传变量名（如 `str_trim VAR`），这仍是显式契约。
3. **取值优先级固定**：显式参数 > 环境变量 > 配置文件 > 默认值，只在一处实现（`conf_get_any`）。
4. **写文件必原子**：同目录 `mktemp` → 写入 → `chmod` → `mv`；内容未变直接 return。
5. **库不改变调用方的 shell 选项。** 测试断言 source 前后 `[[ -o pipefail ]]` 一致。

## 5. 模块 API

### error

```bash
die CODE MSG...          # log_error 后 exit CODE
fail CODE MSG...         # log_error 后 return CODE
require_cmd CMD...       # 缺任一 → SK_PRECOND
require_root             # 非 root → SK_PRECOND
require_file PATH...
require_bash MAJOR MINOR
```

错误码：`0` 成功 / `1` 通用失败 / `2` 用法 / `3` 前置条件 / `4` 网络 / `5` 校验。

### i18n

```bash
_t 'Backup failed'                # gettext 可用则翻译，否则原样返回
log_error "$(_t 'Backup failed'): $file"   # 变量必须放在 _t 之外
```

msgid 一律英文；`locale/en` 的 msgstr 留空即回退英文。

### log

```bash
log_info  MSG     # [INFO]  MSG
log_ok    MSG     # [ OK ]  MSG
log_warn  MSG     # [WARN]  MSG
log_error MSG     # [ERROR] MSG ；同时写入 SK_ERRMSG
log_debug MSG     # 仅 SHELLKIT_DEBUG=1
log_section MSG   # 分节标题（对应 upstream 的 echo_yellow "1. xxx"）
```

`SHELLKIT_COLOR=auto|always|never`；`auto` 时判 `[[ -t 2 ]]`。

### str（3.2 兼容）

```bash
str_trim VAR                # 就地 trim 首尾空白
str_lower VAR   str_upper VAR
str_contains HAYSTACK NEEDLE   # 返回码，不输出
str_repeat VAR N STR
```

### validate

```bash
validate_not_empty V
validate_single_line V
validate_key V            # ^[a-zA-Z_][a-zA-Z0-9_]*$
validate_port V
validate_ip V
validate_version V        # v?N.N.N
validate_abs_path V
validate_url V            # ^https?://
validate_enum V "a|b|c"
```

统一行为：失败返回 1，原因写入 `SK_VALIDATE_ERR`。

### fs

```bash
fs_atomic_write FILE CONTENT [MODE=600]
fs_backup FILE [KEEP=3]        # 产出 FILE.bak.YYYYmmddHHMMSS；按文件名升序保留最新 KEEP 份
fs_tmpdir                      # 建临时目录并注册 EXIT trap
fs_ensure_dir DIR [MODE=700]
```

### os

```bash
os_name            # linux | darwin | other
os_arch            # x86_64 | aarch64 | other（arm64→aarch64）
os_is_root
os_has_cmd CMD...
os_pkg_install PKG...   # dnf → yum → apt-get → zypper → apk，自动探测一次
os_pkg_update
os_sed_i ARGS...        # Darwin 补 ```''``` 备份后缀
os_md5 FILE   os_sha256 FILE
```

### net

```bash
net_sha256 FILE
net_verify FILE SHA256
net_download URL DEST [SHA256]   # 缓存命中校验；失败删残件；curl/wget 自动择一
net_wait_port HOST PORT [TIMEOUT=30]
net_wait_http URL [TIMEOUT=30]
```

`net_download` 支持镜像回退：若设置 `SHELLKIT_MIRROR_FROM` / `SHELLKIT_MIRROR_TO`，首次失败后替换 URL 前缀重试一次。

### config

```bash
conf_init FILE                # 可重复调用，后者覆盖前者；幂等
conf_get KEY [DEFAULT]        # 只输出值；文件不存在也不报错
conf_get_any KEY [DEFAULT]    # env > file > default
conf_has KEY                  # 返回码 0/1
conf_set KEY VALUE            # 校验 + 无变化跳过 + 原子写 + 600
conf_unset KEY
conf_disable KEY              # 改成注释行
conf_keys                     # 逐行输出
```

未调用 `conf_init` 时 `conf_get` 直接返回 DEFAULT 且不报错（库不该因为使用者没初始化就炸）。
`conf_set` 的失败情形：key 非法、值含换行、写盘失败——分别返回 SK_USAGE / SK_USAGE / SK_ERR。

### prompt

```bash
ask VAR PROMPT [DEFAULT] [TIMEOUT]
ask_yn VAR PROMPT [DEFAULT=y] [TIMEOUT]     # 渲染 [Y/n] / [y/N]
ask_choice VAR PROMPT "a|b|c" [DEFAULT] [TIMEOUT]
confirm PROMPT [DEFAULT=n]                   # 只返回码
```

行为规定：

- 渲染格式与 upstream 保持一致：`MSG [default: x] `、`MSG [Y/n]`、`MSG [a|b|c] (default: b)`。
- 非交互（`SHELLKIT_NONINTERACTIVE=1` 或 stdin 非 tty）：取 DEFAULT；**若无 DEFAULT 则 SK_PRECOND 失败**，绝不静默返回空值。
- 超时：`read -t`，Bash 3 返回 1 与 Bash 4 返回 142 的差异封装在内部 `_read_timeout`；**只有真正超时才回退默认**，EOF 视为错误。
- `ask_yn` 非法输入重问，最多 3 次后 SK_USAGE。
- 答案一律 trim 后写入。
- TIMEOUT 为空或 0 表示不超时。
- `ask_choice` 的 DEFAULT 必须属于选项集，否则 SK_USAGE。

### cli

```bash
cli_cmd start "启动服务" cmd_start "start [--wait SEC]"
cli_run "$@"
```

- 分发：`declare -F "cmd_${name}"`；未知命令按前缀模糊匹配给候选，并打印对齐的 help。
- 全局选项：`-h|--help`、`-V|--version`、`--verbose`（开 SHELLKIT_DEBUG）、`--no-color`、`-y|--yes`（非交互取默认）。
- 子命令选项：`cli_opt VAR -w|--wait VALUE`，支持 `--k=v`、`--k v`、`--` 终止；未知选项 → SK_USAGE + 该命令 usage。
- 处理器返回码直接作为进程退出码；若 `SK_ERRMSG` 非空则输出一次。
- `SK_ERRMSG` 由 `log_error` 设置、由 `cli_run` 输出后清空，避免重复打印。
- `-y|--yes` 等价于 `SHELLKIT_NONINTERACTIVE=1`。
- 护栏：只做注册/分发/help/选项解析/退出码五件事。

## 6. 脚手架

```bash
shellkit new ./deploy-tool --cmd start --cmd stop --cmd status
```

验收标准：**生成后 `cd deploy-tool && make test` 必须当场通过**。

生成内容：入口 `bin/<name>`（15 行）、`lib/app.sh`、`commands/<cmd>.sh`（各含一行注册）、`config.example`、`tests/test_smoke.sh`、`Makefile`（test/lint/fmt/messages/help）、`.shellcheckrc`。

配套：`shellkit doctor`（逐项检查 bash 版本、gettext、sha256sum/shasum、curl/wget）、`shellkit install-self`（装到 /usr/local/bin，对应 upstream 的 prepare_jmsctl）、`shellkit list`。

## 7. 测试与门禁

断言库：`assert_eq`、`assert_contains`、`assert_true`、`assert_false`、`assert_exit_code`、`assert_file_mode`、`assert_stdout_empty`。

| 门 | 命令 | 说明 |
|---|---|---|
| 语法 | `bash -n` 全部 `*.sh` | 同 upstream |
| 静态 | `shellcheck -S warning -x` | upstream 没有 |
| 格式 | `shfmt -d -i 2 -ci` | 只检查不改 |
| 回归 | `bash tests/run.sh` | 同 upstream |
| 约定 | 日志不污染 stdout；source 不改 shell 选项 | 新增 |

CI：`ubuntu-latest` + `macos-latest` 双矩阵（3.2 基线只有 macOS 能真正验证）。

## 8. 与 upstream 的差异账

| 处置 | 内容 |
|---|---|
| 原样保留 | gettext 全包裹；`read -t` 超时回退默认；config 原子写 + 600；下载 sha256 缓存校验；五种包管理器；`tests/run.sh` 逐个跑 |
| 修正 | 日志改 stderr；`has_config` 改返回码；`download()` 从业务脚本移入公共库；`prompt` 区分 EOF 与真超时；库不设 shell 选项；出参统一 `printf -v` |
| 不搬 | Docker/Compose 业务；jdmc/openbao/kotl 等专有模块；`logo.txt`；`config_init` 整套；`msginit` 的交互式步骤 |

## 9. 里程碑

| 阶段 | 交付 | 完成判据 |
|---|---|---|
| M1 | bootstrap + error/i18n/log/str/validate/fs/os + 对应测试 | `bash tests/run.sh` 绿 |
| M2 | config + prompt + 测试（含管道喂 stdin 模拟非 tty、模拟超时） | 同上 |
| M3 | net + cli + 测试 | 同上 |
| M4 | 脚手架 + doctor/install-self + 模板冒烟 | `shellkit new /tmp/x && cd /tmp/x && make test` 绿 |
| M5 | po 流水线 + 中文文案回填 + 文档 + CI | 四道门全绿，双平台 |

## 10. 风险与对策

| 风险 | 对策 |
|---|---|
| Bash 3.2 缺特性 | 用 `tr` / `printf -v` 替代；CI 双平台兜底 |
| 目标机没有 gettext | 降级为英文原样输出，不失败 |
| CLI 框架过度设计 | §5 的护栏写进代码评审清单 |
| 脚手架生成的代码腐化 | 模板里的冒烟测试同时是"约定示例"，改模板必跑 |

## 11. 验收标准（整体）

1. macOS（Bash 3.2）与 Ubuntu（Bash 5.x）上 `bash tests/run.sh` 全绿。
2. `shellcheck -S warning -x` 零告警。
3. `shellkit new` 生成的工程 `make test` 当场通过。
4. 只用日志的函数 stdout 为空；source bootstrap 前后 shell 选项不变。
5. 新增一个子命令只需新建一个文件 + 一行 `cli_cmd`，不改分发器与 help。
