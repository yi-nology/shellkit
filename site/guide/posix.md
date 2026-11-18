---
title: "POSIX 子集（设备侧）"
---


shellkit 的基线是 **Bash 3.2+**。但设备侧脚本跑在别的地方：NAS 的 start/stop、
OpenWrt 的 init、busybox 容器里的部署脚本 —— 那些机器默认**没有 bash**（装一个
bash 等于在用户设备上改运行时环境），而且脚本是**装机即执行**的：改坏 = 装上就挂，
现场还装不了 shellkit 补救。

所以 shellkit 另带一份 **POSIX 子集**：`lib/posix/shellkit-posix.sh`。
一份只写 POSIX 语法的库，与主库（`lib/core/`）并列，**不是**主库在 POSIX 下的降级运行。

## 怎么用

设备侧脚本是 `#!/bin/sh`，用 `.`（POSIX 标准写法）加载：

```sh
#!/bin/sh
. /opt/pigeonbox/lib/shellkit-posix.sh

log_info "starting pigeonbox"
conf_init /etc/pigeonbox/pigeonbox.conf
endpoint=$(conf_get_any ENDPOINT http://127.0.0.1:8080)
retry 3 fetch_config --endpoint "$endpoint"
```

> ⚠️ 注意是 `.` 不是 `source`：`source` 是 bash 专有写法，在 busybox ash 上
> **不是报错，是脚本起不来**。

加载点有三个，按现场情况挑：

| 位置 | 什么时候用 |
| --- | --- |
| 工程里的库副本（`vendor/shellkit/lib/posix/`） | 设备侧脚本随工程一起打包 |
| 系统安装目录（`<prefix>/lib/posix/`） | 设备侧脚本随系统包装进系统目录 |
| 仓库里的 `lib/posix/` | 开发期自测 |

`shellkit vendor` 同步的是整棵 `lib` 树 ⇒ **POSIX 子集跟着库副本一起走**，
不需要额外配置。

## 提供哪些能力

POSIX 子集只给「设备侧真的用得上」的那一小撮。完整清单在
`lib/posix/capabilities.tsv`（三列：函数名 / POSIX 子集里有没有 / 没有的话为什么）：

| 类别 | 函数 |
| --- | --- |
| 日志 | `log_info`、`log_ok`、`log_warn`、`log_error`、`log_debug`、`log_section` |
| 失败 | `fail`、`die` |
| 清理 | `trap_push`、`trap_install` |
| 重试 | `retry` |
| 文件 | `fs_ensure_dir`、`fs_ensure_file` |
| 下载与校验 | `net_download`、`net_sha256`、`net_verify` |
| 配置 | `conf_init`、`conf_get_any` |
| 版本 | `ver_cmp`、`ver_gt`、`ver_lt`、`ver_eq` |
| 锁 | `lock_acquire`、`lock_release` |
| 状态输出 | `status_emit`、`status_is_machine`、`status_state_valid`、`status_version`、`status_extra` |
| 能力查询 | `posix_capable` |

清单里没列的能力，主库里有、POSIX 子集里没有 —— 每一行都写明了原因
（设备侧用不上、需要数组、依赖 bash 的作业控制……）。

## 怎么判断「这条能不能用」

**别靠试**：设备侧试出来的失败往往是「装上就挂」，而现场装不了 shellkit 补救。

静态判断 —— 查能力清单：

```sh
. /opt/pigeonbox/lib/shellkit-posix.sh
if grep -q '^net_request	yes' /opt/pigeonbox/lib/posix/capabilities.tsv; then
  net_request GET "$url"
fi
```

运行时判断 —— 问库自己：

```sh
. /opt/pigeonbox/lib/shellkit-posix.sh
if posix_capable net_request; then
  net_request GET "$url"
fi
```

`posix_capable` 返回 0 = 有这条能力，1 = 没有，2 = 参数不对。

## 写 POSIX 子集时的纪律

POSIX sh 是**解析器级别**的约束：混进一个 bash 专有语法，busybox ash 上
不是报错，是**整个脚本起不来**。所以子集里的代码必须守住：

- 没有数组、没有 `[[ ]]`、没有 `local`、没有 `printf -v`、没有 `mapfile`；
- 没有 `source`（用 `.`）、没有 `+=`、没有大写展开、没有 `((...))` 算术；
- **函数里的自变量用专属变量名** —— POSIX 没有 `local`，名字会串到别的函数里
  （所以子集里到处是 `_sp_xxx` 这种带前缀的变量）；
- 取环境变量用 `printenv`，不用 `eval` 间接引用（`eval` 那一套既能注入，
  又过不了 shellcheck 的 sh 方言）。

## 门禁

```sh
make posix-check
```

这道门查五件事：

1. `lib/posix/*.sh` 用 `dash -n` 解析得过（dash 是最接近 POSIX 的实现）；
2. 过 `shellcheck -s sh`（bashism 一律挑出来）；
3. 本地再扫一遍常见 bashism（shellcheck 没覆盖到的写法也挑出来）；
4. 能力清单与源码对得上 —— 清单里 `yes` 的必须真在 POSIX 库里，`no` 的必须真在
   主库里，每个 `no` 都得写明原因；
5. 清单与源码不一致时给出重生成命令（`bash tools/check_posix.sh --write`）。

门禁本体在 `tools/check_posix.sh`，判据在 `tests/test_posix.sh`。
`make check` 里已经包含这一步。

## 与主库的关系

- POSIX 子集**不在 1.x 的兼容承诺面内**（见 `docs/COMPATIBILITY.md`）：
  主库公开函数的返回码与行为有承诺，POSIX 子集是附属实现。
- 两份代码**不共享实现**：主库用 bash 专有语法（数组、`printf -v`、作业控制），
  POSIX 子集用 POSIX 语法重写同一件事。改主库的行为，**不要**顺手改子集 ——
  那是另一份承诺。
- 子集的行为以 `lib/posix/shellkit-posix.sh` 的注释与 `tests/test_posix.sh` 为准。
