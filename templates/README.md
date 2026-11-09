# {{NAME}}

{{DESCRIPTION}}

用 [shellkit](https://github.com/yi-nology/shellkit) 生成的 shell 工具骨架。

## 结构

    bin/{{NAME}}       入口，只负责装配
    lib/app.sh         装配层：配置路径 + 加载命令
    commands/*.sh      每个子命令一个文件，末尾用 cli_cmd 注册
    vendor/shellkit/   随工程走的库副本（版本 {{SHELLKIT_VERSION}}）
    tests/             断言库 + 逐文件执行器

## 常用

    make test      # 全部测试
    make lint      # shellcheck
    make fmt       # shfmt 只检查不改
    ./bin/{{NAME}} --help

## 加一个子命令

    cp commands/{{CMD}}.sh commands/newcmd.sh   # 改函数名与 cli_cmd 行
    make test

## 模板变量

模板目录下的 `template.config` 声明变量，一行一个 `KEY=VALUE`：

    DESCRIPTION=一行说明

模板里用 `{{DESCRIPTION}}` 引用。生成工程时可以覆盖：

    shellkit new ./mytool --set DESCRIPTION="我的工具"

## 钩子

模板目录下的 `template.hooks.d/pre` 与 `post` 是可执行脚本，
分别在落盘前与落盘后运行。它们拿到的环境变量有
`SHELLKIT_PROJECT_DIR`、`SHELLKIT_PROJECT_NAME`、`SHELLKIT_PROJECT_COMMANDS`、
`SHELLKIT_TEMPLATE_VERSION`，以及每个模板变量。

钩子失败会让生成失败 —— 这是故意的：钩子没做成的工程不算生成成功。

## 升级

生成的工程里有一份 `.shellkit-manifest`，记着模板版本与每个文件的指纹：

    shellkit upgrade /path/to/project          # 更新没被你改过的文件
    shellkit upgrade /path/to/project --check  # 只看会改什么，不动文件

你改过的文件一律留着不动，并告诉你哪些被跳过了。
