#!/usr/bin/env bash
#
# 构建发布 tarball：shellkit-<ver>.tar.gz + shellkit-skill-<ver>.tar.gz + SHA256SUMS。
#
#   bash tools/package_tarball.sh                     # 版本取 VERSION 文件，输出到 dist/
#   bash tools/package_tarball.sh --dist out --version 1.2.3
#
# 为什么单独成脚本：release.yml 的 build 段与 packages.yml 都要打这份 tarball。
# 内联两份 cp 清单必然漂移（0.13.0 漏 CHANGELOG、v0.15.0 漏 tests/ 都是清单改漏），
# 所以打包清单只维护这一处 —— tarball 是唯一真相源（issue #65）。
#
# 退出码：0 成功 / 1 一般错误 / 2 用法错 / 3 前置条件不满足（缺源文件）
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dist=dist
version=""

die() {
  printf '[FAIL] %s\n' "$1" >&2
  exit "${2:-1}"
}

usage() {
  printf 'Usage: bash tools/package_tarball.sh [--dist DIR] [--version X.Y.Z]\n' >&2
}

while [ "$#" -gt 0 ]; do
  case $1 in
    --dist)
      [ "$#" -ge 2 ] || {
        usage
        exit 2
      }
      dist=$2
      shift
      ;;
    --version)
      [ "$#" -ge 2 ] || {
        usage
        exit 2
      }
      version=$2
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf 'package_tarball: unknown option: %s\n' "$1" >&2
      usage
      exit 2
      ;;
  esac
  shift
done

cd "$ROOT" || die "cannot cd into $ROOT" 1
[ -f VERSION ] || die "VERSION file not found in $ROOT" 3
[ -n "$version" ] || version=$(tr -d '[:space:]' <VERSION)

name="shellkit-$version"
rm -rf "${dist:?}/${name:?}"
mkdir -p "$dist/$name" || die "cannot create $dist/$name" 1

# 只放跑起来需要的东西：生成器、库、模板、语言包、文档、测试
# 少拷一个目录，smoke test 要到几百行之后才会以 127 的形式炸掉 ——
# 0.13.0 漏了 CHANGELOG、v0.15.0 漏了 tests/，两次都是这么红的。
# 所以清单原样保留在这里，且 cp 自带逐项点名（缺哪个源就报哪个）。
cp -R shellkit install.sh repair.sh demo.sh lib templates locale po tools tests docs skills examples "$dist/$name/" ||
  die "cannot copy the release tree (see which path above is missing)" 3
cp README.md AGENTS.md VERSION LICENSE NOTICE Makefile CHANGELOG.md "$dist/$name/" ||
  die "cannot copy the top-level files (see which path above is missing)" 3
rm -rf "$dist/$name/docs/superpowers"
chmod +x "$dist/$name/shellkit" "$dist/$name/install.sh" "$dist/$name/repair.sh" "$dist/$name/demo.sh"
tar -C "$dist" -czf "$dist/$name.tar.gz" "$name" || die "cannot build $dist/$name.tar.gz" 1

# skill 包单独打一个 tarball：装进 AI 客户端的就是这个目录
# （SKILL.md + references/）。混在主包里的话，用户得自己拆目录，
# 还得知道 references/ 是什么 —— 「装一下」的门槛不该这么高。
rm -rf "$dist/skill"
mkdir -p "$dist/skill"
cp -R skills/shellkit "$dist/skill/shellkit" || die "cannot copy skills/shellkit" 3
tar -C "$dist/skill" -czf "$dist/shellkit-skill-$version.tar.gz" shellkit ||
  die "cannot build $dist/shellkit-skill-$version.tar.gz" 1

(cd "$dist" && sha256sum "$name.tar.gz" "shellkit-skill-$version.tar.gz" >SHA256SUMS) ||
  die "cannot write $dist/SHA256SUMS" 1
cat "$dist/SHA256SUMS"
exit 0
