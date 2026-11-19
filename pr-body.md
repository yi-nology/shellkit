#146：生态里反复要重写两遍的运维骨架 —— git 的「正确姿势」（默认分支、脏仓守卫、
浅克隆取 tag、受控快进、worktree 检出）与裸进程的进程组 / 看门狗（后台引导、整组
停止、带退避的自愈）。每次重写都会重犯同一批错：硬编码 `main`（有的仓默认分支
是 `master`，报出来的却像网络问题）、不查脏仓就 pull（同机并行会话的工作被无声
冲掉）、浅克隆里版本退化成哈希（产物版本变成 devel）、只 kill 主进程（子进程残留、
端口还占着）、没有退避的重启（起来就崩 ⇒ 无限重启，把机器打满）。

交付两件：

1. **git 领域抽象 `lib/core/git.sh`**（7 个公开函数）——
   `git_default_branch`（origin/HEAD → origin/main|master → 远端单分支 ⇒ 它 →
   多分支且认不出 ⇒ 报歧义不猜）、`git_is_dirty`（脏仓守卫，未跟踪文件也算脏）、
   `git_tag`（浅克隆安全取 tag：精确 tag → 补取 tag → 补深度，三层回退）、
   `git_fetch`（受控取数，脏仓直接拒绝）、`git_fast_forward`（只快进、绝不丢本地
   提交）、`git_reset_hard`（显式的破坏性重置，名字里就写着 hard）、
   `git_worktree_add`（检出到工作树）。

2. **进程组 / 看门狗原语 `lib/core/proc.sh`**（4 个公开函数）——
   `proc_start`（脱离终端、作业控制自带进程组、原子写 pid 文件、日志追加、存活
   校验）、`proc_stop`（整组停止：先 TERM 留收尾时间，还活着就 KILL 整组）、
   `proc_is_running`（探活，僵尸 pid 文件会被清掉）、`proc_watchdog`（带退避的
   自愈：1→2→4… 翻倍，连续健康三个周期退避归零，`--max-restarts` 用尽则非 0 退出）。

**命名偏差（issue 点名 `svc_start` / `svc_stop`，交付的是 `proc_*`）**：
仓库里 `svc_*` 已经被 systemd/launchd 的「服务单元」语义占用（写 unit 文件、交给
服务管理器拉起）。issue 要的这一层管的是**裸进程** —— 设备侧启动脚本手写的
「nohup & + pid 文件 + 探活循环」。两层语义不同，名字不能混：复用 `svc_*` 等于
改掉既有调用方的行为，撞上仓库「0.x 内只加不改」的硬约束。因此新族命名为 `proc_*`，
模块头注释里写明了这个理由。

**独立审查发现并已修掉的缺陷**（都在本 PR 内修掉后才提）：

| 缺陷 | 位置 | 修法 |
|---|---|---|
| 快进合错分支还返回 0 | `git_fast_forward` | HEAD 不在目标分支上 ⇒ 明确报错（3）、不动工作树 |
| worktree 能建在仓内 | `git_worktree_add` | 用 `_sk_fs_in_dir` 判仓边界（工作树根 + 链接工作树的主仓根），仓内一律拒绝（3） |
| 组杀会把调用方一起杀掉 | `proc_stop` | 组杀前比较目标 pgid 与调用方自身 pgid（`ps -o pgid= -p $$`），相同就退化成只杀 pid |
| 能力清单漂移 | `lib/posix/capabilities.tsv` | `tools/check_posix.sh --write` 重生成 |
| 判据不承重 | 两个测试文件 | 补负对照 + 变异测试（见下） |

前三条的共同形状是**静默出错**：返回 0 却把事情做错了（合进别的分支、把工作树
建在仓里把自己锁死、把自己一起杀掉），比报错难查得多。

顺带修掉的次级项：`git_tag` 不再返回带 `-dirty` 的值（版本号要的是 tag 本身），
祖先 tag 的兜底写进文档；`__deepen` 收进 `local`（原来漏成全局变量）；`proc_start`
启动失败时整组清理（不留占端口的孤儿）；`proc_stop` 会等组内成员消失、停不掉时
如实返回 3（原来注释写 3、代码永远返回 0）；`proc_watchdog` 的 `--max-restarts`
不再双计数（一次失败被算成两次，上限少一半）；`--interval 0` / `--max-backoff 0`
被拒（0 秒间隔是热循环、0 秒退避是重启风暴）；`--help` 走 `_t`。

**判据承重**（`tests/test_git.sh`、`tests/test_proc.sh`）：新加的断言逐条做过变异 ——
造坏必须变红：

| 变异 | 结果 |
|---|---|
| `git_default_branch` 的 main/master 回退环改成空循环 | 红（main wins over master） |
| `git_fast_forward` 的「HEAD 是不是目标分支」改成 `if false` | 红（rc 3 ⇒ 0，且分支指针被改动） |
| `git_worktree_add` 的仓边界检查改成 `if false` | 红（rc 3 ⇒ 0，且主仓变脏） |
| `proc_stop` 排除「自己那个组」的判断去掉 | 红（调用方被自己组 SIGTERM 打死，SURVIVED 不打印） |
| `_sk_proc_alive` 的 `Z*` 僵尸分支去掉 | 红（真僵尸被判成活着） |
| `proc_watchdog` 的拉起调用改成 `if false` | 红（重启次数 0） |

僵尸那条用的是**真僵尸**（子进程退出、父亲还活着且不回收 ⇒ 进程表里留着 Z 态），
不是「pid 不存在」那种 —— 后者只测得到「没了」，测不到 Z 分支。

**边界（明说）**：两个模块都标了 `@stability experimental`，**不进 1.x 的兼容承诺面**
（`docs/API-FREEZE.md` 里列为 experimental）；`proc_*` **不进 POSIX 子集**（它依赖
bash 的作业控制 `set -m` 与 `ps` 的进程组字段，busybox ash 上没有 ——
`lib/posix/capabilities.tsv` 里逐条写着原因）；**没有改动任何既有函数的行为**。

环境相关的基线（覆盖率棘轮两棵树 + bench 计数基线）**在 ubuntu-latest 上重生成**
（与门禁同一个 runner）—— 本机是 macOS，基线不可移植。

Closes #146
