# 参与开发

## 门禁先跑起来

```bash
make check
```

九步全绿才算过。单跑某一步：

```bash
bash tests/run.sh
./shellkit docs --check
bash tools/check_versions.sh
bash tools/check_docs.sh
```

## 加一个模块要改四处，少一处就红

1. 写 `lib/core/<name>.sh`：公开函数上方**必须**紧邻注释行（`docs-check` 会拦）。
2. `lib/bootstrap.sh` 的模块序列里插入 —— **按依赖拓扑序**，不是字母序。
3. `tools/shdoc.sh` 的 `MODULES` 里加同一位置（两处顺序必须一致）。
4. 写 `tests/test_<name>.sh`：文件名被 `tests/test_*.sh` 通配到就自动执行。

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
