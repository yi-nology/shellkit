# 模块地图

`lib/bootstrap.sh` 是唯一入口，一次性按**拓扑序**加载全部 23 个模块。你不用挑着 source，
也不该复制某个模块的实现进自己的脚本 —— 那是把「同一个坑踩两遍」的另一种写法。

## 一张表

| 模块 | 职责 | 关键函数 |
| --- | --- | --- |
| [error](/reference/error.md) | 失败与前置条件 | `die` `fail` `require_cmd` `require_root` `require_file` `require_bash` |
| [i18n](/reference/i18n.md) | 译文查找 | `_t` `_tn` |
| [log](/reference/log.md) | 全部走 stderr | `log_info` `log_ok` `log_warn` `log_error` `log_debug` `log_section` |
| [str](/reference/str.md) | 3.2 没有的字符串操作 | `str_trim` `str_lower` `str_upper` `str_contains` `str_starts_with` `str_ends_with` `str_repeat` |
| [validate](/reference/validate.md) | 输入校验 | `validate_not_empty` `validate_single_line` `validate_key` `validate_port` `validate_ip` `validate_version` `validate_abs_path` `validate_url` `validate_enum` |
| [fs](/reference/fs.md) | 原子写与幂等改文件 | `fs_atomic_write` `fs_backup` `fs_ensure_dir` `fs_ensure_line` `fs_ensure_block` `fs_ensure_symlink` `fs_tmp_init` |
| [os](/reference/os.md) | 平台差异只在这里 | `os_name` `os_arch` `os_is_root` `os_has_cmd` `os_pkg_install` `os_sed_i` `os_md5` `os_sha256` |
| [trap](/reference/trap.md) | 清理栈 | `trap_push` `trap_pop` `trap_cleanup` `trap_install` `trap_list` |
| [run](/reference/run.md) | 跑命令 | `run` |
| [retry](/reference/retry.md) | 退避重试 | `retry` |
| [lock](/reference/lock.md) | 单实例 | `lock_acquire` `lock_release` `lock_held` |
| [net](/reference/net.md) | 下载与就绪探测 | `net_download` `net_verify` `net_sha256` `net_wait_port` `net_wait_http` |
| [http](/reference/http.md) | 发 HTTP 请求 | `net_request` `net_json` `net_escape_json` |
| [config](/reference/config.md) | KEY=VALUE 与 dotenv 配置 | `conf_init` `conf_get` `conf_get_any` `conf_has` `conf_set` `conf_unset` `conf_disable` `conf_keys` `conf_load_dotenv` `conf_source` |
| [scaffold](/reference/scaffold.md) | 模板变量、生成物清单、钩子 | `scaffold_vars_set` `scaffold_vars_get` `scaffold_config_load` `scaffold_render` `scaffold_manifest_read` `scaffold_run_hook` |
| [prompt](/reference/prompt.md) | 交互 | `ask` `ask_yn` `ask_choice` `confirm` |
| [cli](/reference/cli.md) | 注册式命令框架 | `cli_group` `cli_cmd` `cli_run` `cli_opt` `cli_opts` `cli_has` `cli_usage_global` |
| [man](/reference/man.md) | 生成 man page | `man_page` `man_module_page` `man_write_all` `man_modules` `man_count_functions` |

## 加载顺序不是字母序

拓扑序的理由：后面的模块会调用前面的。比如 `log` 要能用 `_t`（先加载 `i18n`），
`error` 要用 `log_error`，`cli` 要用 `log_error` 和 `_t`。

这份顺序写在**一个文件**里 —— `lib/modules.txt`，两列：

```text
i18n
log          i18n
error        i18n log
str          error
```

第一列是模块名，第二列是它**直接依赖**的模块（空格分隔，可以不写）。
`lib/bootstrap.sh` 按它加载，`tools/shdoc.sh` 按它生成 API 参考，文档站也按它同步 ——
加一个模块只改这一个文件，没有第二处要对。

依赖必须排在依赖者前面。放错了不用等运行时才发现：`make module-order-check` 会直接
指出「哪个模块调用了还没加载的模块的函数」。

## 只加载你要的模块

默认全量加载（23 个模块）。真要瘦下来：

```bash
SHELLKIT_MODULES="log fs" . ./vendor/shellkit/lib/bootstrap.sh
```

只有列出来的模块会被加载，**它们的传递依赖会自动带上**（`i18n` 永远加载，
因为每个模块都要翻译）。

## 按任务选模块

| 你现在要做的事 | 用哪个 |
| --- | --- |
| 打一条日志 | `log_info` / `log_ok` / `log_warn` / `log_error` / `log_debug` / `log_section` |
| 失败就退出并给退出码 | `die` / `fail` / `require_cmd` / `require_root` / `require_file` |
| 读配置（环境变量优先） | `conf_init` 之后 `conf_get_any` |
| 改配置且要幂等 | `conf_set`；改任意文件用 `fs_ensure_line` / `fs_ensure_block` |
| 写文件不想写坏 | `fs_atomic_write`；备份用 `fs_backup` |
| 下载并校验 | `net_download URL DEST [SHA256]`，镜像回退已内置 |
| 等端口 / 等 HTTP | `net_wait_port` / `net_wait_http` |
| 跑命令，失败即停 | `run systemctl restart nginx` |
| 跑命令但要自己判成败 | `run --no-die systemctl is-active nginx` |
| 失败重试几次 | `retry 5 curl -fsS "$url" -o x` |
| 保证同时只跑一个实例 | `lock_acquire deploy 30` |
| 退出时一定要收尾 | `trap_push 'rm -rf "$workdir"'` + `trap_install` |
| 问用户一个问题 | `ask` / `ask_yn` / `ask_choice` / `confirm` |
| 加一个子命令 | `cli_cmd` 注册 + `cmd_<name>` 实现 |
| 输出中英文 | `_t 'english msgid'`，译文在 `locale/` |

## 几个容易混的边界

- `run` 默认**失败即 `die`**，而 `die` 里的 `exit` 不受调用方 `if` / `||` 约束。想在条件里判成败，
  用 `run --no-die`，它只返回码。
- `retry` **不重试**用法错（`SK_USAGE`）和校验失败（`SK_VERIFY`）：这两类重试一百次结果一样。
- `lock_acquire` 拿到锁就挂进清理栈，脚本退出自动释放；不需要手写 `trap 'lock_release'`。
- `conf_get` 只看配置文件；要「环境变量优先」用 `conf_get_any`。名字只差一点，行为差很多。
