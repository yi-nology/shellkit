# CLI 速查

> 由 `tools/skill_pack.sh` 从 `shellkit` 的 `cli_cmd` 注册表解析生成 —— 加命令不用改这里。

## project generation

| 命令 | 用法 | 说明 |
| --- | --- | --- |
| `shellkit new` | `new <dir> [--name NAME] [--cmd NAME]... [--template DIR] [--set K=V] [--yes]` | create a new project skeleton |
| `shellkit demo` | `demo [DIR] [--no-test]` | generate a demo project and walk through it |
| `shellkit upgrade` | `upgrade <dir> [--check] [--diff] [--force]` | update a generated project to the current template |

## environment

| 命令 | 用法 | 说明 |
| --- | --- | --- |
| `shellkit doctor` | `doctor [--dir DIR] [--json]` | check the runtime environment |
| `shellkit list` | `list` | list templates and library modules |

## existing projects

| 命令 | 用法 | 说明 |
| --- | --- | --- |
| `shellkit vendor` | `vendor <dir> [--check] [--force]` | sync the library into an existing project |

## documentation

| 命令 | 用法 | 说明 |
| --- | --- | --- |
| `shellkit docs` | `docs [--check]` | regenerate the API reference |
| `shellkit man` | `man [--out DIR]` | generate man pages |
| `shellkit completion` | `completion [bash|zsh] [--install]` | print or install a shell completion script |

## installation

| 命令 | 用法 | 说明 |
| --- | --- | --- |
| `shellkit install-self` | `install-self [--prefix DIR] [--force]` | install shellkit into PATH |
| `shellkit uninstall-self` | `uninstall-self [--prefix DIR]` | remove an installed shellkit |
| `shellkit update` | `update [--check] [--from FILE] [--sha256 SUM] [--prefix DIR]` | update an installed shellkit |

## AI clients

| 命令 | 用法 | 说明 |
| --- | --- | --- |
| `shellkit skill` | `skill <list|install|uninstall|print> [--client NAME] [--dir DIR] [--force]` | install the AI skill into an AI client |

## 退出码

| 码 | 含义 |
| --- | --- |
| 0 | 成功 |
| 1 | 一般错误 |
| 2 | 用法错（参数不对） |
| 3 | 前置条件不满足（缺命令、非 root、该交互却没有默认值） |
| 4 | 网络失败 |
| 5 | 校验失败（sha256 不匹配、文档与代码不一致） |
