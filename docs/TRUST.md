# 信任链：验什么、不验什么、离线怎么验

sha256 只证明「下载没被改」，不证明「这个包是我们发的」—— `SHA256SUMS` 和 tarball
走同一个下载通道，中间人可以一起换掉。minisign 签名把信任锚到一把公钥上。
而 `curl | bash` 形态的 `install.sh` **校验不了它自己**（脚本先执行、后校验），
这条链断在哪里、怎么绕开，本文逐段写清（issue #66）。

## 全景：每一环保证什么、不保证什么

| 环节 | 机制 | 保证 | 不保证 |
|---|---|---|---|
| tarball ↔ SHA256SUMS | sha256 对比（install.sh 默认就做） | 下载的包与发布时逐字节一致 | 清单本身没被换（同通道） |
| `.minisig` ↔ 文件 | minisign（Ed25519）验签 | 文件确实由持私钥的发布者签出 | 公钥本身是真的（要跨渠道核对） |
| `install.sh` 自身 | 默认**无** | —— | 脚本在任何校验之前就执行；离线路径里用 `install.sh.minisig` 验 |
| deb / rpm | 同一 tarball 封装 + 逐项自检 | 包内容与已验签 tarball 逐字节一致 | 独立的 apt/rpm 仓库签名（未建仓库，见下） |

## install.sh 验什么、不验什么

**验**（仅远端安装路径；本地 git 检出安装不联网、无此环节）：

1. tarball 的 sha256 对 `SHA256SUMS` —— 默认永远验；
2. 配了公钥（`SHELLKIT_MINISIGN_PUBKEY` 或 `SHELLKIT_MINISIGN_PUBKEY_FILE`）时，
   额外验 `SHA256SUMS.minisig` 与 `shellkit-<ver>.tar.gz.minisig` ——
   验签发生在**读取清单内容之前**：先锚「清单是我们发的」，再信 sha256。

**不验**：

- **install.sh 自己**：`curl | bash` 的形态决定它没有机会校验自己。要验它，走下面的离线路径；
- **deb / rpm**：包不走 install.sh，信任链见「系统包」一节；
- **公钥来源**：脚本不内置公钥（内置只是把信任挪个地方），公钥由你用环境变量交给它。

没配公钥时：整段验签跳过、只在 stderr 提示一行，退出码与输出的其余部分与从前一致
——**默认行为不变**，这是 issue #66 的硬要求。

## 在线安装（可选验签）

```bash
# 公钥用 base64 串（.pub 文件第 2 行）
curl -fsSL https://github.com/yi-nology/shellkit/releases/latest/download/install.sh \
  | SHELLKIT_MINISIGN_PUBKEY='REPLACE_WITH_BASE64_PUBLIC_KEY' bash

# 或者公钥来自文件（先下载、先核对，再执行）
curl -fsSL https://github.com/yi-nology/shellkit/releases/latest/download/install.sh \
  | SHELLKIT_MINISIGN_PUBKEY_FILE=./shellkit.minisign.pub bash
```

配了公钥却缺 minisign ⇒ 退出码 3（前置条件）；验签不过或缺签名资产 ⇒ 退出码 5（校验失败）。

## 离线可校验安装（高保障环境推荐）

先下载、验签、核对，**最后**才执行任何脚本；安装阶段用已验签的本地树，不再联网：

```bash
ver=1.2.3 # 换成要装的版本号；版本与哈希请跨渠道核对
base="https://github.com/yi-nology/shellkit/releases/download/v$ver"
work=$(mktemp -d)
cd "$work" || exit 1

curl -fsSLO "$base/shellkit-$ver.tar.gz"
curl -fsSLO "$base/shellkit-$ver.tar.gz.minisig"
curl -fsSLO "$base/SHA256SUMS"
curl -fsSLO "$base/SHA256SUMS.minisig"
curl -fsSLO "$base/install.sh"
curl -fsSLO "$base/install.sh.minisig"
curl -fsSLO "$base/shellkit.minisign.pub"

# 1) 验签：任何一条不过就停（minisign 是唯一前置：apt-get install minisign / brew install minisign）
minisign -Vm SHA256SUMS -p shellkit.minisign.pub
minisign -Vm "shellkit-$ver.tar.gz" -p shellkit.minisign.pub
minisign -Vm install.sh -p shellkit.minisign.pub

# 2) 校验 sha256（macOS 没有 sha256sum 时：shasum -a 256 -c SHA256SUMS）
sha256sum -c SHA256SUMS

# 3) 解包并用「已验签、已校验」的本地树安装：install.sh 看到本目录就装本地树，不再下载
tar -xzf "shellkit-$ver.tar.gz"
cd "shellkit-$ver" || exit 1
./install.sh --prefix "$HOME/.local"
```

## 公钥从哪来（跨渠道核对）

公钥（`shellkit.minisign.pub`，一行 base64）有三个获取渠道，**至少比对其中两个一致再用**：

1. release 资产 `shellkit.minisign.pub` —— 与下载同通道，防不了同通道替换，只为方便；
2. 本文件 `docs/TRUST.md` 钉的 base64 —— 随 git 历史可审计；
3. raw.githubusercontent.com 上**该 tag 版本**的本文件 —— 走 GitHub 的 TLS 与平台完整性。

### 当前公钥

```text
状态：发布私钥尚未生成/配置。维护者完成下面「三步」后，把公钥 base64 钉在这里；
在此之前 release 资产没有 .minisig，install.sh 远端安装会提示 signature
verification skipped（这是当前的真实状态，不是故障）。
```

## 维护者要做的三步（私钥只有你有）

```bash
# 1) 生成密钥对。-W 表示私钥不加密 —— CI 签名不能卡在密码提示上；
#    代价是私钥泄露即信任链失效，请像对待 TLS 私钥一样保管它。
minisign -G -W -f -s shellkit.key -p shellkit.pub

# 2) 私钥进仓库 secret（内容形态，绝不进 git）；公钥同样放 secret 供 CI 发布资产
gh secret set SHELLKIT_MINISIGN_KEY < shellkit.key
gh secret set SHELLKIT_MINISIGN_PUBKEY < shellkit.pub
rm -f shellkit.key # 本地不再留副本

# 3) 把公钥 base64（.pub 文件第 2 行）钉进本文件的「当前公钥」一节，随下一个 tag 发布
```

- **没配私钥时**：`tools/sign_release.sh` 打印 `skipped: SHELLKIT_MINISIGN_KEY is not set`
  并以 0 退出 —— 发布不挡、资产没有 `.minisig`、**绝不伪造签名产物**；
- **顺序**：先发带签名的 release，再给 install.sh 配公钥。反过来配公钥，
  验签会因为「签名资产不存在」以 5 失败（这是故意的：要验就必须验得过）；
- **轮换**：换钥匙后，旧公钥验证旧版本、新公钥验证新版本 —— 本文件按版本钉历史公钥。

## 发布资产不可变（issue #87）

`gh release upload --clobber` 会静默覆盖同 tag 已发布的资产 —— 同一版本的
下载内容可被替换。签名与 sha256 防的是下载链路，防不了发布账号被攻破后的
整体替换；资产不可变是把「替换」变成显式人工动作的最后防线。纪律由
`tools/release_assets.sh` 落地，release.yml 与 packages.yml 的上传全部走它：

- 资产不存在 ⇒ 上传（不给 `--clobber`：存在即拒绝，不存在才写）；
- 资产已存在且摘要一致 ⇒ 跳过（流水线重跑幂等，不产生写入）；
- 资产已存在但摘要不同 ⇒ **拒绝覆盖并让发布红**，指路人工处理 —— 真要重发
  同一版本，先手工删掉旧资产（或整个 release）再跑，让替换有记录、可审计。

## 系统包（deb / rpm）的信任链

包不是第二份内容：`tools/package_syspkg.sh` 把**已发布**的 tarball 解到
`/usr/lib/shellkit`，`/usr/bin/shellkit` 只是指过去的软链；装上、跑通、卸干净由
`tools/package_smoke.sh` 判，逐项点名自检见脚本注释。所以「验过 tarball」≈「验过包的内容」。
自己交叉核对一次：

```bash
tar -xzf "shellkit-$ver.tar.gz"
# deb：解开包，与已验签的 tarball 逐字节对比
mkdir -p /tmp/sk-pkg
dpkg-deb -x "shellkit-$ver.deb" /tmp/sk-pkg
diff -r "shellkit-$ver" /tmp/sk-pkg/usr/lib/shellkit

# rpm：装上后再对比同一路径
sudo rpm -i "shellkit-$ver.rpm"
diff -r "shellkit-$ver" /usr/lib/shellkit
```

包没有独立的 apt/rpm 仓库签名（那要托管仓库，超出当前范围）——在此之前请用上面的
交叉核对，或只用 tarball 路径。另外：**系统包请用包管理器升级**，不要跑
`shellkit update`（它会绕过 dpkg/rpm 的数据库，把包变成「管理器不认识的改动」）。

## 为什么选 minisign（以及不提供 openssl 手搓回退）

- **GPG**：信任网、过期、子钥的管理成本高，脚本里验签要 `gpg --batch` 一堆解析；
- **cosign**：为容器/OCI 设计，默认走 KMS/OIDC，给 tarball 签名是杀鸡用牛刀，
  验证方还得装整套工具；
- **minisign**：单文件、Ed25519、一条命令验签、公钥就是一行 base64 —— 正好匹配
  「执行一行安装命令之前先验一个 tarball」的场景；
- **不退到 openssl**：minisign 的签名格式（Ed25519 + Blake2b 预哈希 + trusted comment）
  用 openssl 拼出来等于自研签名方案 —— 比要求用户装一个几十 KB 的工具更危险。
  没有 minisign 的机器：要么装它，要么走 sha256-only 的默认路径（行为不变）。
