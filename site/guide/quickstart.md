# 三十秒上手

生成一个工程，看它长什么样，加一个自己的子命令。

## 跑一遍

```bash
git clone https://github.com/yi-nology/shellkit.git
cd shellkit
./shellkit doctor
./shellkit new /tmp/shellkit-demo --cmd start --cmd status
cd /tmp/shellkit-demo && make test
```

`doctor` 做三类检查：**环境**（缺什么工具）、**库完整性**（模块文件齐不齐、有没有坏）、
**vendor 漂移**（工程里那份副本与自带的是否逐字节一致）。

**缺工具不影响核心功能** —— 库本身零运行时依赖，缺的只是对应的检查项会跳过。
但「库坏了」或「vendor 漂移」会被抓出来并返回 5（校验失败）：前者点名缺哪个模块，
后者点名漂了哪个文件。`--dir DIR` 可以指定要检查的工程目录。

`new` 生成的工程**当场 `make test` 通过**，不是空骨架。

## 生成了什么

```text
shellkit-demo/
├─ bin/shellkit-demo      入口：定位自身 → 加载库与应用 → cli_run
├─ lib/app.sh             装配层：配置路径 + 加载 commands/*.sh
├─ commands/start.sh      每个子命令一个文件，末尾一行 cli_cmd 注册自己
├─ commands/status.sh
├─ config.example
├─ tests/run.sh           逐文件执行器
├─ tests/test_helper.sh   断言库
├─ tests/test_smoke.sh    冒烟测试
├─ vendor/shellkit/       随工程走的库副本，不依赖本机装过 shellkit
├─ Makefile               test / lint / fmt
├─ AGENTS.md              给 AI 的约束：禁用语法表 + 任务落点表 + 自检清单
└─ .shellcheckrc
```

`vendor/` 是刻意这么设计的：工程自带库副本，CI 上不需要先装 shellkit，也不会因为
「上个礼拜升级了系统里的 shellkit」而让构建结果变了。

## 加一个子命令

复制 `commands/start.sh` 改名，改函数名和末尾那行 `cli_cmd`：

```bash
cp commands/start.sh commands/deploy.sh
```

新文件里是这样（截掉具体逻辑）：

```bash
cmd_deploy() {
  local __target __force=""

  cli_opt_init
  cli_opt __force --force -f
  cli_opt __target --target -t 1
  cli_opts "$@" || return $?

  if [ -z "$__target" ]; then
    __target=$(conf_get TARGET "localhost")
  fi
  log_info "deploying $__target"
  return "$SK_OK"
}

cli_cmd deploy "deploy the service" "deploy [--force] [--target HOST]"
```

**分发器不用动**：`cli_run` 用 `declare -F` 动态找 `cmd_<name>`，命令名带短横也对得上
（`install-self` → `cmd_install_self`）。

`cli_cmd` 必须写在文件末尾：注册发生在 `source` 的时候，写早了函数还没定义。

## 接进已有项目

不用先重写。一条命令把库镜像进去：

```bash
cd /path/to/your-project
shellkit vendor .
shellkit vendor . --check
```

`vendor` 同步 `lib/`、`locale/`、`templates/`、`tests/`、`VERSION` **以及 CLI 本身**
到 `vendor/shellkit`；`--check` 只逐字节比对，漂移返回 5，适合放进 CI 拦
「有人在本地改过 vendor」这种情况。

副本自带 CLI 与模板，所以工程被拷到一台**没装 shellkit 的机器**上时，
仍然可以离线升级：

```bash
./vendor/shellkit/shellkit upgrade .
```

脚本顶部一行接入：

```bash
. "$(cd "$(dirname "$0")/.." && pwd)/vendor/shellkit/lib/bootstrap.sh"
```

只想先要测试能力？把 `tests/run.sh` 和 `tests/test_helper.sh` 两个文件拷过去就行，零依赖。

接着按 [五步迁移](./migrating.md) 做，每一步都能单独上线。
