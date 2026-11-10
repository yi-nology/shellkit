---
home: true
title: shellkit
heroText: 写运维 shell 的起点
tagline: 一个约束清晰的 Bash 库、一个脚手架生成器、一套 CLI 框架。目标不是功能多，而是让写出来的脚本又准又一致。
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
    details: 日志一律走 stderr。所以 v=$(conf_get KEY) 拿到的永远是干净的值，不会混进 [INFO]。
  - title: 出参用 printf -v
    details: 函数不直接改调用方变量。Bash 3.2 没有 nameref，这是唯一在 3.2 上可靠的返回值通道。
  - title: 基线是 3.2，不是 5.x
    details: macOS 自带的 /bin/bash 就是 3.2.57。关联数组、nameref、mapfile 全库禁用。
  - title: 退出码是接口
    details: 0 成功、1 一般错误、2 用法错、3 前置条件、4 网络、5 校验。调用方靠它决定重不重试。
  - title: 一条命令生成工程
    details: shellkit new 生成的工程自带库副本、测试、Makefile 和给 AI 的约束，当场 make test 通过。
  - title: 给 AI 的约束与代码同源
    details: 禁用语法表、任务落点表、交付自检都由 docs/ai/contract.md 拼出，改一处三处同时更新。
---

## 一条命令装上

安装脚本只做四件事：取版本号 → 下载 tar.gz 与 SHA256SUMS → 校验 → 交给包内自带的
`shellkit install-self`。它自己不往目标目录里放任何文件，安装逻辑只有一份。

```bash
curl -fsSL https://github.com/yi-nology/shellkit/releases/latest/download/install.sh | bash
```

默认装到 `/usr/local`；没有写权限就退到 `~/.local`。要钉版本或换目录：

```bash
curl -fsSL https://github.com/yi-nology/shellkit/releases/latest/download/install.sh | PREFIX="$HOME/.local" bash
curl -fsSL https://github.com/yi-nology/shellkit/releases/latest/download/install.sh | VERSION=0.10.0 bash
```

当前版本 **[下载 0.10.0](https://github.com/yi-nology/shellkit/releases/latest)**。
sha256 对不上就 `exit 5`，一个字节都不落地。

## 真跑出来的终端输出

下面每张图都是真跑出来的：`docs/shots/*.shot` 里每行 `$` 开头的命令会被执行，输出原样渲染成 SVG。
所以版本号、路径、退出码都是当时的真值，不是画的。

<ShotFigure src="/shots/doctor.svg" caption="先看环境缺什么，缺了也不影响核心功能" />

<ShotFigure src="/shots/new-project.svg" caption="生成的工程当场 make test 通过" />

<ShotFigure src="/shots/gate.svg" caption="文档里的例子改名会立刻红，不会悄悄烂掉" />

## 18 个模块，一个模块一个主题

你该做的是装配，不是重新实现一遍。每个模块的完整签名与退出码见 [API 参考](/reference/index.md)。

| 模块 | 管什么 |
| --- | --- |
| [error](/reference/error.md) | 失败即返回既定退出码 |
| [i18n](/reference/i18n.md) | msgid 英文，缺 gettext 时原样输出 |
| [log](/reference/log.md) | 全部走 stderr，彩色可关 |
| [str](/reference/str.md) | 3.2 没有大小写变换，用 tr 兜底 |
| [validate](/reference/validate.md) | 校验失败原因写进 SK_VALIDATE_ERR |
| [fs](/reference/fs.md) | 原子写、备份轮转、幂等改文件 |
| [os](/reference/os.md) | Darwin / Linux 差异只在这里 |
| [trap](/reference/trap.md) | 清理栈：LIFO、幂等、退出码保真 |
| [run](/reference/run.md) | 失败即停；dry-run 只打印 |
| [retry](/reference/retry.md) | 退避重试，不管用法错 |
| [lock](/reference/lock.md) | mkdir 原子锁，拿到即进清理栈 |
| [net](/reference/net.md) | 下载带 sha256 校验与镜像回退 |
| [http](/reference/http.md) | 发 HTTP 请求，状态码与业务错分开看 |
| [config](/reference/config.md) | KEY=VALUE 与 dotenv，环境变量优先 |
| [scaffold](/reference/scaffold.md) | 模板变量、生成物清单、钩子 |
| [prompt](/reference/prompt.md) | 超时回退默认值 |
| [cli](/reference/cli.md) | 注册即生效，动态分发 |

## 五条硬约定

这五条是「准」的来源，不是风格偏好 —— 每一条都有具体后果：

1. **stdout 只给数据，日志一律 stderr。** 否则 `$(...)` 会混进 `[INFO]`，调用方拿到脏值。
2. **出参用 `printf -v "$var"`，函数不直接改调用方变量。** 3.2 没有 nameref。
3. **取值优先级：显式参数 > 环境变量 > 配置文件 > 默认值。** 由 `conf_get_any` 统一实现。
4. **写文件必原子。** 临时文件加 `mv -f`，中断不会留下半个文件。
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

## 许可

MIT，见 [LICENSE](https://github.com/yi-nology/shellkit/blob/main/LICENSE)。

设计骨架参考自 [jumpserver/installer](https://github.com/jumpserver/installer)（GPLv3），
原署名保留在 [NOTICE](https://github.com/yi-nology/shellkit/blob/main/NOTICE) 里；
shellkit 的代码是独立实现，未复制上游代码。
