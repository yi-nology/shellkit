## 交付说明（PR 已合并）

按 issue 的两块骨架都已落地：

**1. git 领域抽象**（`lib/core/git.sh`）

| 函数 | 作用 |
|---|---|
| `git_default_branch` | 解析默认分支（origin/HEAD → origin/main|master → 远端单分支 ⇒ 它 → 多分支 ⇒ 报歧义不猜） |
| `git_is_dirty` | 脏仓守卫（未跟踪文件也算脏） |
| `git_tag` | 浅克隆安全取 tag（三层回退：精确 tag → 补取 tag → 补深度） |
| `git_fetch` | 受控取数（脏仓直接拒绝） |
| `git_fast_forward` | 只快进、绝不丢本地提交；HEAD 不在目标分支上就明确报错 |
| `git_reset_hard` | 显式的破坏性重置（名字里就写着 hard） |
| `git_worktree_add` | 检出到工作树（仓内路径一律拒绝） |

**2. 进程组 / 看门狗原语**（`lib/core/proc.sh`）

| 函数 | 作用 |
|---|---|
| `proc_start` | 后台引导：脱离终端、自带进程组、原子写 pid 文件、日志追加、存活校验 |
| `proc_stop` | 整组停止（TERM → KILL，等组内成员消失；停不掉时返回 3） |
| `proc_is_running` | 探活（僵尸 pid 文件会被清掉） |
| `proc_watchdog` | 带退避的自愈（1→2→4…，连续健康 3 周期归零，`--max-restarts` 用尽则非 0 退出） |

### 关于命名：issue 里写的是 `svc_start` / `svc_stop`，交付的是 `proc_*`

仓库里 `svc_*` 已经被 systemd/launchd 的「服务单元」语义占用（写 unit 文件、交给服务管理器拉起）。issue 要的这两块里，「进程组 / 看门狗」这一层管的是**裸进程** —— 设备侧启动脚本手写的「nohup & + pid 文件 + 探活循环」。两层语义不同，名字不能混：复用 `svc_*` 等于改掉既有调用方的行为，撞上仓库「只加不改」的硬约束。因此新族命名为 `proc_*`，模块头注释里写明了理由。

### 边界

- 两个模块都标了 `@stability experimental`，**不进 1.x 承诺面**（`docs/API-FREEZE.md` 里列为 experimental）。
- `proc_*` **不进 POSIX 子集**：它依赖 bash 的作业控制（`set -m`）与 `ps` 的进程组字段，busybox ash 上没有 —— 能力清单 `lib/posix/capabilities.tsv` 里逐条写着原因。
- 没有改动任何既有函数的行为。
