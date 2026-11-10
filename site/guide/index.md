# 指南

这套文档按「你现在要解决什么」组织，不按功能目录组织。

## 三条常见路径

| 你的情况 | 读这三篇就够 |
| --- | --- |
| 第一次接触，想判断值不值得用 | [三十秒](./quickstart.md) → [五条硬约定](./conventions.md) → [Cookbook](./cookbook.md) |
| 已经有脚本在跑，想接库但不重写 | [安装](./installation.md) → [五步迁移](./migrating.md) → [测试与门禁](./testing.md) |
| 要查某个函数到底怎么调 | [API 参考](/reference/index.md)，每个模块一页 |

## 开始

- [安装与升级](./installation.md) —— 一条命令、钉版本、内网镜像、离线包、更新与卸载。
- [三十秒上手](./quickstart.md) —— 生成工程、看结构、加第一个子命令。

## 核心概念

- [五条硬约定](./conventions.md) —— 为什么 stdout 只给数据、为什么出参要用 `printf -v`。
- [Bash 3.2 兼容](./bash32.md) —— 哪些语法在 macOS 自带的 bash 上直接崩，以及为什么。
- [模块地图](./modules.md) —— 20 个模块各管什么，什么时候该用哪个。

## 常见任务

- [Cookbook](./cookbook.md) —— 25 个场景，每节都是「场景 / 代码 / 为什么」。
- [CLI 框架](./cli.md) —— 注册式命令、帮助自动生成、选项解析。
- [国际化](./i18n.md) —— msgid 英文、pot/po/mo、缺 gettext 时的降级。
- [测试与门禁](./testing.md) —— 断言库、逐文件执行器、`make check` 每一步拦什么。
- [给 AI 用](./ai.md) —— 三份同源契约，以及一段能直接用的提示词。

## 进阶

- [示例工程](./examples.md) —— 两个能直接跑的真实工程，讲的是装配。
- [五步迁移](./migrating.md) —— 先杀 stdout 污染，再接配置、交互、CLI、测试。
- [发版](./releasing.md) —— 一条命令升版本，以及为什么要这样。
- [参与开发](./contributing.md) —— 加一个模块要改三处，少一处就红。

## 排错

- [故障排查](./troubleshooting.md) —— 退出码 → 症状 → 处理。
- [FAQ](./faq.md) —— 十二个真实被问到的问题。
