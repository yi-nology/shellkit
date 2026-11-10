# FAQ

## 为什么不直接用 bash 5？

因为 macOS 自带的 `/bin/bash` 是 3.2.57，而且很多机器上装不了 homebrew。基线定在 3.2，
意味着脚本在别人的 Mac 上、在 CI 的基础镜像里都能跑。想用 5.x 也可以，但这个库不假设你在。

## 为什么日志非要走 stderr？

因为 `v=$(conf_get KEY)` 必须拿到干净的值。如果日志也写 stdout，`$v` 会变成
`[INFO] 8080`，错误会出现在完全无关的地方。这条是整套设计的起点。

## 能不能只用其中一两个模块？

默认会一次性加载全部 23 个模块 —— 单个模块很小，加起来还不到 400KB。

真要瘦下来，用 `SHELLKIT_MODULES` 点名要用的模块：

```bash
SHELLKIT_MODULES="log fs" . ./vendor/shellkit/lib/bootstrap.sh
```

只有列出来的模块会被加载，**它们的传递依赖会自动带上**（`i18n` 永远加载，
因为每个模块都要翻译）。写了不存在的模块名会直接报错，不会静默忽略。

想「只要测试能力」的时候可以直接拷 `tests/run.sh` 和 `tests/test_helper.sh` 两个文件，零依赖。

## 为什么 `shellkit new` 要把库拷进 `vendor/`？

两个原因：CI 上不需要先装 shellkit；以及「上周升级了系统里的 shellkit」不会悄悄改变
今天构建出来的行为。`shellkit vendor . --check` 用逐字节比对防止有人在本地改过 vendor。

## 生成的工程能直接进生产吗？

能，但要先做三件事：把 `config.example` 换成对真实路径的说明；把 `commands/` 里的 TODO
替换成真实逻辑；确认退出码分类对了（别一律 `exit 1`）。

## `run` 和直接敲命令有什么区别？

`run` 失败即 `die`，而且消息里带命令原文与退出码。`SHELLKIT_DRY_RUN=1` 时只打印不执行，
打印出来的命令是**引号化过**的，可以直接复制执行。要在条件里判成败，用 `run --no-die`。

## 为什么 `die` 的 `exit` 不受 `if` / `||` 约束？

`die` 里是 `exit`，不是 `return`。`if run rsync ...` 里 `run` 调 `die`，整个脚本还是会退出，
`if` 拦不住。这是刻意的：默认语义是「失败就停」，不要因为写在条件里就悄悄变成「失败继续」。

## `conf_get` 和 `conf_get_any` 有什么区别？

`conf_get` 只看配置文件；`conf_get_any` 走「环境变量 > 配置文件 > 默认值」。
想让 `PORT=9090 ./deploy.sh` 生效，用后者。

## 国际化一定要装 gettext 吗？

不用。没装 gettext 时 `_t` 原样输出英文 msgid，程序照常跑；`po/messages.sh --check` 会跳过
而不是失败。只有你要**重新生成**译文时才需要 gettext。

## 为什么卸载要依赖 MANIFEST？

因为「猜着删」是删掉别人东西的最短路径。安装时把真实落盘的文件写进清单，卸载只删清单里
的相对路径，`../` 一律跳过。没有清单就报错退出（3），交给人决定。

## 能不能在没有 root 的机器上用？

能。`shellkit install-self --prefix "$HOME/.local"` 装到自己的目录，把 `$HOME/.local/bin`
加进 `PATH` 即可。运行时不需要 root 的模块（`conf_*`、`fs_*`、`net_*`）都能用；
需要 root 的地方用 `require_root` 显式报 3，而不是某一步随机失败。

## 这套东西适合什么规模的脚本？

从 50 行的运维小工具到几千行的安装器都合适。它不提供「业务框架」，只提供那些**每个
脚本都要重写一遍、而且每个都写得不一样**的部分：日志、退出码、配置读写、下载校验、
重试、锁、清理、交互、CLI、译文。
