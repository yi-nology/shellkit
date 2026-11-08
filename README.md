# shellkit

写运维 shell 的起点。一套**约束清晰的 Bash 库 + 脚手架生成器**，从
[jumpserver/installer](https://github.com/jumpserver/installer) 的安装脚本体系里抽出来，
目标不是"功能多"，而是**让写出来的脚本又准又一致**。

- 基线 **Bash 3.2+**：Linux 全系 + macOS 原生 `/bin/bash` 都能跑。
- 日志只走 stderr，stdout 只给数据 —— 所以 `v=$(conf_get KEY)` 永远是干净的。
- `shellkit new` 生成工程后 `make test` **当场通过**，不是"跑起来看看"。

## 安装

`@bash
git clone https://github.com/yi-nology/shellkit.git
cd shellkit
./shellkit doctor              # 先看环境缺什么
./shellkit install-self        # 装到 /usr/local（需要权限）
./shellkit install-self --prefix ~/.local   # 或者装到自己的目录
`@

不想全局安装也没问题：直接 `git clone` 到任意位置用，或者让工程自带一份库
（`shellkit new` 默认就这么做，见下）。

## 30 秒上手

`@bash
shellkit new ./deploy-tool --cmd start --cmd stop --cmd status
cd deploy-tool
make test
./bin/deploy-tool --help
`@

生成的结构：

`@
deploy-tool/
├─ bin/deploy-tool        入口：定位自身 → 加载库与应用 → cli_run
├─ lib/app.sh             装配层：配置路径 + 加载 commands/*.sh
├─ commands/start.sh      每个子命令一个文件，末尾 cli_cmd 注册自己
├─ config.example
├─ tests/{run.sh,test_helper.sh,test_smoke.sh}
├─ vendor/shellkit/       随工程走的库副本，不依赖本机装过 shellkit
├─ Makefile               test / lint / fmt
└─ .shellcheckrc
`@

**加一个子命令** = 复制 `commands/start.sh` 改名 + 改函数名和 `cli_cmd` 那一行，分发器不用动。

## 接进既有项目

不用先重写脚本。已经能跑的项目，一条命令把库镜像进去：

```bash
cd /path/to/your-project
shellkit vendor .            # 同步 lib/ + locale/ + VERSION 到 vendor/shellkit
shellkit vendor . --check    # 只比对（逐字节 diff），漂移返回 5，适合放进 CI
```

脚本顶部两行接入：

```bash
. "$(cd "$(dirname "$0")/.." && pwd)/vendor/shellkit/lib/bootstrap.sh"
```

然后按 [docs/MIGRATING.md](docs/MIGRATING.md) 的 5 步渐进迁移
（先杀 stdout 污染 → 配置读写 → 交互 → CLI 框架 → 测试），每一小步都能单独上线。

只想先要测试能力？把 `tests/test_helper.sh` + `tests/run.sh` 两个文件拷过去即可，零依赖。

## 直接用库

`@bash
. "$SHELLKIT_HOME/lib/bootstrap.sh"     # 唯一入口，一次性加载全部模块
`@

`@bash
#!/usr/bin/env bash
set -euo pipefail

. ./vendor/shellkit/lib/bootstrap.sh

require_bash 3 2                  || exit $?
require_cmd curl sha256sum        || exit $?

conf_init ./config                || exit $?
port=$(conf_get_any PORT 8080)    # 环境变量 PORT > config 里的 PORT > 8080

log_info "starting on port $port"     # 走 stderr
if ask_yn ok "确认?" y; then :; fi
`@

## 五条硬约定

这五条是"准"的来源，不是风格偏好：

1. **stdout 只给数据，日志一律 stderr。** 否则 `$(...)` 会混进 `[INFO]`，调用方拿到脏值。
2. **出参用 `printf -v "$var"`，函数不直接改调用方变量。** Bash 3.2 没有 nameref，
   这是唯一在 3.2 上可靠的"返回值"通道。
3. **取值优先级：显式参数 > 环境变量 > 配置文件 > 默认值。** 由 `conf_get_any` 统一实现。
4. **写文件必原子**：临时文件 + `mv -f`，配置类再叠 `chmod 600`
   （`fs_atomic_write`、`conf_set`）。
5. **库不改变调用方的 shell 选项，也不改 cwd。** `set -euo pipefail` 只由你的入口脚本开。

## 模块

| 模块 | 关键函数 | 说明 |
|---|---|---|
| `error` | `die` `fail` `require_cmd` `require_root` `require_file` `require_bash` | 失败即返回既定退出码 |
| `i18n` | `_t` `_tn` | msgid 英文，缺 gettext 时原样输出 |
| `log` | `log_info` `log_ok` `log_warn` `log_error` `log_debug` `log_section` | 全部 stderr，彩色可关 |
| `str` | `str_trim` `str_lower` `str_upper` `str_contains` `str_starts_with` `str_ends_with` `str_repeat` | 3.2 无大小写变换，用 `tr` 兜底 |
| `validate` | `validate_*`（not_empty / single_line / key / port / ip / version / abs_path / url / enum） | 失败原因写 `SK_VALIDATE_ERR` |
| `fs` | `fs_atomic_write` `fs_backup` `fs_ensure_dir` `fs_tmpdir` `fs_tmp_init` | 原子写；备份按名升序保留最新 N 份 |
| `os` | `os_name` `os_arch` `os_is_root` `os_has_cmd` `os_pkg_*` `os_sed_i` `os_md5` `os_sha256` | Darwin/Linux 差异只在这里 |
| `net` | `net_download` `net_verify` `net_wait_port` `net_wait_http` | 下载带 sha256 缓存校验与镜像回退 |
| `config` | `conf_init` `conf_get` `conf_get_any` `conf_has` `conf_set` `conf_unset` `conf_disable` `conf_keys` | `KEY=VALUE`；值未变不写盘 |
| `prompt` | `ask` `ask_yn` `ask_choice` `confirm` | 超时回退默认值；EOF 与超时区分处理 |
| `cli` | `cli_group` `cli_cmd` `cli_run` `cli_opt` `cli_opts` | 注册即生效，`declare -F` 动态分发 |

### 退出码

| 码 | 含义 |
|---|---|
| 0 | `SK_OK` |
| 1 | `SK_ERR` 一般错误 |
| 2 | `SK_USAGE` 用法错 |
| 3 | `SK_PRECOND` 前置条件不满足（缺命令、非 root、非交互却没默认值…） |
| 4 | `SK_NET` 网络失败 |
| 5 | `SK_VERIFY` 校验失败（sha256 不匹配等） |

### 环境变量

`SHELLKIT_DEBUG=1`、`SHELLKIT_COLOR=auto|always|never`、`SHELLKIT_NONINTERACTIVE=1`
（等价 `-y`）、`SHELLKIT_TMP_KEEP=1`、`SHELLKIT_NO_GETTEXT=1`、
`SHELLKIT_MIRROR_FROM`/`SHELLKIT_MIRROR_TO`（下载源镜像前缀替换）。

## CLI 框架

`@bash
cli_group "运维"
cli_cmd deploy "部署服务" "deploy [--force] <target>"
cli_cmd status "查看状态"

cmd_deploy() {
  local force=""
  cli_opt_init
  cli_opt force --force -f        # 布尔开关
  cli_opts "$@" || return $?      # 剩余位置参数在 SK_OPTS_LEFT
  local target="${SK_OPTS_LEFT[0]:-}"
  [ -n "$target" ] || { log_error "缺 target"; return "$SK_USAGE"; }
  ...
}

cli_run "$@"
`@

错误只报一次：`log_error` 记录到 `SK_ERRMSG`，`cli_run` 兜底补印，不会重复刷屏。
未知命令按前缀给候选（`Did you mean: deploy`）。命令名可以带短横，
`install-self` 自动派发到 `cmd_install_self`。

## 国际化

msgid 一律英文，译文放 `locale/<lang>/LC_MESSAGES/shellkit.po`：

`@bash
bash po/messages.sh     # xgettext → msgmerge → msgfmt，产出 .mo
`@

已带 `zh_CN`、`zh_Hant`（各 97 条全译）；`locale/en` 的 msgstr 留空，回退英文。
**没装 gettext 不会失败**，只是输出英文——这一点和上游硬装 gettext 的做法相反。

## 测试与门禁

自研极简断言（`assert_eq` / `assert_contains` / `assert_exit_code` / `assert_file_mode` …），
`tests/run.sh` 逐个 `bash` 执行，不依赖 bats：

`@bash
make test       # 12 个测试文件
make syntax     # bash -n 全部脚本
make lint       # shellcheck -S warning -x（含"渲染模板后再检查"）
make fmt        # shfmt -d -i 2 -ci（只检查不改）
make check      # 以上全跑
`@

CI：`macos-latest`（真 Bash 3.2）+ `ubuntu-latest` 双矩阵。

## Bash 3.2 兼容

为了在 macOS 原生 bash 上跑，全库**不使用**：

关联数组（`declare -A`）、`local -n`/nameref、`${var^^}`/`${var,,}`、`mapfile`/`readarray`、
`[[ -v var ]]`、空数组展开（3.2 在 `set -u` 下会报错）。

替代手法：子命令用 `declare -F` 动态分发；出参用 `printf -v`；大小写用 `tr`；
数组追加用 `arr[${#arr[@]}]=x`。

## 目录

`@
shellkit                  生成器入口（也 source 自己的库）
lib/bootstrap.sh          唯一入口，按拓扑序加载
lib/core/*.sh             11 个模块
templates/                shellkit new 的模板
tests/                    断言库 + 逐文件执行器 + 12 个测试
po/messages.sh            msgid 抽取与 .mo 编译
locale/{en,zh_CN,zh_Hant}
docs/superpowers/specs/   设计文档（决策、契约、与上游差异账）
`@

## 与上游的关系

思路与骨架来自 [jumpserver/installer](https://github.com/jumpserver/installer)（GPLv3）：
四层结构、gettext 全包裹、`read -t` 超时回退、配置原子写 + 600、下载 sha256 缓存校验、
五种包管理器、逐文件测试执行器。

修正的部分：日志从 stdout 改 stderr、`has_config` 改返回码、`download()` 从业务脚本
提到公共库、prompt 区分 EOF 与真超时、库不再替你设 shell 选项和 `cd`。

## 许可

GPL-3.0-or-later，见 [LICENSE](LICENSE)。派生自 GPLv3 的 jumpserver/installer，
保留其署名与许可。
