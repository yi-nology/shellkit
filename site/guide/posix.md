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
| 进程与看门狗 | `proc_start`、`proc_stop`、`proc_is_running`、`proc_watchdog` |
| 能力查询 | `posix_capable` |

清单里没列的能力，主库里有、POSIX 子集里没有 —— 每一行都写明了原因
（设备侧用不上、需要数组、依赖 bash 的作业控制……）。
**有**的那几行，第三列同样有话：写清这一条在设备侧**长什么样**
（例如 `proc_*` 那一行写明「没有作业控制 ⇒ 靠 `setsid` 拿进程组，
拿不到时只停主进程」）。一根 `-` 等于没写。

## 设备侧的进程层（proc_*）

设备侧启动脚本的另一半：**后台引导 + 整组停止 + 探活自愈**。
手写这三件事要自己对付三个坑，而这三个坑主库早就对付过了：

1. **僵尸假阳性**：`kill -0 <pid>` 对**僵尸进程仍然返回 0**
   ⇒ 只用 `kill -0` 判存活，永远等不到「进程已退出」⇒ 停不干净、
   pid 文件永远清不掉、看门狗永远以为进程还在。
2. **只杀主进程**：子进程残留、端口还占着（手写最常见的坑）。
3. **重启风暴**：探活失败与超时不分、没有退避 ⇒ 设备上疯狂重启。

POSIX 子集里的这四个函数与主库**同名**、返回码一致：

`@sh
#!/bin/sh
. /opt/pigeonbox/lib/shellkit-posix.sh

proc_start pigeonbox /opt/pigeonbox/bin/pigeonbox   # 后台拉起 + pid 文件
proc_is_running pigeonbox                            # 探活（僵尸判死）
proc_stop pigeonbox                                  # 整组停
`@

看门狗（探活失败就拉起，带退避；连续失败到上限就**放弃并返回非 0**）：

`@sh
proc_watchdog --interval 5 --max-backoff 60 --max-restarts 5 pigeonbox /opt/pigeonbox/bin/pigeonbox
`@

### 它在设备侧是怎么降级的（说清楚，别让人按主库的行为去假设）

| 场合 | 设备侧的做法 | 拿不到时 |
| --- | --- | --- |
| 脱离终端 | `setsid` > `nohup` > 子 shell 忽略 SIGHUP（三级退化） | —— |
| 进程组 | `setsid` 给一个新会话 ⇒ 整组停做得到 | 拿不到就**只停主进程**（宁可留子进程，也不能自杀） |
| 进程状态 | 读 `/proc/<pid>/stat` 的状态位（`Z`/`X` 判死） | 查不到就退化成 `kill -0`（判据变粗，但不误杀） |

### 三条实测出来的约束（busybox 1.36 容器里逐条验的）

1. **整组停不能带 `--`**：
   `kill -TERM -- -1234` 在 busybox 报 `invalid number '--'`、
   dash 报 `Illegal number: -` ⇒ 两边都没杀成；
   而 `kill -TERM -1234`（不带 `--`）busybox 与 dash 都认，bash 反而不认。
   ⇒ 两种都试，先带 `--`，失败再不带。
2. **busybox 的 `ps` 不认 `-p`**（`invalid option -- 'p'`），
   也不认 `stat=` 的表头抑制 ⇒ 状态与进程组改读 `/proc/<pid>/stat`，
   `ps` 只当兜底。
4. **信号名必须带前导 `-`**（`kill -TERM`，不是 `kill TERM`）：
   busybox 的 kill 认不带横杠的信号名，而 dash 与 bash 会把 `TERM` 当成
   **一个 pid** ⇒ 整组杀根本没发生 ⇒ 进程停不掉（退出码 3）。
   ⚠ 这条错**只在有 setsid 的机器上才走到**（macOS 没有 setsid ⇒
   走「只停主进程」的降级 ⇒ 本机永远是绿的）⇒ 判据要在目标环境里跑。
5. **僵尸状态按前缀认**（`Z*`）：Linux 常报 `Z`、macOS/BSD 常报 `Z+` ⇒
   精确匹配只能认中一种 ⇒ 另一种机器上僵尸被当成活进程。
3. **`setsid` 在「已经是组长」时会 fork** ⇒ 父进程拿到的 `$!`
   可能是 setsid 的 pid 而不是真正那条命令的 pid ⇒
   pid 文件由**子进程自己写**（`exec` 不改 pid ⇒ 写的必然是它）。

### 不要两份同时加载

这四个函数与主库**同名** ⇒ bash 与 ash 都是「后定义覆盖先定义」⇒
主库与 POSIX 子集**同时加载**时，后加载的那份会顶掉先加载的那份。
按需只加载一份：bash 侧用主库，设备侧用 POSIX 子集。

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
- **起名字别撞上子集自己的公开函数**：子集里有 `fail()` 与 `die()`
  ⇒ 判据脚本（或其他调用方）再定义一个 `fail()` 会被子集那份覆盖
  （后定义覆盖先定义）⇒ 自己的失败计数永远不增 ⇒ **判据假绿**。
  辅助函数用独占前缀。
- 判据要能在**真解释器**上跑：同一份 POSIX sh 脚本在 dash 与 busybox ash 上
  原样跑（见下面的门禁），而不是在 bash 上「假装是 ash」。

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

### 判据在真解释器上跑

`tests/posix_smoke.sh` 是一份**只用 POSIX sh 语法**的判据脚本
（设备侧那一层：进程与看门狗）⇒ 同一份在 dash 与 **busybox ash** 上原样跑：

`@sh
dash tests/posix_smoke.sh          # 本机
busybox ash tests/posix_smoke.sh    # 设备侧的解释器（CI 的必需检查之一）
`@

判据有承重：脚本内做**变异自证**（把库的缺陷改坏 ⇒ 场景必须变红），
每处都带**形状守卫**（变异必须真的落到源码上，否则「断言没变」与
「缺陷没造回去」分不开）；bash 侧（`tests/test_posix_proc.sh`）再验一层
「把库的僵尸判定改坏 ⇒ 判据必须变红」。

## 与主库的关系

- POSIX 子集**不在 1.x 的兼容承诺面内**（见 `docs/COMPATIBILITY.md`）：
  主库公开函数的返回码与行为有承诺，POSIX 子集是附属实现。
- 两份代码**不共享实现**：主库用 bash 专有语法（数组、`printf -v`、作业控制），
  POSIX 子集用 POSIX 语法重写同一件事。改主库的行为，**不要**顺手改子集 ——
  那是另一份承诺。
- 子集的行为以 `lib/posix/shellkit-posix.sh` 的注释与 `tests/test_posix.sh` 为准。
