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
# 为什么不是「手写五个 sed」：版本号出现在六处（VERSION、pot 头、README、站点的
# 下载按钮与钉版本示例）且全是手抄的。漏一处的后果不是报错，而是网页挂着上一版的
# 下载按钮、README 教人装旧版 —— 而门禁全绿。所以顺序固定、且有一步专门复查。
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
unset VERSION

# ---------- 1. 校验 ----------

if ! printf '%s\n' "$VER" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  _die "version must look like x.y.z: <$VER>" 2
fi

cd "$ROOT"

# 先赋值再比较：把 `|| true` 塞进 [ ] 里的 $( ) 会让 shellcheck 0.11 的解析器报 SC1073
TOP=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ "$TOP" != "$ROOT" ]; then
  _die "not a git checkout: $ROOT" 3
fi

CUR="$(tr -d '[:space:]' <VERSION)"

# _ver_gt A B —— A > B 时返回 0（不走 sort -V：BSD sort 没有它）
_ver_gt() {
  local __a=$1 __b=$2 __i=1 __x __y
  while [ "$__i" -le 3 ]; do
    __x=$(printf '%s' "$__a" | cut -d. -f"$__i")
    __y=$(printf '%s' "$__b" | cut -d. -f"$__i")
    if [ "${__x:-0}" -gt "${__y:-0}" ]; then
      return 0
    fi
    if [ "${__x:-0}" -lt "${__y:-0}" ]; then
      return 1
    fi
    __i=$((__i + 1))
  done
  return 1
}

_ver_gt "$VER" "$CUR" || _die "new version $VER must be greater than current $CUR" 2

HEAD_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$HEAD_BRANCH" != "$BRANCH" ]; then
  _die "release runs on $BRANCH, current branch is $HEAD_BRANCH" 3
fi

if [ -n "$(git status --porcelain)" ]; then
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
    -e "s/VERSION=[0-9]+\.[0-9]+\.[0-9]+/VERSION=$VER/g" \
    -e "s/下载 [0-9]+\.[0-9]+\.[0-9]+/下载 $VER/g" \
    "$__f"
  rm -f "$__f.bak"
}
_bump_refs README.md
_bump_refs site/index.html

# ---------- 6. 两道门 ----------

_say "checking version references"
bash tools/check_versions.sh

_say "running make check (this is the long part)"
if ! make check; then
  if [ "$DRY" = "1" ]; then
    git checkout -- .
  fi
  _die "make check failed; fix it before releasing" 5
fi

if [ "$DRY" = "1" ]; then
  git checkout -- .
  _say "dry run finished: every step passed, working tree restored"
  _say "next: bash tools/release.sh $VER"
  exit 0
fi

# ---------- 7. 提交、打 tag、推 ----------

_say "committing"
git add -A
git commit -m "chore(release): $VER" >/dev/null
git tag -a "v$VER" -m "shellkit $VER"

if [ "$PUSH" = "1" ]; then
  _say "pushing $BRANCH and v$VER"
  git push origin "HEAD:$BRANCH"
  git push origin "v$VER"
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
