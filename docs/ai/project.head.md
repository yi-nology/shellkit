<!-- 生成物：由 tools/ai_doc.sh 拼装，请勿手改。改 docs/ai/project.head.md 再跑 shellkit docs。 -->

# 这个工程：{{NAME}}

这是一个 shellkit 工程。库在 `vendor/shellkit/`，随工程走，不改全局环境。

## 结构

    bin/{{NAME}}          入口：定位自身 -> 加载库与应用 -> cli_run
    lib/app.sh            装配层：配置路径 + 加载 commands/*.sh
    commands/*.sh         每个子命令一个文件，末尾 cli_cmd 注册自己
    vendor/shellkit/      库副本（版本见 vendor/shellkit/VERSION）
    tests/                断言库 + 逐文件执行器
    config.example        配置模板

## 加一个子命令：改两处，分发器不用动

1. 新建 `commands/<cmd>.sh`，复制 `commands/{{CMD}}.sh` 改名，改函数名 `cmd_<cmd>` 与
   末尾的 `cli_cmd <cmd> "描述" "<cmd> [选项]"`。
2. 新命令属于另一个分组时，在 `cli_cmd` 前加一行 `cli_group "分组名"`。
3. `make test`。

命令名带短横会自动派发到下划线函数名（`install-self` -> `cmd_install_self`）。

## 改行为之前先看这里

- 配置读写一律 `conf_get_any` / `conf_set`，不要自己 `grep` 配置文件。
- 日志一律 `log_*`（走 stderr），不要 `echo` 到 stdout。
- 想改 `vendor/shellkit/` 里的东西？它是镜像，**会被下一次 vendor 覆盖**。
  需要新能力就升级库版本，而不是就地改。

## 验证

    make test          # 必须绿
    make lint          # shellcheck（装了才跑）
    ./bin/{{NAME}} --help
