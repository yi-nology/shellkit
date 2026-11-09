# 故障排查

先看退出码，再看症状表。**退出码就是接口**，它比日志更可靠 —— 日志可能被 `--no-color`
或重定向改掉，退出码不会。

## 退出码

| 码 | 宏 | 含义 | 典型来源 |
| --- | --- | --- | --- |
| 0 | `SK_OK` | 成功 | — |
| 1 | `SK_ERR` | 一般错误 | 命令函数自己 `fail "$SK_ERR"` |
| 2 | `SK_USAGE` | 用法错 | 参数不对、未知选项、`_sk_need_args` |
| 3 | `SK_PRECOND` | 前置条件不满足 | 缺命令、非 root、该交互却没默认值、拿不到锁 |
| 4 | `SK_NET` | 网络失败 | `net_download`、`net_wait_port` 超时 |
| 5 | `SK_VERIFY` | 校验失败 | sha256 不匹配、文档与代码不一致、`vendor --check` 漂移 |

调用方靠这个码决定重试还是不重试：`retry` 只重试 `SK_NET`，遇到 `SK_USAGE` 与 `SK_VERIFY`
直接放弃 —— 这两类重试一百次结果一样。

## 症状 → 处理

| 症状 | 多半是这个原因 | 怎么办 |
| --- | --- | --- |
| `$(...)` 拿到的值里混着 `[INFO]` | 某处日志写到了 stdout | 日志只许 `log_*`（走 stderr）；自定义输出用 `printf >&2` |
| `bad substitution` | 用了 `${v^^}` / `${v,,}` | 改 `tr a-z A-Z`，见 [Bash 3.2](./bash32.md) |
| `declare: -A: invalid option` | 用了关联数组 | 改 `case` 分派或两个平行数组 |
| `command not found: mapfile` | 用了 `mapfile` | 改 `while IFS= read -r` |
| `unbound variable` 且指向数组 | `set -u` 下展开空数组 | 写 `${arr[@]+"${arr[@]}"}` |
| 脚本在 `if run ...` 里整体退出 | `run` 失败调 `die`，`exit` 不受 `if` 约束 | 改 `run --no-die`，只拿返回码 |
| 部署脚本每次都重启服务 | 没有比对内容就写文件 | 先比内容，变了才写；`fs_ensure_*` 天然幂等 |
| 配置文件权限变成 644 | 直接 `echo >>` 追加 | 用 `conf_set` / `fs_atomic_*`（走 `cp -p` 保权限） |
| 同一秒两次备份只剩一份 | 备份名只到秒 | 0.6.0 起备份名带 pid 与序号，升级即可 |
| `lock_acquire` 永远拿不到锁 | 上次被 `SIGKILL`，锁目录留着没 pid | 0.6.0 起无 pid 的锁给 5 秒宽限后回收 |
| 文档改完 `make check` 红 | 生成物没跟着更新 | 跑 `./shellkit docs`，再 `bash po/messages.sh` |
| `check-docs` 报 unknown function | 例子里用了不存在或改名的函数 | 去 [API 参考](/reference/index.md) 核对签名 |
| `messages-check` 每次都红 | pot 里带了绝对路径或行号 | 用 `bash po/messages.sh` 重新生成（`--no-location` 已内置） |

## 三条排查纪律

1. **先复现，再改代码。** 没有稳定复现的修改只是让现象换了个样子。
2. **判据落在产物上，不落在「命令没报错」上。** `gh issue close`、`gh issue create` 这类命令
   成功时也可能一行都不打印；要回读状态或产物。
3. **反向验证一次。** 修完之后，先在旧代码上确认测试确实红，再在新代码上确认绿 ——
   没红过的测试不能证明任何事。

## 调试开关

```bash
# 打开 debug 日志
SHELLKIT_DEBUG=1 ./bin/myapp start

# 关掉颜色，方便贴日志
SHELLKIT_COLOR=never ./bin/myapp start

# 非交互：所有提问取默认值。缺默认值时返回 SK_PRECOND(3)
SHELLKIT_NONINTERACTIVE=1 ./bin/myapp start

# 保留临时目录，事后看现场
SHELLKIT_TMP_KEEP=1 ./bin/myapp start
```

`SHELLKIT_NONINTERACTIVE=1` 下如果某个提问**没有默认值**，库会返回 3 而不是卡在那里等输入 ——
这是为了让「在 CI 里跑到一个交互点」变成明确的失败，而不是挂死。
