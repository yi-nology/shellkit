# shellkit man：把手册页生成出来

`shellkit man` 把 shellkit 自己的 man page 生成出来：第 1 节是命令总览，每个库模块一页第 3 节。

页面不是手写的 —— 命令来自 CLI 注册表，模块清单来自 `lib/modules.txt`，函数说明来自
`lib/core/*.sh` 里公开函数上方的注释块。加一个命令、改一句注释，页面自动跟着变；
另维护一份清单的那份一定会漂移。

## 用法

```bash
shellkit man                  # 第 1 节正文打到 stdout（stdout 只给数据）
shellkit man --out ./man      # 写文件：shellkit.1 + 每个模块一页 shellkit-<模块>.3
```

## 生成什么

| 文件 | 章节 | 内容 |
| --- | --- | --- |
| `shellkit.1` | 1 | 命令总览：命令名、描述、用法、分组，外加全局选项与退出码 |
| `shellkit-<模块>.3` | 3 | 该模块的公开函数：签名、摘要，以及 `@param` / `@exitcode` / `@see` |

模块清单以 `lib/modules.txt` 为准 —— 那里加一行，就多一页；删一行，就少一页。

## 退出码

| 码 | 含义 |
| --- | --- |
| 0 | 成功 |
| 2 | 用法错（未知选项、缺参数、多余参数） |
| 3 | 前置条件不满足（`--out` 目录不存在或不可写） |

## 写出文件后怎么看

```bash
shellkit man --out ./man
man -l ./man/shellkit.1
man -l ./man/shellkit-str.3
```

macOS 自带的 `man` 支持 `-l` 直接读本地文件，不必先 `man install` 到目录里。

## 当库用

man 模块提供 5 个公开函数（完整签名与退出码见 [REFERENCE.md](REFERENCE.md)）：
`man_page`（第 1 节正文）、`man_module_page`（某个模块的第 3 节正文）、
`man_write_all`（整页写进目录）、`man_modules`（模块名列表）、
`man_count_functions`（公开函数总数）。

```bash
. lib/bootstrap.sh
man_page > shellkit.1          # 第 1 节正文
man_module_page str            # 某个模块的第 3 节正文
man_write_all ./man            # 全部页面写进目录（目录必须已经存在）
```

## 数据来自哪里

- 命令总览：CLI 注册表，也就是 `cli_cmd` 注册命令时填的那几个数组。
- 模块清单：`lib/modules.txt` —— 加载顺序与依赖声明的唯一真相源。
- 函数说明：`lib/core/<模块>.sh` 里公开函数上方紧邻的注释块。首行是摘要，
  `@param` / `@exitcode` / `@see` 会被渲染成结构化条目；下划线开头的私有函数不进页面。

注释块必须紧邻函数、中间不能有空行 —— 空一行，shdoc 与 man 页都会丢掉整段说明。
