# {{NAME}}

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
