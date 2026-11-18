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

## 发版窗口：`main` 会在你跑门禁时前进

`make release` 里最长的一步是 `make check`（本机约 30–40 分钟，CI runner 也接近这个量级）。
这段时间里**别的 PR 可能合进 `main`** —— 而脚本最后一步才 push。窗口足够长，就不是理论风险：

> **2026-11-17 / v0.27.0 的实际事故**：第一次发版，改版本、重生成、门禁全绿，
> 本地已经建好 `chore(release): 0.27.0` 与 `v0.27.0` tag；`git push origin main`
> 被拒（`! [rejected] HEAD -> main (fetch first)`）—— 窗口内 PR #132 合入了 `main`。
> 当时 **tag 没推出去、Release 没产生**，所以只是本地多了一次提交，没有任何对外影响。

### 恢复步骤（不要 rebase，重跑）

```bash
git tag -d vx.y.z                  # 本地 tag 必须先删，否则重跑时第 2 步会判「tag 已占用」
git reset --hard origin/main      # 丢掉本地那次 chore(release) 提交
git pull --ff-only origin main
make release VERSION=x.y.z        # 重跑：CHANGELOG / pot / 文档按新 base 重新生成
```

**为什么不 rebase**：`CHANGELOG.md` 是从 `git log` 生成的。rebase 只会把那一次提交挪到新 base 上，
窗口内合入的 PR **不会进 changelog**（发布说明会漏条目），而重跑会按新历史重新生成。

### 缩短窗口：`--no-push`

`tools/release.sh` 支持 `--no-push`：门禁跑完只做本地 commit + tag，把两条 push 命令打印出来。
你确认远端没动之后立刻推，竞态窗口从「整个 make check」缩到秒级：

```bash
bash tools/release.sh x.y.z --no-push   # 门禁 + commit + tag，不推
git push origin main                     # 先推主线
git push origin vx.y.z                   # 再推 tag：release.yml 由 tag 触发
gh run list --workflow=release.yml --limit 1
```

推 tag 前顺手看一眼 `git log --oneline origin/main -3` 是不是你本地的那条 `chore(release)`；
不是就先回到上面的恢复步骤，**不要** `git push --force` 到 `main`。

### 判据在哪

- `tools/release.sh` 第 2 步：`v<version>` 已存在 ⇒ 退 `3`（所以恢复必须先删本地 tag）；
- 第 11 步 push 失败 ⇒ 整个发版退 `1`，**不会**留下半个 Release（tag 没推 = `release.yml` 没被触发）；
- 发布之后用 `gh release view "v$version" --json isDraft,assets` 与
  `bash tools/release_selfcheck.sh "v$version" --require-packages` 确认资产真的在。

## 发版窗口：2026-11-18 / v1.1.0 —— 一次发布，四次连环事故

这一版发得不顺。四次事故串在一起，每一次的根因都不是「运气不好」，而是**每一步都少了一条判据**：

1. **一个空格让 CI 全矩阵红**。新增的 `tests/test_changelog_prev.sh` 有一行 shfmt 不合规
   （`( cmd )` vs `(cmd)`）⇒ `make fmt` 红 ⇒ macOS / Ubuntu / compat 五个 job 全红。
   本地空演跑在**这个提交之前**，所以本地绿、CI 红。
   ⇒ **纪律：改动落地前，本地 `make check` 必须跑过这个提交** —— 哪怕只新增了一个文件。

2. **openeuler 的 compat job 被 40 分钟的 job 总超时砍掉** —— 砍掉的是「装包慢」
   （容器里 `dnf install` 花了 39 分钟），不是「卡死」。tag 已经推了，但门禁 fail-closed
   ⇒ **没有产生 Release**（行为正确：对外可见的半成品比没有发布糟糕得多）。

3. **修超时修出新问题**。内层超时先取 900 秒，但同一批共享 runner 上实测过**合法**的
   慢安装 1069 秒（17 分 49 秒）—— 900 秒会把「慢但没卡死」误杀成失败。
   ⇒ 改成 1800 秒，并补 `tests/test_ci_timeouts.sh`：内层超时不得短于实测最慢装包，
   也不得把 job 的总预算吃光。**手抄的超时数必须有判据盯着**，否则下次改 CI 又抄错。

4. **发布门禁的 40 分钟等待窗口险些不够**。质量门禁从 08:18 等到 08:55（37 分钟）
   才放行，慢的那一格是 coverage ratchet。
   ⇒ 窗口不够时的处置：`gh run rerun <release_run_id> --failed` —— 此时检查已经绿了，
   门禁立即放行。

### 尚无 Release 对象时：删 tag 重打

tag `v1.1.0` 最初指向一个不含 #142 / #143 与格式修复的提交。远端**没有 Release 对象**
（`gh release view v1.1.0` → not found）⇒ 此时删 tag、重打不会留下对外可见的半成品：

```bash
git push origin :refs/tags/v1.1.0     # 删远端 tag（没有 Release 对象才允许）
git tag -f -a v1.1.0 NEW_SHA -m 'shellkit 1.1.0'
git push origin v1.1.0                # 重新推 ⇒ release.yml 由 tag 触发，重新走门禁
```

**前提是先确认没有 Release 对象**。有对象时删 tag：Release 页面仍在（对象与 tag 是分离的），
但它指向的 tag 已经变了 ⇒ 页面上的「Source」指向新提交、资产却还是旧的 —— 那比慢发布糟糕得多。

### 共享工作树里，分支会被别的会话动

同一次发版里另一个会话在同一工作树把分支从 `main` 切到了它自己的 feature 分支 ⇒
那次「修格式」的提交因此落到了**它的分支**上（HEAD 已经不是 main），而 `git status` 当时还是干净的。
⇒ 提交前先确认 `git rev-parse --abbrev-ref HEAD`；发现分支被别人动过就**用独立 worktree**
（`git worktree add --detach`）做自己的提交 —— 不要在共享工作树里切分支：切分支会把别人
正在写的分支从他们脚下抽走。

## `main` 的保护规则（2026-11-18 起）

`main` 现在带分支保护（branch protection）。规则刻意与仓库自己的发布门禁**同一份清单**：

- **必需检查**：15 个 = `tools/release_gate.sh` 的 `DEFAULT_CHECKS`（ci.yml 的 job 名逐字一致）；
- **`strict: false`**：检查不要求在 base 分支最新提交上重跑 —— `main` 在发版窗口里经常前进，
  开了 strict 会把每个 PR 都卡成 BLOCKED（与上面「发版窗口」一节是同一个坑）；
- **不要求 review**：这是 agent 驱动的工作流，链路上没有人类 reviewer ——
  要求 approvals 等于把每个 PR 永久卡住；
- **不加 push restrictions**：`main` 上的直接 push 是发版链的一部分（`make release` 要推 release 提交）；
- **禁止 force-push 与删除**：`main` 不可被强推、不可被删；
- **不启用 linear history**：仓库用 merge commit 合 PR。

为什么要与 `release_gate.sh` 同一份清单：两处口径各写一份必然漂 —— required contexts
的名字对不上，PR 就永远卡在「等一个永远不会来的检查」（GitHub 按名字匹配，不按 job）。

**改 ci.yml 的 job 名要同步两处**：`tools/release_gate.sh` 的 `DEFAULT_CHECKS` 与
branch protection 的 required contexts。核对当前规则：

```bash
gh api repos/yi-nology/shellkit/branches/main/protection
```

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
4. **装 minisign + rpmbuild**：ubuntu runner 默认都没有。凡是调用 `sign_release.sh` 的 job，
   **必须在同一 job 内先装 minisign**（`tests/test_release_signing_tool.sh` 盯着这条规则 ——
   v0.21.0 与 v0.26.0 都在这上面栽过）；
5. **构建 deb / rpm 并冒烟**（issue #127）：基于**将要发布的那份 tarball**（先对 `SHA256SUMS`）
   打包，再逐个「装上 → 跑通 → 卸干净」。系统包与主资产走同一张验收表：任何一步失败
   整条 run 红，公开动作不会发生；
6. **签名** `bash tools/sign_release.sh --dist dist --require`，随后用 `--file` 给 deb/rpm
   补签（同一把钥匙、同一次运行）：正式发布必须签名，没配私钥直接以 `3` 失败，
   不产出「看起来一样、其实没签」的发行版；
7. **核对钉入公钥** `tools/check_trust_pin.sh`：`docs/TRUST.md`「当前公钥」与本次签名钥不一致就中止；
8. **建 draft release**：17 项资产 —— 8 份内容（tarball / skill 包 / `SHA256SUMS` / `install.sh` /
   `repair.sh` / `demo.sh` / `.deb` / `.rpm`）+ 8 份 `.minisig` + `shellkit.minisign.pub`。
   上传走 `tools/release_assets.sh`（不可变：同摘要跳过、异摘要拒绝覆盖）。draft 里缺
   deb/rpm 或签名就走不到公开；
9. **独立验签** `bash tools/verify_release.sh <tag>`：从 draft 重新取回资产，用 TRUST.md 钉住的公钥
   逐份验签并与 `SHA256SUMS` 对账 —— 只在 `dist/` 上验签证明不了「用户下载到的那份」是对的。
   draft 还没对外可见，所以这一步失败时用户什么都看不到；
10. **公开** `gh release edit <tag> --draft=false --latest`：验签过了才轮到它。
    判据在 `tests/test_release_publish_order.sh`：去掉 `--draft`、把验签与公开对调，用例必须红；
11. **发布后自检** `tools/release_selfcheck.sh <tag> --require-packages`：对着已发布的
    Release 逐项点名（主资产、每份 `.minisig`、`.deb` / `.rpm`），缺一个就红。
    系统包已在公开前硬失败，这一步是发布后可见面的独立复核。

### deb / rpm 是发版硬门禁（issue #127）

旧流程把 deb/rpm 放在公开之后的 `continue-on-error` job 里：Release 页面存在且绿，
不代表下载列表里有系统包（v0.26.0 / v0.26.1 实际缺过）。现在系统包在
**同一个 release job 内、公开之前**构建/冒烟/签名；`packages` job 已删除，
`release.yml` 里不再出现 `continue-on-error`。判据在
`tests/test_release_packages_gate.sh`（构建/签名步骤必须在公开步骤之前，缺一步就红）。
仍然建议亲眼看一遍：

```bash
gh run view <run-id> --json jobs --jq '.jobs[] | [.name,.conclusion] | @tsv'
gh release view "v$version" --json assets --jq '.assets[].name'
```

上面第二条里没有 `shellkit-<ver>.deb` / `.rpm` ⇒ 发布流程出现回归（系统包已是公开前
硬门禁，正常不应发生）；`self-check` 也会按同一判据红。v0.26.0 与 v0.26.1 的历史缺口
（前者 job 没装 minisign，后者 `--file` 补签仍要求 `SHA256SUMS` 整份齐全）对应的
「发布后补打」路径已随 #127 删除。

## 预发布（RC）

RC 走同一条命令，只是版本号带后缀：

```bash
make release-dry VERSION=1.0.0-rc.1
make release VERSION=1.0.0-rc.1
```

- tag 是 `v1.0.0-rc.1`，`VERSION` 文件与资产名（`shellkit-1.0.0-rc.1.tar.gz` 等）都带后缀；
- 公开那步识别 tag 里的 `-`：走 `gh release edit --draft=false --prerelease`，**不**置 `--latest` ——
  `releases/latest`（`install.sh` 的默认路径）继续指向正式版；
- 装 RC 必须显式给版本：`curl -fsSL .../install.sh | VERSION=1.0.0-rc.1 bash`；
- Homebrew formula 只跟正式版，RC 不回填 tap；
- 版本比较由 `ver_cmp` 处理：同核心时正式版 > 预发布，`rc.2 > rc.1`（口径见 `docs/COMPATIBILITY.md`）。
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
出现 `SKIP` 不算通过（`--strict` 下**任何**跳过都判失败并点名版本与原因，
不是只有「全部跳过」才红——一个跑通、两个跳过同样红）；非 strict 的
本地运行仍允许跳过，但 summary 会逐版本列出 `passed / skipped(原因) / failed`。
真离网时先解决网络，而不是把跳过当绿。

> 为什么是三次：这个矩阵证明的是「老工程能被新版本接住」，
> 而它依赖外部 Release 资产与网络路径 —— 一次通过可能只是一次运气。
> 三次连续通过才值得写进发布说明。

## RC 验证：拿真实项目跑一圈（v1.0.0 前置）

升级矩阵证明的是「已发布的旧版本 → 当前」，证明不了「**你自己的工程**」。
v1.0.0 起，发 RC 前用它跑至少两个**非夹具**项目（不是 `examples/` 里的示例）：

```bash
bash tools/rc_check.sh /path/to/project-a /path/to/project-b
```

每个项目它都先**整目录复制到临时目录**（绝不改你的工程），然后在副本上断言：

1. `shellkit upgrade` 退出 0，`vendor/shellkit/VERSION` 跟上当前版本；
2. 清单里没记的、`vendor/` 之外的用户文件**字节不变**；
3. 没有 `.shellkit-new` / `.shellkit-old` / 清单 `.tmp` 残骸；
4. 再升一次是幂等（`already up to date`）；
5. `install-self → uninstall-self` 之后 `bin/shellkit` 与安装清单都消失；
6. 重装出来的 CLI 还能再升级同一个项目，版本仍正确。

输出每个项目的 PASS/FAIL 与 `ran=/fails=` 汇总；任何一项失败退出 `1`，
项目目录不是 shellkit 工程时点名 `no .shellkit-manifest`。
`--keep` 保留临时目录，便于看现场。
## 迟到的资产：--file 补签

发布之后才打出来的资产（例如镜像清单）用点名补签，不要重跑整份签名：

```bash
bash tools/sign_release.sh --dist dist --require --file "dist/manifest.json"
bash tools/release_assets.sh "v$version" \
  "dist/manifest.json" "dist/manifest.json.minisig"
```

deb/rpm 不再走这条路：它们在 release job 内、公开之前与主资产一起签名（#127）。
点名模式**只签点名的文件**（不会顺手重签 `SHA256SUMS` 与 `install.sh`），
也不再要求清单里其他文件在本地存在 —— 补签场景下 `dist/` 里天然只有一部分资产。
没配私钥时 `--require` 直接失败：宁可不附加，也不发布无签名的资产。

## 发布之后必须自己验一遍

CI 绿了不等于用户装得上。这四个动作是发版的验收标准：

```bash
# 1) release 工作流跑完了吗（deb/rpm 已在公开前硬门禁内）
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
version=0.27.0
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
