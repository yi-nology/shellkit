#!/usr/bin/env bash
#
# 把 docs/ 投影成站点页面。生成物全部在 site/.gitignore 里，由 npm 的 predev /
# prebuild 自动调用，所以本地预览与 CI 构建都不会拿着过期副本发版。
#
#   bash tools/site_sync.sh      # 生成到 site/
#
# 为什么不是「复制一份到 site/ 再手改」：docs/ 是唯一真相源，站点只是它的一个视图。
# 手改副本会让两边慢慢分叉，而且没有任何门禁会发现分叉。
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCS="$ROOT/docs"
SITE="$ROOT/site"

# 模块清单从 lib/modules.txt 读 —— 与 bootstrap、shdoc 同一份真相源。
#
# 以前这里硬写了一份，结果加模块时忘了改这里，站点上就少了两页 API 参考
# （http 与 scaffold），而没有任何门禁发现。第三份清单迟早还会漂。
#
# modules.txt 每行是「模块名 [依赖...]」，这里只取第一个字段。
MODULES=""
while IFS= read -r __mod_line || [ -n "$__mod_line" ]; do
  case "$__mod_line" in
    '' | '#'*) continue ;;
  esac
  # 取第一段（模块名），后面的依赖字段不要
  __mod_name=${__mod_line%%[[:space:]]*}
  [ -n "$__mod_name" ] || continue
  MODULES="$MODULES $__mod_name"
done <"$ROOT/lib/modules.txt"
MODULES="${MODULES# }"
[ -n "$MODULES" ] || _die 'lib/modules.txt is empty or missing' 3

_say() { printf '[site-sync] %s\n' "$*" >&2; }
_die() {
  printf '[site-sync] ERROR: %s\n' "$*" >&2
  exit "${2:-1}"
}

[ -f "$DOCS/REFERENCE.md" ] || _die "missing $DOCS/REFERENCE.md; run shellkit docs first" 3
mkdir -p "$SITE/guide" "$SITE/reference" "$SITE/en/guide" "$SITE/en/reference" \
  "$SITE/.vuepress/public/shots" || _die 'cannot create site directories' 1

# _first_h1 FILE —— 取首个一级标题的文本；没有就返回空
_first_h1() {
  awk '/^# / { sub(/^# +/, ""); print; exit }' "$1"
}

# _emit_page SRC DEST —— 生成带 frontmatter 的页面，并把 docs 内部链接改成站内路由
_emit_page() {
  local __src=$1
  local __dest=$2
  local __title

  __title=$(_first_h1 "$__src")
  [ -n "$__title" ] || __title='shellkit'
  __title=$(printf '%s' "$__title" | tr -d '"')

  {
    printf -- '---\ntitle: "%s"\n---\n\n' "$__title"
    awk 'BEGIN { done = 0 } /^# / { if (!done) { done = 1; next } } { print }' "$__src"
  } | sed \
    -e 's#](REFERENCE\.md)#](../reference/index.md)#g' \
    -e 's#](MIGRATING\.md)#](migrating.md)#g' \
    -e 's#](COOKBOOK\.md)#](cookbook.md)#g' \
    -e 's#](RELEASING\.md)#](releasing.md)#g' \
    -e 's#](MAN\.md)#](man.md)#g' >"$__dest" || return 1
}

# _funcs_of MODULE —— 该模块公开函数名列表（反引号包裹，空格分隔）
_funcs_of() {
  awk -v mod="$1" '
    $0 == "## " mod { inside = 1; next }
    /^## / { inside = 0 }
    inside && /^### `/ {
      s = $0
      sub(/^### `/, "", s)
      sub(/`.*/, "", s)
      printf "`%s` ", s
    }
  ' "$DOCS/REFERENCE.md"
}

# _module_page MODULE —— 中文参考页
_module_page() {
  local __m=$1
  {
    printf -- '---\ntitle: "%s"\n---\n\n' "$__m"
    awk -v mod="$__m" '
      $0 == "## " mod { inside = 1; next }
      /^## / { inside = 0 }
      inside { print }
    ' "$DOCS/REFERENCE.md"
  } >"$SITE/reference/$__m.md" || return 1
}

# _module_page_en MODULE —— 英文参考页：只保留签名，注释正文不翻译
_module_page_en() {
  local __m=$1
  {
    printf -- '---\ntitle: "%s"\n---\n\n' "$__m"
    printf '> Signatures only. The Chinese page carries the full comments: [%s](../../reference/%s.md).\n' "$__m" "$__m"
    awk -v mod="$__m" '
      function flush() {
        if (name != "") {
          print ""
          print name
          if (sig != "") { print ""; print "`" sig "`" }
        }
        name = ""; sig = ""
      }
      $0 == "## " mod { flush(); inside = 1; next }
      /^## / { flush(); inside = 0; next }
      !inside { next }
      /^### `/ { flush(); name = $0; want = 1; next }
      want && NF { sig = $0; sub(/ *——.*/, "", sig); want = 0 }
      END { flush() }
    ' "$DOCS/REFERENCE.md"
    printf '\n[Source on GitHub](https://github.com/yi-nology/shellkit/blob/main/lib/core/%s.sh)\n' "$__m"
  } >"$SITE/en/reference/$__m.md" || return 1
}

# ---------- 1. 三篇从 docs/ 同步的中文页 ----------

_emit_page "$DOCS/COOKBOOK.md" "$SITE/guide/cookbook.md" || _die 'failed to write guide/cookbook.md'
_emit_page "$DOCS/MIGRATING.md" "$SITE/guide/migrating.md" || _die 'failed to write guide/migrating.md'
_emit_page "$DOCS/RELEASING.md" "$SITE/guide/releasing.md" || _die 'failed to write guide/releasing.md'
_emit_page "$DOCS/MAN.md" "$SITE/guide/man.md" || _die 'failed to write guide/man.md'

# ---------- 2. API 参考：总览 + 每模块一页 ----------

__nfunc=$(grep -c '^### `' "$DOCS/REFERENCE.md")
{
  printf -- '---\ntitle: "API 参考"\n---\n\n'
  printf '# API 参考\n\n'
  printf '> 由 `tools/shdoc.sh` 从源码注释生成，共 %s 个公开函数。改完注释跑 `shellkit docs`。\n' "$__nfunc"
  printf '> 参数与退出码写在每个函数的签名行里；这里是唯一真相源，不会和代码漂移。\n\n'
  printf '| 模块 | 公开函数 |\n| --- | --- |\n'
  for __m in $MODULES; do
    printf '| [%s](./%s.md) | %s |\n' "$__m" "$__m" "$(_funcs_of "$__m")"
  done
  printf '\n## 退出码\n\n'
  printf '| 码 | 宏 | 含义 |\n| --- | --- | --- |\n'
  printf '| 0 | `SK_OK` | 成功 |\n'
  printf '| 1 | `SK_ERR` | 一般错误 |\n'
  printf '| 2 | `SK_USAGE` | 用法错（参数不对） |\n'
  printf '| 3 | `SK_PRECOND` | 前置条件不满足（缺命令、非 root、该交互却没默认值） |\n'
  printf '| 4 | `SK_NET` | 网络失败 |\n'
  printf '| 5 | `SK_VERIFY` | 校验失败（sha256 不匹配、文档与代码不一致） |\n'
} >"$SITE/reference/index.md" || _die 'failed to write reference/index.md'

for __m in $MODULES; do
  _module_page "$__m" || _die "failed to write reference/$__m.md"
  _module_page_en "$__m" || _die "failed to write en/reference/$__m.md"
done

{
  printf -- '---\ntitle: "API reference"\n---\n\n'
  printf '# API reference\n\n'
  printf '> %s public functions. Signatures are generated from the source comments;' "$__nfunc"
  printf ' the Chinese pages carry the full comments.\n\n'
  printf '| Module | Functions |\n| --- | --- |\n'
  for __m in $MODULES; do
    printf '| [%s](./%s.md) | %s |\n' "$__m" "$__m" "$(_funcs_of "$__m")"
  done
} >"$SITE/en/reference/index.md" || _die 'failed to write en/reference/index.md'

# ---------- 3. 站点页面里的版本号 ----------
# 站点页面的版本号是「手抄投影」：跟 README、pot 头一样靠 tools/check_versions.sh
# 复查、靠 tools/release.sh 批量替换。这里不做什么 —— 它一旦开始「自动同步」，
# 就会出现「源码里是旧版、构建出来是新版」这种没法用 grep 复查的状态。
#
# 需要在站点里出现当前版本的地方（首页的下载按钮、安装页的钉版本示例），
# 由 check_versions.sh 与 site_links.sh 两道门守住。

# ---------- 4. 同步页的英文导语（正文只存在于中文页）----------

_en_notice() {
  local __file=$1
  local __title=$2
  local __zh=$3
  local __why=$4
  {
    printf -- '---\ntitle: "%s"\n---\n\n' "$__title"
    printf '::: warning Chinese only\n'
    printf 'This page is maintained in Chinese, because it is generated from the canonical'
    printf ' documents under `docs/`. Translating it here would create a second copy that rots.\n'
    printf ':::\n\n'
    printf '%s\n\n' "$__why"
    printf 'Read the full text: [%s (中文)](../guide/%s.md).\n' "$__title" "$__zh"
  } >"$__file" || return 1
}

# 场景数从源文件数出来，不手抄：手抄的数字必然在加场景那天开始过期。
__cookbook_n=$(grep -c '^## [0-9]' "$DOCS/COOKBOOK.md" 2>/dev/null || true)
[ -n "$__cookbook_n" ] || __cookbook_n=0
_en_notice "$SITE/en/guide/cookbook.md" 'Cookbook' 'cookbook' \
  "$__cookbook_n recipes: editing config, verified downloads, retries, single-instance locks, interactive prompts. Every section is scenario / code / why."
_en_notice "$SITE/en/guide/migrating.md" 'Migration guide' 'migrating' \
  'Five incremental steps for wiring shellkit into a script that already runs in production. Each step can ship on its own.'
_en_notice "$SITE/en/guide/releasing.md" 'Releasing' 'releasing' \
  'How a release happens: one command bumps the version, regenerates artifacts, runs the gates, commits, tags and pushes.'
_en_notice "$SITE/en/guide/man.md" 'Man pages' 'man' \
  'How shellkit man builds man pages: section 1 from the CLI registry, one page per library module from the module list and the doc comments.'

# ---------- 5. 截图 ----------

for __f in "$DOCS"/shots/*.svg; do
  [ -f "$__f" ] || continue
  cp "$__f" "$SITE/.vuepress/public/shots/" || _die "failed to copy $__f"
done

_say "pages: 4 synced, 1 reference index, $__nfunc functions across $(printf '%s\n' $MODULES | wc -l | tr -d ' ') modules"
exit 0
