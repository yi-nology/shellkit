# 参与开发

## 门禁先跑起来

```bash
make check
```

全部步骤全绿才算过（清单的唯一真相源是 `Makefile` 的 `check` 目标）。单跑某一步：

```bash
bash tests/run.sh                   # 测试
./shellkit docs --check             # 生成物是否最新
bash tools/check_versions.sh        # 版本引用是否一致
bash tools/check_docs.sh            # 文档里的例子是否仍然成立
bash tools/check_module_order.sh    # 模块加载顺序与依赖声明
bash tools/check_exitcode_docs.sh   # 公开函数有没有写明返回码
bash tools/check_local_names.sh     # 出参保留名与命名空间
bash tools/check_pipe_safety.sh     # 管道早退（SIGPIPE + pipefail）
bash tools/check_security.sh        # 路径/软链/权限/脱敏/锁/原子写
bash tools/api_baseline.sh          # 公开 API 行为基线 + Stable 承诺
```

`make bats-check`、`make coverage`、`make mutation`、`make bench` 不进 `make check`：
它们要么依赖外部工具（bats），要么要跑好几遍套件 —— CI 里有单独的 job/步骤。

## 加一个模块要改三处，少一处就红

1. 写 `lib/core/<name>.sh`：公开函数上方**必须**紧邻注释行（`docs-check` 会拦），
   而且要写明返回码（`check-exitcode-docs` 会拦）。
2. 在 `lib/modules.txt` 里加一行 —— 这是模块清单的**唯一真相源**：
   `lib/bootstrap.sh` 按它加载，`tools/shdoc.sh` 按它生成 API 参考，站点也按它同步。
   两列：**第一列模块名，第二列它依赖的模块**（空格分隔，可以不写）。
   按**依赖拓扑序**放，不是字母序；依赖漏写或顺序颠倒，`module-order-check` 会直接指出
   「哪个模块调用了还没加载的函数」或「哪个依赖没声明」。
3. 写 `tests/test_<name>.sh`：文件名被 `tests/test_*.sh` 通配到就自动执行。

`@internal` 标记的函数不导出，也不参与注释覆盖检查；内部函数名以下划线开头
（`_sk_*`）同样不参与。

## 改既有函数要单独提版本

0.x 内只加不改。改动会改变结果（返回码、产出文件名、输出文本）时：

1. 单独一个版本号（比如 0.6.0 → 0.7.0）；
2. 在 `docs/MIGRATING.md` 加一张「会改变结果的行为变化」表；
3. 说明旧行为、新行为、以及调用方要怎么改。

只加不改的改动可以走 patch。

## 发版

```bash
make release-dry VERSION=x.y.z
make release VERSION=x.y.z
```

第一条空跑：升版本 → 重生成 pot 与文档 → 同步首页版本引用 → 跑门禁 → **还原工作树**。
第二条真发：commit、打 tag、push，tag 触发 release 工作流。细节见 [发版](./releasing.md)。

## 文档

| 你改了什么 | 要跑什么 |
| --- | --- |
| 公开函数的注释 | `./shellkit docs`（重生成 REFERENCE 与三份 AI 契约） |
| 加了 msgid | `bash po/messages.sh` |
| 站点页面 | `cd site && npm run build`（会自动先同步 `docs/`） |
| README 里的例子 | 不用手动同步，`check-docs` 会验证 |

`docs/` 是唯一真相源：站点的 Cookbook、迁移、发版与 API 参考都由 `tools/site_sync.sh`
从 `docs/` 生成，不要在 `site/` 里改那几页 —— 下次构建会被覆盖。

## 提交

- 一个提交做一件事。修 bug 与改文档不要混在一起。
- 提交信息写「为什么」，不是「改了什么」—— 「改了什么」看 diff 就知道。
- 需要证明的行为变化，把真实命令与输出贴进提交体或 PR 描述。
