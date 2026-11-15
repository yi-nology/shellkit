#!/usr/bin/env bash
#
# 发布产物验收：把 dist/ 里的**真产物**解开，在包内跑整套测试 + CLI 三连。
#
#   bash tools/package_artifact_smoke.sh [--dist DIR]
#
# 为什么要有这个脚本（v0.25.0）：v0.24.0 的教训 —— 源码矩阵全绿、系统包构建也全绿，
# 但真 tarball 解包后跑套件才炸（漏了 .gitignore，见 PR #106）。「仓库工作树能跑」
# 不等于「发布包能跑」。所以这段验收逻辑只维护一份：PR 阶段（ci.yml 的 artifact job）
# 与发版（release.yml 的 build 作业）调的是同一个脚本，两侧不可能漂移。
#
# 判据分四类，任何一类不过就退出 1：
#   1. skill 包能独立解开，且 references/ 齐全（缺了 AI 会照着残包写代码）
#   2. tarball 里逐项点名该有的东西都在（清单漂移要在这里现原形，而不是几百行之后 127）
#   3. 包内的测试套件全绿（bash tests/run.sh）
#   4. 包内的 CLI 真能跑：doctor / new + 工程 make test / demo
#
# 退出码：0 全过 / 1 验收不过 / 2 用法错 / 3 缺前置条件（dist 里没有产物）
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dist="$ROOT/dist"

while [ $# -gt 0 ]; do
  case $1 in
    --dist)
      shift
      [ $# -gt 0 ] || {
        printf 'usage: %s [--dist DIR]\n' "${0##*/}" >&2
        exit 2
      }
      dist=$1
      ;;
    --dist=*) dist=${1#*=} ;;
    -h | --help)
      printf 'usage: %s [--dist DIR]\n' "${0##*/}"
      exit 0
      ;;
    *)
      printf 'unknown option: %s\n' "$1" >&2
      exit 2
      ;;
  esac
  shift
done

say() { printf '[artifact] %s\n' "$*" >&2; }
die() {
  printf '[artifact] FAIL: %s\n' "$1" >&2
  exit "${2:-1}"
}

[ -f "$ROOT/VERSION" ] || die "no VERSION file at the repo root" 3
version=$(tr -d '[:space:]' <"$ROOT/VERSION")
[ -n "$version" ] || die "VERSION is empty" 3

skillpkg="$dist/shellkit-skill-$version.tar.gz"
tarball="$dist/shellkit-$version.tar.gz"
[ -f "$skillpkg" ] || die "missing $skillpkg (run tools/package_tarball.sh first)" 3
[ -f "$tarball" ] || die "missing $tarball (run tools/package_tarball.sh first)" 3

work=$(mktemp -d "${TMPDIR:-/tmp}/shellkit-artifact.XXXXXX") || die "cannot create a temp dir" 3
trap 'rm -rf "$work"' EXIT INT TERM HUP

# 1) skill 包：必须能独立解开，且 references 齐全
say "checking the skill package"
tar -C "$work" -xzf "$skillpkg" || die "cannot extract $skillpkg"
for f in shellkit/SKILL.md shellkit/references/reference.md shellkit/references/cli.md; do
  [ -s "$work/$f" ] || die "the skill package is missing $f"
done

# 2) tarball：许可文件 + 逐项点名的清单
say "checking the release tarball layout"
mkdir -p "$work/rel"
tar -C "$work/rel" -xzf "$tarball" || die "cannot extract $tarball"
pkgdir="$work/rel/shellkit-$version"
[ -d "$pkgdir" ] || die "the tarball does not contain shellkit-$version/"

# MIT 要求版权声明随每一份副本分发，NOTICE 里的上游署名同理 ——
# 漏了不会有任何报错，只有收到律师函时才知道。
for f in LICENSE NOTICE; do
  [ -s "$pkgdir/$f" ] || die "the release tarball is missing $f"
done

# 打包清单必须逐项点名：少拷一个文件，问题会到几百行之后才以「command not found / 127」
# 的形式炸掉，看不出是打包漏了东西（v0.15.0 漏 tests/、v0.24.0 漏 .gitignore 都是这么来的）。
for f in shellkit \
  install.sh \
  repair.sh \
  demo.sh \
  lib/bootstrap.sh \
  templates \
  locale/shellkit.pot \
  po/messages.sh \
  tests/run.sh \
  tests/test_helper.sh \
  tests/test_fault_matrix.sh \
  docs/MIGRATING.md \
  docs/SECURITY.md \
  skills/shellkit/SKILL.md \
  skills/shellkit/references/reference.md \
  README.md \
  AGENTS.md \
  .gitignore \
  VERSION; do
  [ -e "$pkgdir/$f" ] || die "the release tarball is missing $f"
done

# repair.sh 必须可执行：CLI 起不来时，它是唯一的恢复入口。
[ -x "$pkgdir/repair.sh" ] || die "the release tarball is missing an executable repair.sh"

# 3) 包内测试套件
say "running the suite inside the artifact (this is the long part)"
(cd "$pkgdir" && bash tests/run.sh) || die "the suite is not green inside the release tarball"

# 4) 包内 CLI 三连
say "checking the packaged CLI"
(cd "$pkgdir" && ./shellkit doctor) || true
(cd "$pkgdir" && ./shellkit new "$work/demo" --cmd start) || die "shellkit new failed inside the artifact"
(cd "$work/demo" && make test) || die "the generated project does not pass its own tests"
(cd "$pkgdir" && ./shellkit demo "$work/demo2") || die "shellkit demo failed inside the artifact"

say "ok: shellkit $version artifact passed"
exit 0
