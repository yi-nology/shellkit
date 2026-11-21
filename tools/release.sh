#!/usr/bin/env bash
#
# 一条命令发版。做的事按顺序是：
#
#   1. 校验：版本号格式、比当前版本大、在 main 上、工作树干净、tag 未被占用、有 xgettext
#   2. 写 VERSION
#   3. 重生成 pot（头里的 Project-Id-Version 跟着走）
#   4. 重生成文档产物（REFERENCE / AGENTS / SKILL）
#   5. 同步 README 与站点里的钉版本示例和下载按钮
#   6. tools/check_versions.sh + make check
#   7. commit "chore(release): x.y.z" → 打 tag → push main 与 tag
#
# 第 6 步与 CI 发版路径是同一口径：tag 推上去之后，release.yml 先等
# 「被 tag 的那个 SHA」上 ci.yml 的全部必需检查都 success（tools/release_gate.sh，
# issue #42），才构建产物并发布。本地 make check 不过，tag 根本出不了这台机器；
# CI 必需检查不过，release 也发不出去 —— 两条路拦的是同一件事。
#
# 为什么不是「手写五个 sed」：版本号出现在五个文件、七条引用（VERSION、pot 头、
# README、site/index.md 与 site/en/index.md 的下载按钮与钉版本示例）且全是手抄的。
# 漏一处的后果不是报错，而是网页挂着上一版的下载按钮、README 教人装旧版 —— 而门禁
# 全绿。所以顺序固定、且有一步专门复查。
#
#   bash tools/release.sh 0.6.0              # 真发（push main + tag）
#   bash tools/release.sh 0.6.0 --dry-run    # 跑完全部本地步骤后把工作树还原
#   bash tools/release.sh 0.6.0 --no-push    # 只 commit + tag，不推
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VER=""
DRY=0
PUSH=1
BRANCH="${SHELLKIT_RELEASE_BRANCH:-main}"

_say() { printf '[release] %s\n' "$*" >&2; }
_die() {
  printf '[release] ERROR: %s\n' "$*" >&2
  exit "${2:-5}"
}
_usage() {
  printf '%s\n' \
    'usage: bash tools/release.sh <version> [--dry-run] [--no-push]' \
    '' \
    '  <version>   x.y.z，必须大于当前 VERSION' \
    '  --dry-run   跑完全部本地步骤（含 make check），然后把工作树还原' \
    '  --no-push   只提交与打 tag，不推远端'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h | --help)
      _usage
      exit 0
      ;;
    --dry-run) DRY=1 ;;
    --no-push) PUSH=0 ;;
    --?*)
      printf '[release] unknown option: %s\n' "$1" >&2
      _usage >&2
      exit 2
      ;;
    *)
      if [ -n "$VER" ]; then
        _die "only one version argument is allowed: $1" 2
      fi
      VER=$1
      ;;
  esac
  shift
done

if [ -z "$VER" ]; then
  _usage >&2
  exit 2
fi

# make 会把命令行变量（make release VERSION=x.y.z）导出给 recipe 的子进程，
# 而 install.sh 把**环境变量** VERSION 解释成「装这个版本」。留着它会污染
# 后面的 make check：测试里的 install.sh 会去下载一个还没发布的版本，报网络错（4）。
# 光 unset 不够 —— 子 make 会从 MAKEFLAGS 里把 VERSION=x.y.z 重新装回来，
# 所以下面调 make check 时要把这三个变量一起摘掉。
unset VERSION

# ---------- 1. 校验 ----------

# 允许 semver 预发布后缀：1.0.0-rc.1（发布 RC 用；后缀里的标识符用点分隔）
if ! printf '%s\n' "$VER" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?$'; then
  _die "version must look like x.y.z or x.y.z-pre: <$VER>" 2
fi

cd "$ROOT"

# git 的失败不许原样漏出去。三个坑都实测过：
#   · HEAD 解析不出来 ⇒ 原来直接漏 git 的 128 + "fatal: ambiguous argument 'HEAD'"
#     —— 操作者既不知道这个退出码是什么意思，也不知道下一步做什么
#     （真因：容器与宿主共用同一个 .git 时，宿主刚做的 git pull/gc 让 HEAD 短暂不可见）；
#   · git status 失败 ⇒ 命令替换把退出码吞掉、得到空串 ⇒ 判定成「工作树干净」
#     ⇒ 发版照跑 —— 这是**静默失效**，比报错危险得多；
#   · push 被拒 ⇒ docs/RELEASING.md 的退出码表写的是 1，代码却退 git 的 128。
#
# 现在所有 git 调用都过 _git_fail：拿到 git 的 stderr 原话，判成我们自己的退出码。
_GIT_ERR=$(mktemp "${TMPDIR:-/tmp}/shellkit-git.XXXXXX") || _die "mktemp failed" 1
trap 'rm -f "$_GIT_ERR"' EXIT

_git_fail() {
  local __cmd=$1
  local __code=${2:-1}
  printf '[release] ERROR: %s failed\n' "$__cmd" >&2
  if [ -s "$_GIT_ERR" ]; then
    sed -n '1,8p' "$_GIT_ERR" | sed 's/^/[release]   /' >&2
  fi
  if [ "$__code" = "3" ]; then
    printf '[release] the repository is not in a releasable state; fix it before releasing\n' >&2
    printf '[release] if you just ran git pull/gc/clone this may be an environment race (seen when a container shares the same .git): wait, then retry\n' >&2
  fi
  exit "$__code"
}

# 先赋值再比较：把 `|| true` 塞进 [ ] 里的 $( ) 会让 shellcheck 0.11 的解析器报 SC1073
if ! TOP=$(git rev-parse --show-toplevel 2>"$_GIT_ERR"); then
  _git_fail "git rev-parse --show-toplevel" 3
fi
if [ "$TOP" != "$ROOT" ]; then
  _die "not a git checkout: $ROOT" 3
fi

CUR="$(tr -d '[:space:]' <VERSION)"

# 版本比较：与 CHANGELOG 选基准共用同一份实现（口径不许有两份）
# shellcheck source=tools/ver_semver.sh
. "$ROOT/tools/ver_semver.sh"

_ver_gt "$VER" "$CUR" || _die "new version $VER must be greater than current $CUR" 2

if ! HEAD_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>"$_GIT_ERR"); then
  _git_fail "git rev-parse --abbrev-ref HEAD" 3
fi
if [ "$HEAD_BRANCH" != "$BRANCH" ]; then
  _die "release runs on $BRANCH, current branch is $HEAD_BRANCH" 3
fi

if ! STATUS_OUT=$(git status --porcelain 2>"$_GIT_ERR"); then
  _git_fail "git status --porcelain" 3
fi
if [ -n "$STATUS_OUT" ]; then
  _die "working tree is dirty; commit or stash first (git status --short)" 3
fi

if git rev-parse -q --verify "refs/tags/v$VER" >/dev/null 2>&1; then
  _die "tag v$VER already exists" 3
fi

if ! command -v xgettext >/dev/null 2>&1; then
  _die "xgettext is required to bump the pot header (brew install gettext / apt-get install gettext)" 3
fi

_say "$CUR -> $VER on $BRANCH"

# ---------- 2. 写 VERSION ----------

printf '%s\n' "$VER" >VERSION

# ---------- 2.5 CHANGELOG 追加本次发版的小节 ----------
#
# 变更记录不能手写：手写的 changelog 和 git 历史对不上，过几个月就没人信它了。
# 这里从「上一个 tag 到 HEAD」的提交自动生成，人只负责写 commit message。
_changelog_add() {
  local __ver=$1 __prev __date __tmp
  # 选「上一个已发布版本」：口径与 semver 一致（正式版 > 预发布），
  # 且 GA 发版时跳过预发布 tag（RC 与 GA 常常是同一批功能）。
  # 实现见 tools/changelog_prev.sh —— 单独成文件是为了能直接测它。
  __prev=$(bash "$ROOT/tools/changelog_prev.sh" "$__ver") || __prev=""
  __date=$(git log -1 --format=%ad --date=short 2>"$_GIT_ERR") || _git_fail "git log -1" 3
  __tmp=$(mktemp "${TMPDIR:-/tmp}/shellkit-changelog.XXXXXX") || _die 'mktemp failed' 1
  {
    printf '## %s — %s\n\n' "$__ver" "$__date"
    if [ -n "$__prev" ]; then
      git log --oneline --no-merges --reverse "$__prev..HEAD" |
        grep -v ' chore(release):' || true
    else
      git log --oneline --no-merges --reverse HEAD | grep -v ' chore(release):' || true
    fi
    printf '\n'
  } >"$__tmp"
  if [ ! -f CHANGELOG.md ]; then
    printf '# 变更记录\n\n本文件由 `tools/release.sh` 在发版时自动追加，已发布的小节不要手改。\n\n' >CHANGELOG.md
  fi
  # 插到第一个 "## " 小节之前（文件头之后、最新版本之前）
  awk -v sec="$__tmp" '
    !done && /^## / {
      while ((getline line < sec) > 0) print line
      close(sec)
      done = 1
    }
    { print }
  ' CHANGELOG.md >"$__tmp.out"
  if [ ! -s "$__tmp.out" ]; then
    cat CHANGELOG.md "$__tmp" >"$__tmp.out"
  fi
  mv -f "$__tmp.out" CHANGELOG.md
  rm -f "$__tmp"
}

_say "updating the changelog"
_changelog_add "$VER"

# ---------- 3/4. pot 与文档产物 ----------

_say "regenerating the pot"
bash po/messages.sh

_say "regenerating the documents"
./shellkit docs

# ---------- 5. README 与站点里的钉版本引用 ----------

_bump_refs() {
  local __f=$1
  if [ ! -f "$__f" ]; then
    _die "missing $__f" 3
  fi
  sed -E -i.bak \
    -e "s/VERSION=[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?/VERSION=$VER/g" \
    -e "s/下载 [0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?/下载 $VER/g" \
    -e "s/Download [0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?/Download $VER/g" \
    -e "s/shellkit-[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?\.tar\.gz/shellkit-$VER.tar.gz/g" \
    "$__f"
  rm -f "$__f.bak"
  # 站点的「下载 x.y.z」按钮：预发布要指向本 tag（releases/latest 只指向 GA）；
  # 正式版要把上一轮 RC 留下的 tag 链接改回 releases/latest。
  case "$VER" in
    *-*)
      sed -E -i.bak "s#(\*\*\[(下载|Download) $VER\]\()https://github\.com/yi-nology/shellkit/releases/latest#\1https://github.com/yi-nology/shellkit/releases/tag/v$VER#" "$__f"
      ;;
    *)
      sed -E -i.bak "s#https://github\.com/yi-nology/shellkit/releases/tag/v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?#https://github.com/yi-nology/shellkit/releases/latest#g" "$__f"
      ;;
  esac
  rm -f "$__f.bak"
}
_bump_refs README.md
_bump_refs site/index.md
_bump_refs site/en/index.md
_bump_refs site/guide/installation.md
_bump_refs site/en/guide/installation.md

# ---------- 6. 两道门 ----------

_say "checking version references"
bash tools/check_versions.sh

_say "running make check (this is the long part)"
if ! env -u VERSION -u MAKEFLAGS -u MFLAGS make check; then
  if [ "$DRY" = "1" ]; then
    git checkout -- . 2>"$_GIT_ERR" || _git_fail "git checkout -- ." 5
  fi
  _die "make check failed; fix it before releasing" 5
fi

if [ "$DRY" = "1" ]; then
  git checkout -- . 2>"$_GIT_ERR" || _git_fail "git checkout -- ." 5
  _say "dry run finished: every step passed, working tree restored"
  _say "next: bash tools/release.sh $VER"
  exit 0
fi

# ---------- 7. 提交、打 tag、推 ----------

_say "committing"
git add -A 2>"$_GIT_ERR" || _git_fail "git add -A" 5
git commit -m "chore(release): $VER" >/dev/null 2>"$_GIT_ERR" || _git_fail "git commit" 5
git tag -a "v$VER" -m "shellkit $VER" 2>"$_GIT_ERR" || _git_fail "git tag" 5

if [ "$PUSH" = "1" ]; then
  _say "pushing $BRANCH and v$VER"
  # push 失败退 1（docs/RELEASING.md 的退出码表）：tag 没推上去 ⇒
  # release.yml 没被触发 ⇒ 不会留下半个 Release。
  git push origin "HEAD:$BRANCH" 2>"$_GIT_ERR" || _git_fail "git push origin HEAD:$BRANCH" 1
  git push origin "v$VER" 2>"$_GIT_ERR" || _git_fail "git push origin v$VER" 1
else
  _say "skipped the push (--no-push); push by hand:"
  printf '    git push origin %s\n    git push origin v%s\n' "$BRANCH" "$VER" >&2
fi

printf '\n'
_say "released $VER"
printf '    tag      v%s\n' "$VER"
printf '    notes    https://github.com/yi-nology/shellkit/releases/tag/v%s\n' "$VER"
printf '    assets   https://github.com/yi-nology/shellkit/releases/download/v%s/\n' "$VER"
printf '    watch    gh run list --workflow=release.yml --limit 1\n'
