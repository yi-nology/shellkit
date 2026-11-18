# 安装与升级

三种装法，选一种就行：一条命令、本地检出、内网离线。

## 安全安装（三步，推荐）

sha256 只证明「下载没被改」，证明不了「这个包是 shellkit 发的」—— 清单和包走同一条下载通道，
中间人可以一起换掉。高保障环境按这三步走（默认的 `curl | bash` 仍然可用，见下文）：

```bash
# 1) 核对公钥：docs/TRUST.md「当前公钥」钉的是这一把；
#    再与 release 资产里的 shellkit.minisign.pub、该 tag 的 raw TRUST.md 比对
#    RWQSCu8f5lvakshhMkZ2zgn+hbB0s0EJ2Wpx+rUgfHw7MmcQ5gcmPBao

# 2) 离线验签：先下载、先验，最后才执行任何脚本
#    需要 minisign：brew install minisign / apt-get install -y minisign
VERSION=1.1.0
base="https://github.com/yi-nology/shellkit/releases/download/v$VERSION"
work=$(mktemp -d) && cd "$work" || exit 1
for f in "shellkit-$VERSION.tar.gz" install.sh SHA256SUMS shellkit.minisign.pub; do
  curl -fsSLO "$base/$f" || exit 1
  case "$f" in *.pub) ;; *) curl -fsSLO "$base/$f.minisig" || exit 1 ;; esac
done
minisign -Vm "shellkit-$VERSION.tar.gz" -p shellkit.minisign.pub
minisign -Vm install.sh -p shellkit.minisign.pub
minisign -Vm SHA256SUMS -p shellkit.minisign.pub
sha256sum -c SHA256SUMS            # macOS 没有 sha256sum 时：shasum -a 256 -c SHA256SUMS

# 3) 再安装：用已经验签、已经校验的本地树，不再联网
tar -xzf "shellkit-$VERSION.tar.gz" && cd "shellkit-$VERSION" || exit 1
./install.sh --prefix "$HOME/.local"
```

公钥的另外两个核对渠道、`install.sh` 自身怎么验（离线路径）、deb/rpm 的信任链，
见 [docs/TRUST.md](https://github.com/yi-nology/shellkit/blob/main/docs/TRUST.md)。
## 一条命令

```bash
curl -fsSL https://github.com/yi-nology/shellkit/releases/latest/download/install.sh | bash
```

默认装到 `/usr/local`；没有写权限就退到 `~/.local`。

脚本自己不往目标目录放任何文件，它只做四件事：

1. 取最新版本号（`releases/latest` 的重定向）。
2. 下载 `shellkit-<version>.tar.gz` 与 `SHA256SUMS`。
3. 校验 sha256，对不上就 `exit 5`，一个字节都不落地。
4. 把包解开，交给包内自带的 `shellkit install-self`。

**安装逻辑只有一份**，就在 `install-self` 里。安装脚本只是把它下载下来而已 —— 否则
「一键装」和「手动装」迟早会装出两种布局。

<ShotFigure src="/diagrams/install-chain.svg" caption="六步安装链：验签（可选）锚「谁发的」，sha256 验「没被改」；任何一步不过就 exit 5，一个字节都不落地" />

配了公钥（`SHELLKIT_MINISIGN_PUBKEY` 或 `SHELLKIT_MINISIGN_PUBKEY_FILE`）时，脚本会先验 
`SHA256SUMS.minisig` 与 tarball 的 `.minisig`，**再**读清单内容 —— 完整口径与离线校验步骤见
[信任链](https://github.com/yi-nology/shellkit/blob/main/docs/TRUST.md)。不配公钥时整段验签跳过、默认行为不变。

地址用的是 release 资产，不是 `raw.githubusercontent.com`。后者在部分网络会被重置，
而仓库地址又是固定的，所以网页和 README 都不用 raw。

## Homebrew

```bash
brew install yi-nology/shellkit/shellkit
```

tap 在 [yi-nology/homebrew-shellkit](https://github.com/yi-nology/homebrew-shellkit)。
formula 是生成物：本仓的 `tools/brew_formula.sh` 生成它，sha256 取自对应 release 的
`SHA256SUMS` —— Homebrew 要求逐字节一致，手抄必错。

## 不装也能试（一条命令）

```bash
curl -fsSL https://github.com/yi-nology/shellkit/releases/latest/download/demo.sh | bash
```

下载 release、校验 sha256、解包到临时目录，生成一个工程、跑一遍工程**自己的**测试
（跑的是真二进制），再把导览打出来。不往你的机器上装任何东西，临时目录随进程退出清掉，
留下的只有那个演示工程。

## 钉版本、换目录、走镜像

```bash
# 换安装目录
curl -fsSL https://github.com/yi-nology/shellkit/releases/latest/download/install.sh | PREFIX="$HOME/.local" bash

# 钉版本
curl -fsSL https://github.com/yi-nology/shellkit/releases/latest/download/install.sh | VERSION=1.1.0 bash

# 内网镜像：<base>/v<version>/<asset>
curl -fsSL https://github.com/yi-nology/shellkit/releases/latest/download/install.sh | SHELLKIT_RELEASE_BASE=https://mirror.example/shellkit bash
```

镜像目录必须是 `<base>/v<version>/shellkit-<version>.tar.gz` 这种形状；本地拿 `file://`
造镜像时也要放进 `v<version>/` 子目录，否则会报下载失败。

## 在检出目录里直接装当前工作树

已经 clone 下来、想装的是**当前代码**（不是 release）时：

```bash
./shellkit install-self
./shellkit install-self --prefix "$HOME/.local"
```

`install.sh --prefix DIR` 等价于先解包再调 `install-self`。

## 更新

```bash
shellkit update --check
shellkit update
```

`--check` 只比对版本，**stdout 只给版本号**，可以直接进脚本：

```bash
latest=$(shellkit update --check)
if [ "$latest" != "$(cat VERSION)" ]; then
  log_warn "new version available: $latest"
fi
```

`update` 会下载并校验 sha256，通过之后才替换。离线或内网环境给定本地包：

```bash
shellkit update --from shellkit-1.1.0.tar.gz --sha256 "$SUM"
```

## 卸载

```bash
shellkit uninstall-self            # 只删「我们装的、内容还是原样」的，用户文件默认保留
shellkit uninstall-self --purge    # 连安装目录里用户自己放的一起清掉（普通卸载之后也能再跑）
shellkit uninstall-self --legacy   # 旧安装（只有 MANIFEST、无指纹清单）的显式兼容清理
```

安装时把真实落盘的文件与指纹写成 `PREFIX/share/shellkit/.shellkit-install-manifest`；卸载逐条比对，
`../` 一律跳过并告警，用户改过/新增的文件保留并打印 `kept files that are not ours: N`。
没有清单时普通卸载报错退出（退出码 3），交给人决定 —— 猜着删是最容易删掉别人东西的做法。
只有 `MANIFEST`、没有指纹清单的旧安装默认 fail-closed；先 `install-self --force` 采纳指纹（会覆盖
本地修改）再卸载，或显式用 `--legacy` 按旧语义全删。

## 装到哪了

```text
PREFIX/bin/shellkit                 入口
PREFIX/share/shellkit/lib/          库（bootstrap.sh + core/*.sh）
PREFIX/share/shellkit/locale/       译文
PREFIX/share/shellkit/templates/    shellkit new 的模板
PREFIX/share/shellkit/tests/        测试断言与执行器（装好的副本也能自测）
PREFIX/share/shellkit/MANIFEST      安装文件表
PREFIX/share/shellkit/.shellkit-install-manifest  所有权与指纹基线（卸载/重装依据）
```

## 退出码

| 码 | 什么时候 |
| --- | --- |
| 0 | 装好了 |
| 2 | 参数不对（比如 `--prefix` 后面没有值） |
| 3 | 前置条件不满足（没有写权限、`PREFIX` 是文件不是目录） |
| 4 | 下载失败 |
| 5 | 校验失败（sha256 不匹配、包损坏） |

这五个码在 `shellkit update` 上也是同一套，脚本里可以直接判。
