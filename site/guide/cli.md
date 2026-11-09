# CLI 框架

`lib/core/cli.sh` 只做五件事：注册、分发、帮助生成、选项解析、退出码。

关键设计：**新增命令不需要改分发器**。`cli_run` 用 `declare -F` 动态找 `cmd_<name>`，
命令名里的短横会转成下划线（`install-self` → `cmd_install_self`）。

## 注册

```bash
cli_group "运维"
cli_cmd deploy "部署服务" "deploy [--force] <target>"
cli_cmd status "查看状态"
```

`cli_group` 影响帮助里的分组显示；不调用就归到无分组。`cli_cmd` 的第三个参数是用法行，
省略时帮助里只显示命令名。

注册发生在 `source` 的时候，所以 `cli_cmd` 要写在命令文件**末尾** —— 写早了函数还没定义，
直到 `cli_run` 分发才发现（报 `command has no handler`）。

## 分发

```bash
cli_run "$@"
```

入口脚本只需要这一行。它会先吃掉全局选项，再取第一个位置参数当命令名：

| 全局选项 | 作用 |
| --- | --- |
| `-h`, `--help` | 打印总用法（命令按分组，选项固定五条） |
| `-V`, `--version` | 打印 `SK_VERSION`（没设就 `dev`） |
| `--verbose` | `SHELLKIT_DEBUG=1`，日志出 debug |
| `--no-color` | 关掉颜色 |
| `-y`, `--yes` | `SHELLKIT_NONINTERACTIVE=1`，交互取默认值 |

命令名不存在时，它会按前缀给一个候选并返回 `SK_USAGE`：

```text
[ERROR] no such command: deply
[Did you mean]: deploy
```

## 子命令的选项

三次调用：清空注册表 → 注册规则 → 解析。

```bash
cmd_deploy() {
  local __target="" __force="" __retries="3"

  cli_opt_init
  cli_opt __force --force -f
  cli_opt __target --target -t 1
  cli_opt __retries --retries -r 1
  cli_opts "$@" || return $?

  log_info "target=$__target force=$__force retries=$__retries"
  return "$SK_OK"
}
```

约定：

- `cli_opt VAR LONG [SHORT] [TAKES_ARG]`。第四个参数是 `1` 表示这个选项要吃一个值。
- 注册前先把变量赋好默认值 —— `cli_opt_init` 只清注册表，不碰你的变量。
- 解析完，剩下的位置参数在 **`SK_OPTS_LEFT`**（数组，从下标 0 起）。
- `--opt=value` 和 `--opt value` 都支持；布尔选项带 `=` 会被拒绝（把垃圾塞进变量比报错难查）。

## 错误只报一次

`log_error` 打印一次并把最后一条错误记进 `SK_ERRMSG`，`cli_run` 不会「补印」。
所以命令函数里该 `log_error` 就 `log_error`，不要既 `log_error` 又 `die`。

## 一个完整的最小 CLI

```bash
#!/usr/bin/env bash
set -euo pipefail

. ./vendor/shellkit/lib/bootstrap.sh

cli_group "main"
cli_cmd hello "say hello" "hello [--name NAME]"

cmd_hello() {
  local __name="world"
  cli_opt_init
  cli_opt __name --name -n 1
  cli_opts "$@" || return $?
  printf '%s\n' "hello $__name"
  return "$SK_OK"
}

SK_PROG=hello
cli_run "$@"
```

注意 `printf` 写的是 stdout（这是数据），日志走 stderr —— 所以 `./hello --name x | jq` 这类
管道不会被日志污染。

## 命令补全

子命令名和选项名都是自己定的，运维记不住是常态。补全脚本从注册表生成，
不用维护第二份清单：

```bash
shellkit completion bash > /etc/bash_completion.d/shellkit
shellkit completion zsh  > "${fpath[1]}/_shellkit"
```

自己写的 CLI 也能用同一个函数（程序名取 `SK_PROG`）：

```bash
cli_completion_script bash > mytool-completion.bash
```

`shellkit new` 生成的工程自带这条：`make completion` 输出补全脚本，
优先用工程自带的 `vendor/shellkit/shellkit`，这样没装 shellkit 的机器也能生成。
