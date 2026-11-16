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
# .gitignore 也要随包走：tests/test_gitignore.sh 会读它（把规则重放进一个一次性
# git 仓库再问 git 自己「.env / 私钥会不会被带走」）。漏了它，发布 tarball 里的
# smoke（release.yml 解包后跑 tests/run.sh）必红 —— v0.24.0 就是在这一步现的原形：
# cp: cannot stat '…/shellkit-0.24.0/.gitignore' → FAIL: .gitignore 必须忽略凭据…
cp README.md AGENTS.md VERSION LICENSE NOTICE Makefile CHANGELOG.md .gitignore "$dist/$name/" ||
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

# 校验和要覆盖**每一个**直接分发的文件，不只是两个 tarball：install.sh / repair.sh /
# demo.sh 都是用户会直接执行的脚本，只给 tarball 出校验和 = 「同一个版本、不同渠道、
# 不同完整性保证」（评估 2026-11-16）。脚本本身留在仓库根（发布资产取的就是根上那份），
# 这里只把它们的摘要一并写进清单。
sums=("$name.tar.gz" "shellkit-skill-$version.tar.gz")
for __f in install.sh repair.sh demo.sh; do
  if [ -f "$ROOT/$__f" ]; then
    sums[${#sums[@]}]="$__f"
  fi
done
: >"$dist/SHA256SUMS" || die "cannot write $dist/SHA256SUMS" 1
for __f in "${sums[@]}"; do
  if [ -f "$dist/$__f" ]; then
    (cd "$dist" && sha256sum "$__f") >>"$dist/SHA256SUMS" || die "cannot add $__f to SHA256SUMS" 1
  else
    (cd "$ROOT" && sha256sum "$__f") >>"$dist/SHA256SUMS" || die "cannot add $__f to SHA256SUMS" 1
  fi
done
cat "$dist/SHA256SUMS"
exit 0
