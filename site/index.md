---
home: true
title: shellkit
heroText: 写运维 shell 的起点
tagline: 一个约束清晰的 Bash 库 + 脚手架 + CLI 框架：让写出来的脚本又准又一致。
actions:
  - text: 三十秒上手
    link: /guide/quickstart.md
    type: primary
  - text: 一键安装
    link: /guide/installation.md
    type: secondary
  - text: API 参考
    link: /reference/index.md
    type: secondary
features:
  - title: stdout 只给数据
    details: 日志一律走 stderr，$(...) 拿到的永远是干净值。
  - title: 出参用 printf -v
    details: 3.2 没有 nameref，这是唯一可靠的返回值通道。
  - title: 基线是 3.2，不是 5.x
    details: macOS 自带 /bin/bash 就是 3.2.57，关联数组、nameref、mapfile 全库禁用。
  - title: 退出码是接口
    details: 0-5 各有含义，调用方靠它决定重不重试。
  - title: 一条命令生成工程
    details: shellkit new 生成的工程自带库副本与测试，当场 make test 通过。
  - title: 给 AI 的约束与代码同源
    details: 禁用语法表、任务落点表由同一份真相源拼出，改一处三处同更新。
# footer 与 footerHtml 要同时给：主题的页脚组件是 v-if="footer"，
# 只给 footerHtml 不会渲染（看起来像「配了没生效」）。
footer: 'MIT 许可 · 给 AI 直读：llms.txt —— 一个文件读完整个站点的地图'
footerHtml: '<a href="https://github.com/yi-nology/shellkit/blob/main/LICENSE">MIT</a> · <a href="https://yi-nology.github.io/shellkit/llms.txt" target="_blank" rel="noopener noreferrer">给 AI 直读：llms.txt</a> —— 一个文件读完整个站点的地图'
---

## 三件套怎么拼在一起

<ShotFigure src="/diagrams/assembly.svg" caption="库是唯一真相源：shellkit new 把它 vendor 进工程，CLI 负责日常；23 个模块各管一件事" />

每个模块的完整签名与退出码见 [API 参考](/reference/index.md)。

## 一条命令装上

安装脚本只做四件事：取版本号 → 下载 tar.gz 与 SHA256SUMS → 校验 → 交给包内自带的
`shellkit install-self`。它自己不往目标目录里放任何文件，安装逻辑只有一份。

```bash
curl -fsSL https://github.com/yi-nology/shellkit/releases/latest/download/install.sh | bash
```

默认装到 `/usr/local`；没有写权限就退到 `~/.local`。要钉版本或换目录：

```bash
curl -fsSL https://github.com/yi-nology/shellkit/releases/latest/download/install.sh | PREFIX="$HOME/.local" bash
curl -fsSL https://github.com/yi-nology/shellkit/releases/latest/download/install.sh | VERSION=0.19.0 bash
```

当前版本 **[下载 0.19.0](https://github.com/yi-nology/shellkit/releases/latest)**。
sha256 对不上就 `exit 5`，一个字节都不落地。

## 真跑出来的终端输出

每张图都是真跑出来的：`docs/shots/*.shot` 里每行 `$` 开头的命令会被执行，输出原样渲染成 SVG。

<ShotFigure src="/shots/doctor.svg" caption="先看环境缺什么，缺了也不影响核心功能" />

<ShotFigure src="/shots/new-project.svg" caption="生成的工程当场 make test 通过" />

<ShotFigure src="/shots/gate.svg" caption="文档里的例子改名会立刻红，不会悄悄烂掉" />

## 五条硬约定

每一条都有具体后果，不是风格偏好：

1. **stdout 只给数据，日志一律走 stderr。** 否则 `$(...)` 混进 `[INFO]`，调用方拿到脏值。
2. **出参用 `printf -v`，函数不改调用方变量。** 3.2 没有 nameref。
3. **取值优先级：显式参数 > 环境变量 > 配置文件 > 默认值。** 由 `conf_get_any` 统一实现。
4. **写文件必原子。** 临时文件 + `mv -f`，中断不会留下半个文件。
5. **库不改调用方的 shell 选项，也不改 cwd。** `set -euo pipefail` 只由你的入口脚本开。

展开讲在 [五条硬约定](/guide/conventions.md)，禁用语法与原因在 [Bash 3.2 兼容](/guide/bash32.md)。

## 下一步看哪份

| 你现在的情况 | 从哪进 |
| --- | --- |
| 想花五分钟判断值不值得用 | [三十秒](/guide/quickstart.md) |
| 已经有脚本在跑，想接库但不想重写 | [五步迁移](/guide/migrating.md) |
| 手上有具体活：改配置、下载校验、重试、单实例 | [Cookbook](/guide/cookbook.md) 25 个场景 |
| 要查某个函数的确切签名和退出码 | [API 参考](/reference/index.md) |
| 想让 AI 替你写 | [给 AI 用](/guide/ai.md) |
| 想先看完整工程长什么样 | [示例工程](/guide/examples.md) |
