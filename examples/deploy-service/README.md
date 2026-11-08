# deploy-service：一个像样的部署脚本

演示四件事怎么拼起来，而不是四个孤立的 API：

1. **单实例锁**：两个部署进程不会同时写同一个单元文件。
2. **原子写**：中断时不会留下半个 `.service` 文件让 systemd 读到。
3. **幂等**：`deploy web` 跑一百遍和跑一遍结果一样。
4. **stdout 只给数据**：`state=$(deploy-service status web)` 拿到的是 `installed`，
   不混日志。

## 跑起来

```bash
DEPLOY_ROOT=/tmp/units ./bin/deploy-service deploy web
DEPLOY_ROOT=/tmp/units ./bin/deploy-service status web
make test
```

`DEPLOY_ROOT` 把落点从 `/etc/systemd/system` 挪到别处 —— 测试正是靠它做到不碰真实系统。
这个「落点可注入」的写法值得照抄：否则所有涉及 `/etc` 的脚本都没法测。

## 加一个子命令

在 `commands/` 下新建文件，写 `cmd_<name>()`，末尾加一行 `cli_cmd <name> "描述"`。
入口不用改：它按 `commands/*.sh` 全量加载，分发改由 `cli_run` 查函数名完成。

## 拿走用

这个示例从仓库里加载库（相对路径 `../../../lib/bootstrap.sh`），这样仓库里不用躺第二份
副本。真要拿去用：

```bash
cd /path/to/your-project
shellkit vendor .
```

然后把 `bin/deploy-service` 里那行 `.` 改成：

```bash
. "$(cd "$(dirname "$0")/.." && pwd)/vendor/shellkit/lib/bootstrap.sh"
```
