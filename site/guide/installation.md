# 安装与升级

三种装法，选一种就行：一条命令、本地检出、内网离线。

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

<ShotFigure src="/diagrams/install-chain.svg" caption="五步信任链：sha256 对不上就 exit 5，一个字节都不落地" />

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
curl -fsSL https://github.com/yi-nology/shellkit/releases/latest/download/install.sh | VERSION=0.18.0 bash

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
shellkit update --from shellkit-0.18.0.tar.gz --sha256 "$SUM"
```

## 卸载

```bash
shellkit uninstall-self
```

安装时会把真实落盘的文件写成 `PREFIX/share/shellkit/MANIFEST`；卸载只删清单里列出的
相对路径，`../` 一律跳过并告警。**没有清单就报错退出（退出码 3）**，交给人决定 ——
猜着删是最容易删掉别人东西的做法。

## 装到哪了

```text
PREFIX/bin/shellkit                 入口
PREFIX/share/shellkit/lib/          库（bootstrap.sh + core/*.sh）
PREFIX/share/shellkit/locale/       译文
PREFIX/share/shellkit/templates/    shellkit new 的模板
PREFIX/share/shellkit/tests/        测试断言与执行器（装好的副本也能自测）
PREFIX/share/shellkit/MANIFEST      卸载依据
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
