# shellkit 文档站（VuePress）设计

日期：2026-11-09
状态：已批准，已落地

## 目标

把现在的单页手写落地页换成一套真正的文档站：正式、可搜索、中英双语、内容成体系。
同时不制造「三份手写必然漂移」的问题 —— `docs/` 仍是唯一真相源，站点是它的一个视图。

## 硬约束（来自仓库自身）

- Bash 3.2+：新增的 `tools/*.sh` 不得用 `declare -A`、`${v^^}`、`local -n`、`mapfile`、`[[ -v ]]`、
  空数组直接展开。
- stdout 只给数据，日志走 stderr；出参用 `printf -v`；写出参用固定退出码。
- `make check` 不引入 node 依赖。站点构建是 CI 的独立 job。
- `check_docs.sh` 会扫描仓库内**所有** markdown 的 ```bash 块：块内必须 `bash -n` 通过，
  出现的 shellkit 函数名必须存在于 `docs/REFERENCE.md`。站点页面同样受此约束。
- `VERSION` 是唯一真相源，站点里的版本引用由 `check_versions.sh` 校验、由 `release.sh` 同步。

## 技术选型（实测确认）

| 包 | 版本 | 说明 |
|---|---|---|
| `vuepress` | `2.0.0-rc.31` | VuePress 1 的 webpack4 在 Node 26 上跑不起来 |
| `@vuepress/bundler-vite` | `2.0.0-rc.31` | 必须传 `viteBundler()` 实例，传字符串报 `bundler.build is not a function` |
| `@vuepress/theme-default` | `2.0.0-rc.137` | peer 固定 `vuepress@2.0.0-rc.31` |
| `@vuepress/plugin-search` | `2.0.0-rc.137` | 本地搜索索引，不依赖外部服务 |
| `sass-embedded` | `^1.108.1` | 主题 palette 覆盖需要 sass |

三条实测结论直接影响实现：

1. **配置必须是 `site/.vuepress/config.ts`**。默认主题是 ESM 且带顶层 await，
   `config.js`（CJS）会报 `ERR_REQUIRE_ASYNC_MODULE`。
2. `bundler` 必须是实例，不是包名字符串。
3. 默认主题 rc.137 已内置代码复制、返回顶部、prismjs 行号高亮、提示容器、tab、图片放大、
   sitemap、SEO、lastUpdated —— 额外插件只需要 search 一个。
4. 主题自带的 links-check 实测**不会**让坏链导致构建失败，所以站内链接校验要自己写。
5. **图片不能走 markdown 的相对路径**：VuePress 2 rc.31 + rolldown 会把 `src` 当 ES import 解析，
   `public/` 里的文件不参与 bundler 解析，因此相对路径报 `Rolldown failed to resolve import`、
   绝对路径报 `[UNRESOLVED_IMPORT]`。解法是自己写 `site/.vuepress/components/ShotFigure.vue`，
   用 `withBase()` 拼 URL 后由 Vue 渲染，绕开 markdown 的资源解析。
6. **摘要里不能出现 `<name>` 这样的尖括号**：`tools/shdoc.sh` 生成的摘要会被当成 Vue 模板，
   `cmd_<name>` 会让构建报 `Element is missing end tag`。要写「cmd_ 前缀的函数」而不是 `cmd_<name>`。

## 目录结构

```text
site/
  package.json            精确版本（不带 ^ 的 vuepress 系）+ package-lock.json 入库
  .vuepress/
    config.ts             base '/shellkit/'、中英 locales、导航、侧边栏、search
    styles/index.scss     深色 palette（--vp-c-accent: #3fb950）+ 排版
    public/shots/         同步自 docs/shots（gitignore）
  index.md                中文首页（home 布局）
  guide/*.md              手写 14 篇 + 同步 3 篇
  reference/*.md          总览 + 15 个模块页（生成）
  en/index.md             英文首页
  en/guide/*.md           手写页英文镜像（14 篇）
  en/reference/*.md       签名摘要（生成）
  .vuepress/components/ShotFigure.vue  终端截图组件（绕开 markdown 资源解析）
```

`site/index.html` 与 `site/style.css` 删除。

## 单一真相源与同步契约

`tools/site_sync.sh`（纯 bash）负责把 `docs/` 投影到 `site/`：

| 源 | 目标 | 处理 |
|---|---|---|
| `docs/COOKBOOK.md` | `site/guide/cookbook.md` | 首行 h1 → frontmatter title |
| `docs/MIGRATING.md` | `site/guide/migrating.md` | 同上 |
| `docs/RELEASING.md` | `site/guide/releasing.md` | 同上 |
| `docs/REFERENCE.md` | `site/reference/<module>.md` + `index.md` | 按 `## ` 拆页，h2 → 页面标题，h3 保持 |
| `docs/REFERENCE.md` | `site/en/reference/*.md` | 只保留 `### \`name\`` 签名行与 @param/@exitcode，正文不翻译 |
| `docs/shots/*.svg` | `site/.vuepress/public/shots/` | 原样复制 |
| 三个中文同步页 | `site/en/guide/{cookbook,migrating,releasing}.md` | 生成英文导语 + 链到中文全文 |

同步产物全部 gitignore；`npm run dev/build` 通过 `predev`/`prebuild` 自动先跑同步，
所以本地与 CI 都不会拿到过期副本。同步时把 `https://github.com/<org>/<repo>/blob/main/docs/X.md`
改写成站内路由。

## 内容清单

中文：

- `index.md`：hero + 3 actions + 6 特性 + 3 张真跑截图 + 15 模块速查
- `guide/`：index（总览）、installation、quickstart、conventions、bash32、modules、cli、i18n、
  testing、examples、ai、faq、troubleshooting、contributing，加同步来的 cookbook、migrating、releasing
- `reference/`：总览 + `error i18n log str validate fs os trap run retry lock net config prompt cli` 15 页

英文镜像覆盖全部手写页；同步页只给导语与签名摘要（见上表）。

## 部署

`pages.yml` 重写：

1. `actions/checkout@v4`
2. `actions/setup-node@v4`（node 22 + `cache: npm` + `cache-dependency-path: site/package-lock.json`）
3. `cd site && npm ci && npm run build`
4. `bash tools/site_links.sh site/.vuepress/dist`
5. `actions/upload-pages-artifact@v3`（path: `site/.vuepress/dist`）+ `actions/deploy-pages@v4`

`base: '/shellkit/'` 保证资产路径，站点 URL 不变。
触发路径扩到 `site/**`、`docs/*.md`、`docs/shots/**`、`tools/site_sync.sh`、`tools/site_links.sh`。

## 门禁改动

- 新增 `tools/site_links.sh`：扫构建产物中每个 `href`/`src`，内部链接必须命中真实文件；
  同时断言首页含当前 `VERSION`（复用 `下载 x.y.z` 与 `Download x.y.z` 两种写法）。
  非 0 退出码用 5（校验失败）。
- `tools/check_versions.sh`：站点引用从 `site/index.html` 改为 `site/index.md`（`VERSION=`、`下载 `）
  与 `site/en/index.md`（`VERSION=`、`Download `）；安装页的钉版本示例与 tarball 名也纳入，
  否则发版后「教人装上一版」没人拦。
- `tools/release.sh`：`_bump_refs` 增加 `Download x.y.z` 与 tarball 名规则，并把两个首页、
  两个安装页加进同步列表。
- `docs/RELEASING.md`：版本引用清单从「六处」更新为六个文件、十一条引用。
- `Makefile`：新增 `site-deps` / `site-sync` / `site` / `site-serve`，都不进 `check`。
- `ci.yml`：新增 `site` job（npm ci + build + site_links），与库的门禁并行。

## 风险

| 风险 | 处理 |
|---|---|
| rc 版本线会漂 | 版本号精确锁定、`package-lock.json` 入库、升级单独提交并重建 |
| 英文页与中文页漂移 | 英文只覆盖手写页；同步页英文只放签名摘要，不复制正文 |
| 站点页面代码块被 check_docs 拦 | 每段 bash 写成可 `bash -n` 的完整片段；函数名只用 REFERENCE 里有的 |
| Pages 资产 404 | `base` 必须 `/shellkit/`；构建后用 `site_links.sh` 在本地产物上验证 |

## 验收标准

1. `cd site && npm ci && npm run build` 成功，产物含中文 20+ 页与英文 16+ 页。
2. `bash tools/site_links.sh site/.vuepress/dist` 通过。
3. `bash tools/check_versions.sh` 通过；`bash tools/check_docs.sh` 通过。
4. `make check` 全绿（不依赖 node）。
5. `make release-dry VERSION=0.6.1` 能同时改到第二个首页的 `Download` 版本号。
6. 推送后 pages 工作流 success，线上首页、`/guide/installation.html`、`/reference/log.html` 可访问。

## 落地时补的（不在原设计里）

- **API 参考页从「裸签名」变成「签名 + 说明」**：原先 83 个公开函数里有 37 个在 `docs/REFERENCE.md`
  里只有一行签名（`net_download URL DEST [SHA256]`），没有一句人话。参考页是给读者查「这个函数干什么、
  失败返回什么」的，裸签名等于没写。因此给这 37 个函数补了源码注释摘要并重生成文档 ——
  这也顺带修正了 `cli_opts` 的签名（注释写的 `cli_opts NAME ARGS...` 与实现不符，实现不接 NAME）。
- **发版时的版本漂移**：站点新增的安装页也有 `VERSION=0.6.0` 的钉版本示例，如果不同步，
  发版后站点会教人装旧版 —— 与 README 同类的坑，所以一并纳入 `check_versions.sh` 与 `release.sh`。
- **`tools/check_docs.sh` 排除 `node_modules` 与站点构建产物**：否则装完依赖后 `make check` 会去扫
  第三方 markdown，报一堆不相干的错。
