<!-- 生成物：由 tools/ai_doc.sh 拼装，请勿手改。改 docs/ai/repo.head.md 再跑 shellkit docs。 -->

# 这个仓库：shellkit 本身

你在改的是一个 Bash 库 + 脚手架生成器，不是业务脚本。改动会被别人 vendor 走，
所以**向后兼容是硬约束**：0.x 内只加不改，改既有函数语义要单独提一个版本并写迁移说明。

## 地图

    shellkit                  生成器 CLI（new / doctor / list / vendor / docs / install-self）
    lib/bootstrap.sh          唯一入口：按拓扑序 source lib/core/*.sh
    lib/core/<module>.sh      15 个模块，一个模块一个主题
    templates/                shellkit new 的模板（含 __NAME__ / __CMD__ 占位符）
    tests/                    自研断言 + 逐文件执行器 + 每个模块一个测试
    tools/                    shdoc.awk / coverage.awk / ai_doc.sh / check_docs.sh / term_shot.py
    docs/                     README 之外的深度文档；REFERENCE.md 与 AGENTS.md 是生成物
    locale/{en,zh_CN,zh_Hant} gettext 目录，msgid 一律英文

## 加一个模块要改四处，少一处就红

1. 写 `lib/core/<name>.sh`：公开函数上方**必须**紧邻注释行，否则 `make docs-check` 红。
2. `lib/bootstrap.sh` 的模块序列里插入 —— 按依赖拓扑序，不是字母序。
3. `tools/shdoc.sh` 的 `MODULES` 里加同一位置（两处顺序必须一致）。
4. 写 `tests/test_<name>.sh`。测试文件名被 `tests/test_*.sh` 通配到就自动执行。

## 门禁

    make check     # syntax + test + lint + docs-check + fmt，CI 跑的是同一组

`docs-check` 会拦两种事：公开函数缺注释、`docs/` 里的生成物与源码不一致。
`lint` 是 `shellcheck -S warning -x`，模板会先渲染再检查（占位符不是合法语法）。

## 三个已经踩过的坑

1. **bash 3.2 与 5 的 trap 语义不同**：子 shell 里 `trap -p EXIT`，3.2 读到空，5.x 仍打印
   父 shell 的 trap 但子 shell 退出时不执行。所以幂等不能只查 `trap -p`，看到是自己的
   处理器就重装一遍（重装无害），也绝不把自己的处理器当调用方的捕获下来。
2. **`$(trap -p ...)` 永远读不到东西**：命令替换本身是子 shell。要重定向到文件再 `cat`。
3. **空数组在 `set -u` 下遍历会报 unbound variable**：一律 `${arr[@]+"${arr[@]}"}`。

## 本场景的验证

    make check
    bash tests/run.sh                # 只看测试
    ./shellkit docs --check          # 只看文档产物是否最新
    bash tools/check_docs.sh         # 只看文档里的示例是否仍然成立
