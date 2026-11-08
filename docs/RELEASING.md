# 发版

发版这件事在本仓库里不是「改个版本号再打个 tag」——它要同时动六个地方，其中三处是手抄的。
所以它是一条命令，而且这条命令自己复盘。

## 一条命令

```bash
make release VERSION=0.6.0            # 发：升版本 → 重生成 → 门禁 → commit → tag → push
make release-dry VERSION=0.6.0        # 同一条路径，但跑完还原工作树、不提交不推
bash tools/release.sh 0.6.0 --no-push # 本地提交与打 tag，推远端留给你自己
```

三种用法走的是同一段代码，所以 `release-dry` 通过就等于 `release` 也能过 —— 差别只在最后两步。
**第一次发新版本号时先跑 `release-dry`。**

## 它按顺序做什么

| 步骤 | 动作 | 失败时 |
|---|---|---|
| 1 | 校验版本号格式 `x.y.z`、必须大于当前 `VERSION` | `2` |
| 2 | 必须站在 `main`、工作树干净、`v<version>` 未被占用、有 `xgettext` | `3` |
| 3 | 写 `VERSION` | — |
| 4 | `bash po/messages.sh`：重抽 pot，头部 `Project-Id-Version` 跟着走 | `1` |
| 5 | `./shellkit docs`：重生成 REFERENCE / AGENTS / 模板 AGENTS / SKILL | `1` |
| 6 | 同步 README 与站点里的钉版本示例、下载按钮 | `3` |
| 7 | `bash tools/check_versions.sh` | `5` |
| 8 | `make check`（八个门） | `5` |
| 9 | `git commit -m "chore(release): x.y.z"` + `git tag -a vx.y.z` | `1` |
| 10 | `git push origin main` + `git push origin vx.y.z` | `1` |

第 3 步失败时（脏工作树、分支不对、tag 已存在）**一个文件都不会被改**，这是刻意的：
发版脚本最不该做的事是「改了一半然后停」。

一个容易踩的坑：`make release VERSION=x.y.z` 会让 make 把 `VERSION` **导出**给 recipe 的子进程，
而 `install.sh` 把环境变量 `VERSION` 解释成「装这个版本」。不处理的话，发版时的
`make check` 里	extbf{测试}跑到的 `install.sh` 会去下载一个还没发布的版本，报网络错 `4`。
所以 `tools/release.sh` 一开始就 `unset VERSION` —— 它只从 `VERSION` 文件读版本。


## 版本号出现的六处

`VERSION` 是唯一真相源，其余全是投影，而投影是手抄的：

    VERSION                              真相源，且被 release.yml 用来校验 tag 与包名
    locale/shellkit.pot  的 Project-Id-Version 头
    README.md            的 VERSION=x.y.z 钉版本示例
    site/index.html      的「下载 x.y.z」按钮
    site/index.html      的 VERSION=x.y.z 钉版本示例
    docs/shots/*.svg     截图里若出现版本号，由 make shots 重新渲染

前五处由 `tools/check_versions.sh` 逐项复查（`make versions-check`，已并入 `make check`）。
它用「精确等于 `VERSION`」判定，而不是「看起来像版本号」—— 所以漏改一处必然红。

`site/index.html` 里还有 `3.2.57` 这种与项目版本无关的串（那是 bash 版本），
所以检查用的是带上下文的模式（`VERSION=` 与 `下载 `），不是裸版本号。

## 发布之后必须自己验一遍

CI 绿了不等于用户装得上。这四个动作是发版的验收标准：

```bash
# 1. release 工作流跑完了吗
gh run list --workflow=release.yml --limit 1

# 2. 三个资产都在吗
gh release view v0.6.0 --json tagName,isDraft,isPrerelease,assets

# 3. 下载校验和 + 装一遍 + 自检
work=$(mktemp -d)
curl -fsSLO --output-dir "$work" \
  https://github.com/yi-nology/shellkit/releases/download/v0.6.0/SHA256SUMS
curl -fsSLO --output-dir "$work" \
  https://github.com/yi-nology/shellkit/releases/download/v0.6.0/shellkit-0.6.0.tar.gz
(cd "$work" && shasum -a 256 -c SHA256SUMS)

# 4. 装好的副本能干活：版本、自检、文档产物、生成工程能跑测试
curl -fsSL https://github.com/yi-nology/shellkit/releases/latest/download/install.sh \
  | PREFIX="$work/prefix" bash
"$work/prefix/bin/shellkit" --version
"$work/prefix/bin/shellkit" doctor
"$work/prefix/bin/shellkit" docs --check
"$work/prefix/bin/shellkit" new "$work/demo" --cmd start
(cd "$work/demo" && make test)
```

最后一步是 0.6.0 才装得上的：`install-self` 以前不装 `tests/`，装好的副本 `new` 出来的工程
`make test` 必然 127。**这条别跳。**

## CI 那一半：release.yml

`v*` tag 推上去就触发，别再手工 `gh release create`：

1. 校验 tag 与 `VERSION` 一致（不一致直接失败，避免发出去一个版本号对不上的包）
2. 打包 `shellkit-<version>.tar.gz`，同时生成 `SHA256SUMS`
3. **在解包后的产物里**跑 `tests/run.sh`、`doctor`、`new` + `make test` —— 验的是发出去的东西，
   不是工作树
4. `gh release create --generate-notes`，三个资产：tar.gz、SHA256SUMS、install.sh

`install.sh` 也作为资产发布，因为 `releases/latest/download/install.sh` 是稳定地址，
而 `raw.githubusercontent.com` 在部分网络会被重置。

## 语义变化必须单独提版本

仓库的硬约束是「0.x 内只加不改」。所以：

- **只加函数/加开关** → patch 版即可（0.5.0 → 0.5.1）。
- **改了既有函数的结果**（返回值、退出码、产出文件名、输出文本）→ **必须升 minor**
  （0.5.0 → 0.6.0），并在 `docs/MIGRATING.md` 里加一张「会改变结果的行为变化」表。

写那张表的判据不是「我改了哪些行」，而是**「别人的判据会怎么变」**：退出码从 1 变成 2、
备份文件名多了后缀、锁被回收得更早 —— 这些都会让别人的断言或正则失效。写完再问一遍：
「升级后我自己跑一遍这七条，能不能一眼看出哪条红了？」

## 回滚

发出去的版本不能收回（别人已经装上了），只能往前补：

```bash
git log --oneline -3               # 找到那个坏提交
git revert --no-edit HEAD          # 生成反向提交
make release VERSION=0.6.1
```

如果只是资产有问题（少文件、校验和不符）：修好源码，重新发一个 patch 版本，
再用 `gh release delete v0.6.0 --yes` 把坏版本撤下来。**不要改已发布 tag 的内容** ——
校验和已经流到别人的 CI 里了。

## 为什么不做「手工五步」

版本号、pot 头、README、站点按钮、站点示例，五处都是手抄的。漏一处不会报错：

- 网页上的下载按钮还挂着上一版（用户点了装到旧版）；
- README 教人 `VERSION=0.5.0 bash`（钉住的是有缺陷的版本）；
- pot 头落后（翻译工作流读到旧版本号，`messages-check` 因为 strip 掉头部而不报警）。

这三件事在门禁全绿的情况下可以同时成立。`versions-check` 存在的唯一理由就是把它们变成红的。
