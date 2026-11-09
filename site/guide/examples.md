# 示例工程

两个能直接跑的完整工程。演示的是**装配**，不是把库再实现一遍。

## deploy-service：幂等安装 systemd 单元

[examples/deploy-service](https://github.com/yi-nology/shellkit/tree/main/examples/deploy-service)

要做的事：写一个 unit 文件、启用它、重启服务，重复执行不产生副作用。

```text
examples/deploy-service/
├─ bin/deploy-service
├─ lib/app.sh
├─ commands/install.sh
├─ commands/status.sh
├─ tests/test_deploy.sh
└─ vendor/shellkit/
```

三个关键点：

1. **落点用变量注入**，所以测试完全不碰真实系统目录：

   ```bash
   DEPLOY_ROOT=${DEPLOY_ROOT:-/}
   dest="$DEPLOY_ROOT/etc/systemd/system/app.service"
   fs_atomic_write "$dest" "$unit" 644
   ```

2. **幂等靠内容比对**，不靠「先删再建」。内容没变就不写，`systemctl` 也不重启 ——
   否则每次跑都重启一次服务，这在生产上是事故。
3. **stdout 只给数据**：`status` 子命令输出机器可读的一行，日志走 stderr。

跑它的测试：

```bash
bash examples/deploy-service/tests/test_deploy.sh
```

## fetch-release：下载、校验、原子切换

[examples/fetch-release](https://github.com/yi-nology/shellkit/tree/main/examples/fetch-release)

要做的事：从上游拿一个包 → 校验 sha256 → 解开 → 原子切换软链 → 保留上一版用于回滚。

三个关键点：

1. `net_download URL DEST SHA256` 自带缓存校验：本地已有且哈希对得上就不再下载。
2. 上游用 `file://`，所以测试**完全离线**，不依赖任何外网。
3. 切换用 `fs_ensure_symlink`：它是原子的，且**绝不覆盖普通文件** —— 如果目标位置是个
   真实目录而不是软链，它报错而不是删掉重来。

```bash
bash examples/fetch-release/tests/test_fetch.sh
```

## 为什么测试走真实二进制

这两个工程的测试**不 source 内部函数**，而是执行 `bin/<name>`，按退出码和 stdout 断言。
理由：source 内部函数测的是「函数按我预期实现」，执行二进制测的是「用户拿到的行为」。
后者才会发现「子命令注册漏了」「入口脚本没找到 vendor/」这类问题。

想看更多场景，[Cookbook](./cookbook.md) 有二十二个，每节都是「场景 / 代码 / 为什么」。
