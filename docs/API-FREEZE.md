# API 冻结清单（v1.0.0）

> 生成物：由 `bash tools/api_freeze.sh --write` 从 `tools/api_baseline.txt`、
> `lib/core/*.sh`、`lib/modules.txt`、`lib/bootstrap.sh` 与 `shellkit` 的
> `cli_cmd` 注册生成 —— **不要手改**。
>
> frozen-at: 0.27.0
> 承诺面：50 个 `@stability stable` 公开函数 + 退出码表 + CLI 子命令形状。
> 其余 112 个 `@stability experimental` 函数**不在兼容承诺内**（见 `docs/COMPATIBILITY.md`）。

## 冻结口径（1.x）

- 表内函数的**返回码集合、stdout 数据、产出文件名与路径**在 1.x 内不变；
- **stderr 的日志措辞与译文不在承诺内**（可以改、可以本地化）；
- 表外函数（experimental）随时可变，变更仍要写进 `docs/MIGRATING.md`；
- 改动表内函数的任何结果 ⇒ 升 **minor** + 迁移表 + 重生成此清单；
- 这份清单由门禁对账：源码与已提交清单不一致 ⇒ `make check` 红。

## 退出码

| 码 | 常量 | 含义 |
|---|---|---|
| 0 | `SK_OK` | 成功 |
| 1 | `SK_ERR` | 一般错误 |
| 2 | `SK_USAGE` | 用法错（参数不对） |
| 3 | `SK_PRECOND` | 前置条件不满足（缺命令、非 root、该交互却没有默认值） |
| 4 | `SK_NET` | 网络失败 |
| 5 | `SK_VERIFY` | 校验失败（sha256 不匹配、文档与代码不一致） |

单次调用实际可能返回的码集合见下表的「承诺返回码」列；不在该列里的码不承诺。

## 按模块（stable 函数）

### error

| 函数 | 承诺返回码 | 探针 | 说明 |
|---|---|---|---|
| `fail` | 0,2,其他 | probe | 不退出，只返回码；CODE 校验同 die |
| `require_cmd` | 0,2,3 | probe | 零参数返回 SK_USAGE（否则 'require_cmd "$EMPTY"' 会静默通过） |

### validate

| 函数 | 承诺返回码 | 探针 | 说明 |
|---|---|---|---|
| `validate_ip` | 0,1 | probe | 四段十进制，每段 0-255，且不接受前导零（010 会被当成八进制） |

### trap

| 函数 | 承诺返回码 | 探针 | 说明 |
|---|---|---|---|
| `trap_install` | 0 | probe | 安装 EXIT / INT / TERM / HUP 处理器；可重复调用 |
| `trap_push` | 0,2 | probe | 注册一个清理动作；后注册的先执行 |

### fs

| 函数 | 承诺返回码 | 探针 | 说明 |
|---|---|---|---|
| `fs_atomic_copy` | 0,1,2 | probe | 按字节把 SRC 复制到 DST；写法是原子的 |
| `fs_atomic_write` | 0,1,2 | probe | 原子写文件；默认权限 600，父目录不存在会先建 |
| `fs_backup` | 0,1,2 | probe | 产出 FILE.bak.YYYYmmddHHMMSS，按名升序保留最新 KEEP 份 |
| `fs_ensure_block` | 0,1,2 | probe | 标记块内内容整体替换；没有就追加。幂等。 |
| `fs_ensure_dir` | 0,1,2 | probe | 幂等建目录；给了 MODE 就 chmod |
| `fs_ensure_line` | 0,1,2 | probe | 整行精确匹配；不存在才追加。幂等。 |
| `fs_ensure_symlink` | 0,1,2 | probe | 已是正确链接则不动；否者替换（绝不覆盖普通文件） |
| `fs_tmp_init` | 0,1 | probe | 在当前 shell 初始化临时目录，并把清理动作推进清理栈。 |
| `fs_tmpdir` | 0,1 | probe | 确保临时目录存在并输出路径。 |

### run

| 函数 | 承诺返回码 | 探针 | 说明 |
|---|---|---|---|
| `run` | 0,2,其他 | probe | 执行命令，失败即 die；--no-die 只返回码 |
| `run_concurrent` | 0,2,其他 | probe | 把同一条命令并发跑 N 份 |

### os

| 函数 | 承诺返回码 | 探针 | 说明 |
|---|---|---|---|
| `os_has_cmd` | 0,1,2 | probe | 零参数返回 SK_USAGE（空真会让前置检查静默通过） |

### ver

| 函数 | 承诺返回码 | 探针 | 说明 |
|---|---|---|---|
| `ver_cmp` | 0,2 | probe | 比较两个版本号 |
| `ver_eq` | 0,1,2 | probe | 两个版本是否相等 |
| `ver_gt` | 0,1,2 | probe | A 是否比 B 新 |
| `ver_lt` | 0,1,2 | probe | A 是否比 B 旧 |

### registry

| 函数 | 承诺返回码 | 探针 | 说明 |
|---|---|---|---|
| `registry_add` | 0 | probe | 把一份清单文件登记进索引（条目名 = NAME） |
| `registry_deps` | 0,1 | probe | 传递依赖（拓扑序，空格分隔，不含自身） |
| `registry_get` | 0 | probe | 取字段值（未声明时为空） |
| `registry_scan` | 0 | probe | 扫描清单文件并建立索引 |
| `registry_topo` | 0,1 | probe | 全体拓扑序（空格分隔） |
| `registry_visible` | 0,1 | probe | 条目在当前平台是否可见 |

### retry

| 函数 | 承诺返回码 | 探针 | 说明 |
|---|---|---|---|
| `retry` | 0,2,其他 | probe | 失败退避重试；用法错与校验失败不重试 |

### lock

| 函数 | 承诺返回码 | 探针 | 说明 |
|---|---|---|---|
| `lock_acquire` | 0,2,3 | probe | 0 成功；SK_PRECOND 被占用/超时；SK_USAGE 名字非法 |
| `lock_held` | 0,1,2 | probe | 返回码判断是否被占；被占时 stdout 输出持有者 pid |
| `lock_release` | 0,2,3 | probe | 只释放自己持有的锁 |

### config

| 函数 | 承诺返回码 | 探针 | 说明 |
|---|---|---|---|
| `conf_disable` | 0,1,2 | probe | 把 KEY=VALUE 改成注释行，保留原值 |
| `conf_file` | 0 | probe | 当前生效的配置文件路径；未初始化时为空 |
| `conf_format` | 0 | probe | 当前生效的配置格式（auto\|env\|dotenv） |
| `conf_get` | 0,2 | probe | 只输出值；未初始化或无文件时返回默认值 |
| `conf_get_any` | 0,2 | probe | 环境变量 > 配置层 > 配置文件 > 默认值 |
| `conf_has` | 0,1,2 | probe | 返回码 0/1 |
| `conf_init` | 0,2 | probe | 载入配置文件；文件不存在不报错（当成空配置） |
| `conf_keys` | 0 | probe | 逐行输出键名（配置层的键在前，文件里的键在后，不重复） |
| `conf_load_dotenv` | 0,2,3 | probe | 把 dotenv 文件的键值载入配置层 |
| `conf_set` | 0,1,2,3 | probe | 校验 + 值未变则跳过 + 原子写 + 600 |
| `conf_source` | 0,2,3 | probe | 把 dotenv 文件的键导出为环境变量（供子进程继承） |
| `conf_unset` | 0,1,2 | probe | 删掉一个键；幂等，键不存在也算成功 |

### prompt

| 函数 | 承诺返回码 | 探针 | 说明 |
|---|---|---|---|
| `ask` | 0,1,2,3 | probe | 问一个问题，把答案写进 VAR；超时或 EOF 回退默认值 |
| `ask_choice` | 0,1,2,3 | probe | 多选一；超时或 EOF 回退默认值 |
| `ask_yn` | 0,1,2,3 | probe | 结果写入 y 或 n |
| `confirm` | 0,1,2,3 | probe | 只返回码 |

### cli

| 函数 | 承诺返回码 | 探针 | 说明 |
|---|---|---|---|
| `cli_opt` | 0,2 | probe | 注册一个选项；第四个参数为 1 表示这个选项要吃值 |
| `cli_opts` | 0,2 | probe | 按 cli_opt 注册的规则解析子命令选项；剩余位置参数进 SK_OPTS_LEFT |
| `cli_run` | 0,1,2,其他 | probe | 分发入口：吃全局选项后按名字找同名 cmd_ 前缀的函数 |

## CLI 形状（承诺子命令与参数形状）

| 子命令 | 用法 |
|---|---|
| `new` | `new <dir> [--name NAME] [--cmd NAME]... [--template DIR] [--set K=V] [--yes]` |
| `demo` | `demo [DIR] [--no-test]` |
| `upgrade` | `upgrade <dir> [--check] [--diff] [--force]` |
| `doctor` | `doctor [--dir DIR] [--json]` |
| `list` | `list` |
| `vendor` | `vendor <dir> [--check] [--force]` |
| `docs` | `docs [--check]` |
| `man` | `man [--out DIR]` |
| `completion` | `completion [bash\|zsh] [--install]` |
| `install-self` | `install-self [--prefix DIR] [--force]` |
| `uninstall-self` | `uninstall-self [--prefix DIR] [--purge] [--legacy]` |
| `update` | `update [--check] [--force] [--from FILE] [--sha256 SUM] [--prefix DIR]` |
| `skill` | `skill <list\|install\|uninstall\|print> [--client NAME] [--dir DIR] [--force]` |

说明文案不承诺：它们会按 `SHELLKIT_LANG` 本地化，措辞也可能改进；
子命令名、参数与选项形状、以及退出码属于承诺面。
