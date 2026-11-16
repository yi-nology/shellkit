# 发版

发版不是「改个版本号再打个 tag」：版本号散在五个文件、九处引用里，而它们全是手抄的；
发布资产还要先建成 draft、独立验签、通过之后才对外可见。所以它是一条命令 + 一条流水线。

## 一条命令

```bash
make release VERSION=x.y.z            # 发：升版本 → 重生成 → 门禁 → commit → tag → push
make release-dry VERSION=x.y.z        # 同一条路径，但跑完还原工作树、不提交不推
bash tools/release.sh x.y.z --no-push # 本地提交与打 tag，推远端留给你自己
```

三种用法走的是同一段代码，所以 `release-dry` 通过就等于 `release` 也能过 —— 差别只在最后两步。
**第一次发新版本号时先跑 `release-dry`。**

## 它按顺序做什么

| 步骤 | 动作 | 失败时 |
|---|---|---|
| 1 | 校验版本号格式 `x.y.z`、必须大于当前 `VERSION` | `2` |
| 2 | 必须站在 `main`、工作树干净、`v<version>` 未被占用、有 `xgettext` | `3` |
| 3 | 写 `VERSION` | — |
| 4 | 从 `git log` 生成 `CHANGELOG.md` 条目（不手写，手写的必然和 git 历史对不上） | `1` |
| 5 | `bash po/messages.sh`：重抽 pot，头部 `Project-Id-Version` 跟着走 | `1` |
| 6 | `./shellkit docs`：重生成 REFERENCE / AGENTS / 模板 AGENTS / SKILL | `1` |
| 7 | 同步 README 与站点里的钉版本示例、下载按钮（5 个文件 9 处引用） | `3` |
| 8 | `bash tools/check_versions.sh`：漏改一处就红 | `5` |
| 9 | `make check`：全部门禁 | `5` |
| 10 | `git commit -m "chore(release): x.y.z"` + `git tag -a vx.y.z` | `1` |
| 11 | `git push origin main` + `git push origin vx.y.z`（`--no-push` 时只打印命令） | `1` |

第 1、2 步失败时**一个文件都不会被改**：发版脚本最不该做的事是「改了一半然后停」。
`make check` 失败时会 `git checkout -- .` 把工作树还原。

一个容易踩的坑：`make release VERSION=x.y.z` 会让 make 把 `VERSION` **导出**给 recipe 的子进程，
而 `install.sh` 把环境变量 `VERSION` 解释成「装这个版本」。不处理的话，发版时的
`make check` 里**测试**跑到的 `install.sh` 会去下载一个还没发布的版本，报网络错 `4`。
而且光 `unset` 不够：子 make 会从 `MAKEFLAGS` 里把 `VERSION=x.y.z` 重新装回来。
所以 `tools/release.sh` 先 `unset VERSION`，再用 `env -u VERSION -u MAKEFLAGS -u MFLAGS make check`
跑门禁 —— 它只从 `VERSION` 文件读版本。

## 版本号出现在哪里

`VERSION` 是唯一真相源，其余全是投影，而投影是手抄的：

    VERSION                              真相源，且被 release.yml 用来校验 tag 与包名
    locale/shellkit.pot  的 Project-Id-Version 头
    CHANGELOG.md         由 git log 生成（不手抄）
    README.md            的 VERSION=x.y.z 钉版本示例
    site/index.md        的「下载 x.y.z」按钮 + 钉版本示例
    site/en/index.md     的「Download x.y.z」按钮 + 钉版本示例
    site/guide/installation.md        的 VERSION=x.y.z 示例 + 包名
    site/en/guide/installation.md     的 VERSION=x.y.z 示例 + 包名
    docs/shots/*.svg     截图里出现的版本号，由 make shots 重新渲染

`tools/check_versions.sh` 逐项复查除截图外的九处引用（`make versions-check`，已并入 `make check`）。
它用「精确等于 `VERSION`」判定，而不是「看起来像版本号」—— 所以漏改一处必然红。
`tools/site_links.sh` 在构建产物上再查一遍首页的版本串，拦住「源码对了但没重建」。

首页里还有 `3.2.57` 这种与项目版本无关的串（那是 bash 版本），
所以检查用的是带上下文的模式（`VERSION=` 与 `下载 ` / `Download `），不是裸版本号。

## CI 那一半：release.yml

`v*` tag 推上去就触发，别手工 `gh release create`。顺序是固定的：

0. **质量准入** `tools/release_gate.sh`：查询被 tag 的那个 SHA 上的必需检查，
   失败、缺席、未完成都不放行。**被 runner 取消的检查会自动重跑一次**
   （从 check-run 的 `details_url` 取 run id，请求 `gh run rerun --failed`）；
   重跑后仍被取消 ⇒ 按失败处理（fail-closed）。`--no-rerun` 可关掉自动重跑。
   判据在 `tests/test_release_gate_cancelled.sh`；
1. **tag 与 `VERSION` 一致** —— 不一致直接失败，避免发出一个版本号对不上的包；
2. **打包** `tools/package_tarball.sh`：打包清单只维护一份（`release.yml` 与 `packages.yml` 共用）；
3. **验真产物** `tools/package_artifact_smoke.sh`：解包后跑整套 `tests/run.sh` + CLI 三连 ——
   PR 阶段 `ci.yml` 的 artifact job 调的是同一个脚本，两边不可能漂移；
4. **装 minisign**：ubuntu runner 默认没有。凡是调用 `sign_release.sh` 的 job，**必须在同一 job 内先装它**
   （`tests/test_release_signing_tool.sh` 盯着这条规则 —— v0.21.0 与 v0.26.0 都在这上面栽过）；
5. **签名** `bash tools/sign_release.sh --dist dist --require`：正式发布必须签名，
   没配私钥直接以 `3` 失败，不产出「看起来一样、其实没签」的发行版；
6. **核对钉入公钥** `tools/check_trust_pin.sh`：`docs/TRUST.md`「当前公钥」与本次签名钥不一致就中止；
7. **建 draft release**：13 项资产 —— 6 份内容（tarball / skill 包 / `SHA256SUMS` / `install.sh` /
   `repair.sh` / `demo.sh`）+ 6 份 `.minisig` + `shellkit.minisign.pub`。
   上传走 `tools/release_assets.sh`（不可变：同摘要跳过、异摘要拒绝覆盖）；
8. **独立验签** `bash tools/verify_release.sh <tag>`：从 draft 重新取回资产，用 TRUST.md 钉住的公钥
   逐份验签并与 `SHA256SUMS` 对账 —— 只在 `dist/` 上验签证明不了「用户下载到的那份」是对的。
   draft 还没对外可见，所以这一步失败时用户什么都看不到；
9. **公开** `gh release edit <tag> --draft=false --latest`：验签过了才轮到它。
   判据在 `tests/test_release_publish_order.sh`：去掉 `--draft`、把验签与公开对调，用例必须红；
10. **发布后自检** `tools/release_selfcheck.sh <tag> --require-packages`：等 `packages` 跑完，
    对着已发布的 Release 逐项点名（主资产、每份 `.minisig`、`.deb` / `.rpm`），
    缺一个就红。这一步**不可选**（不带 `continue-on-error`），专门堵住
    「可选 job 失败被吞掉、run 仍显示绿色」的静默缺口。

### 可选 job：deb / rpm

`packages` job 基于**已发布**的 tarball 打 deb/rpm（下载资产 → 对 `SHA256SUMS` → 打包 → 冒烟）、
用 `--file` 点名补签、再不可变上传。它本身是 `continue-on-error: true`，
所以**这个 job 红了不会挡发布**；但 `release.yml` 里有一个不可选的 `self-check` job
等它跑完，用 `tools/release_selfcheck.sh --require-packages` 检查资产清单 ——
缺包时整条 run 是红的，不会再出现「全绿但没有 deb/rpm」。仍然建议亲眼看一遍：

```bash
gh run view <run-id> --json jobs --jq '.jobs[] | [.name,.conclusion] | @tsv'
gh release view "v$version" --json assets --jq '.assets[].name'
```

上面第二条里没有 `shellkit-<ver>.deb` / `.rpm` ⇒ 这一版没带系统包（tarball 路径不受影响）。
v0.26.0 与 v0.26.1 都栽在这里，两次原因不同：前者是 job 没装 minisign（`exit 3`），
后者是 `--file` 补签仍在要求「`SHA256SUMS` 整份齐全」（`SHA256SUMS lists a missing file`）——
后者已在 main 修（点名模式跳过整份清单枚举），随下一版恢复系统包。

## 发布前：连续三次全矩阵绿

跨版本升级矩阵（`tools/upgrade_matrix.sh`）每天只跑一遍，一次绿证明不了稳定：
它可能刚好赶上网络好、机器闲。**v1.0.0 起**，正式发布前要求在空闲机器上连续跑三次全绿，
把三份 `summary` 行贴进发布 PR / issue 作为证据：

```bash
for i in 1 2 3; do
  echo "== run $i"
  bash tools/upgrade_matrix.sh --strict || { echo "run $i failed"; exit 1; }
done
```

每次的判据是同一组：`0.20.0 / 0.23.0 / 0.24.1 / 0.26.2 → 当前` 全部 `passed`，
且每个版本还跑完一圈 `install → uninstall → reinstall → upgrade` 的 lifecycle。
出现 `SKIP` 不算通过（`--strict` 会让「全部跳过」直接失败）；
真离网时先解决网络，而不是把跳过当绿。

> 为什么是三次：这个矩阵证明的是「老工程能被新版本接住」，
> 而它依赖外部 Release 资产与网络路径 —— 一次通过可能只是一次运气。
> 三次连续通过才值得写进发布说明。

## 迟到的资产：--file 补签

发布之后才打出来的资产（deb/rpm、镜像清单）用点名补签，不要重跑整份签名：

```bash
bash tools/sign_release.sh --dist dist --require \
  --file "dist/shellkit-$version.deb" --file "dist/shellkit-$version.rpm"

bash tools/release_assets.sh "v$version" \
  "dist/shellkit-$version.deb" "dist/shellkit-$version.deb.minisig" \
  "dist/shellkit-$version.rpm" "dist/shellkit-$version.rpm.minisig"
```

点名模式**只签点名的文件**（不会顺手重签 `SHA256SUMS` 与 `install.sh`），
也不再要求清单里其他文件在本地存在 —— 补签场景下 `dist/` 里天然只有一部分资产。
没配私钥时 `--require` 直接失败：宁可不附加，也不发布无签名的系统包。

## 发布之后必须自己验一遍

CI 绿了不等于用户装得上。这四个动作是发版的验收标准：

```bash
# 1) release 工作流跑完了吗（含可选的 packages job）
gh run list --workflow=release.yml --limit 1

# 2) draft 已公开、资产齐全（脚本点名，缺一份就非 0）
gh release view "v$version" --json tagName,isDraft,isPrerelease,assets
bash tools/release_selfcheck.sh "v$version" --require-packages

# 3) 从 Release 重新取回资产，用 TRUST.md 钉住的公钥逐份验签 + 对 SHA256SUMS
bash tools/verify_release.sh "v$version"

# 4) 装一遍 + 生成工程 + 跑工程自己的测试
work=$(mktemp -d)
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

## 发布之后：Homebrew tap 要跟上

tap 仓是 [yi-nology/homebrew-shellkit](https://github.com/yi-nology/homebrew-shellkit)，
里面只有一个 `Formula/shellkit.rb`。它钉死了版本号与 sha256，而**发布完不会自动更新** ——
得手工回填一次（Homebrew 要求逐字节一致，早填必错）：

```bash
version=0.26.1
gh release download "v$version" --repo yi-nology/shellkit \
  --pattern SHA256SUMS --dir "/tmp/sk-$version" --clobber
sha=$(awk -v n="shellkit-$version.tar.gz" '$2==n{print $1}' "/tmp/sk-$version/SHA256SUMS")
[ -n "$sha" ] || { echo "no checksum for the tarball in SHA256SUMS"; exit 1; }

bash tools/brew_formula.sh --out /tmp/shellkit-tap/Formula/shellkit.rb \
  --version "$version" --sha256 "$sha"

cd /tmp/shellkit-tap && git add -A \
  && git commit -m "feat: shellkit $version formula" \
  && git push origin HEAD
```

回填完验一下：`brew install yi-nology/shellkit/shellkit` 能装上，
且 `shellkit --version` 报的就是这个版本号。

## 语义变化必须单独提版本

仓库的硬约束是「0.x 内只加不改」。所以：

- **只加函数/加开关** → patch 版即可（0.5.0 → 0.5.1）。
- **改了既有函数的结果**（返回值、退出码、产出文件名、输出文本）→ **必须升 minor**
  （0.5.0 → 0.6.0），并在 `docs/MIGRATING.md` 里加一张「会改变结果的行为变化」表。

写那张表的判据不是「我改了哪些行」，而是**「别人的判据会怎么变」**：退出码从 1 变成 2、
备份文件名多了后缀、锁被回收得更早 —— 这些都会让别人的断言或正则失效。写完再问一遍：
「升级后我自己跑一遍这七条，能不能一眼看出哪条红了？」

Stable API 的行为变化由门禁兜底：`tools/api_baseline.sh` 会比对返回码集合与 Stable 集合，
没写进 MIGRATING 就红。

## 回滚

发出去的版本不能收回（别人已经装上了），只能往前补：

```bash
git log --oneline -3               # 找到那个坏提交
git revert --no-edit HEAD          # 生成反向提交
make release VERSION=x.y.z         # 补一个 patch 版本
```

如果只是资产有问题（少文件、校验和不符）：修好源码，重新发一个 patch 版本，
再用 `gh release delete v<坏版本> --yes` 把坏版本撤下来。**不要改已发布 tag 的内容** ——
校验和已经流到别人的 CI 里了。

## 为什么不做「手工五步」

版本号、pot 头、README、站点按钮、站点示例，都散在手抄的位置上。漏一处不会报错：

- 网页上的下载按钮还挂着上一版（用户点了装到旧版）；
- README 教人 `VERSION=0.5.0 bash`（钉住的是有缺陷的版本）；
- pot 头落后（翻译工作流读到旧版本号，`messages-check` 因为 strip 掉头部而不报警）。

这三件事在门禁全绿的情况下可以同时成立。`versions-check` 存在的唯一理由就是把它们变成红的。
