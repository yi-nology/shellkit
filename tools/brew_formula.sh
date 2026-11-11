#!/usr/bin/env bash
#
# 生成 Homebrew formula。
#
#   bash tools/brew_formula.sh --out FILE [--version V] [--sha256 SUM] [--tarball FILE]
#
# 为什么要有这个工具：formula 里钉死的 sha256 必须跟**已发布**的那个 tarball
# 逐字节一致。手抄 sha256 必错 —— 错了的表现是 brew install 报
# "Checksum mismatch"，用户只会以为下载被劫持了。
#
# 所以 sha256 只有两个来源：
#   --sha256 SUM      已经知道校验和（比如从 release 的 SHA256SUMS 里读的）
#   --tarball FILE    本地就有那个 tarball，直接算
#
# 发版后的回填流程见 docs/RELEASING.md。
#
# 产物只落在 tap 仓的 Formula/（yi-nology/homebrew-shellkit）——
#
# 本仓**不存**一份：formula 里钉死的 sha256 每个版本都变，仓里留一份就是
# 一份必然过期的副本（下次发版就会红）。真相源永远是 release 的 SHA256SUMS。
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT=""
VER=""
SHA=""
TARBALL=""

die() {
  printf 'brew_formula: %s\n' "$1" >&2
  exit "${2:-1}"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --out)
      shift
      [ "$#" -gt 0 ] || die "--out requires a value" 2
      OUT=$1
      ;;
    --out=*) OUT="${1#*=}" ;;
    --version)
      shift
      [ "$#" -gt 0 ] || die "--version requires a value" 2
      VER=$1
      ;;
    --version=*) VER="${1#*=}" ;;
    --sha256)
      shift
      [ "$#" -gt 0 ] || die "--sha256 requires a value" 2
      SHA=$1
      ;;
    --sha256=*) SHA="${1#*=}" ;;
    --tarball)
      shift
      [ "$#" -gt 0 ] || die "--tarball requires a value" 2
      TARBALL=$1
      ;;
    --tarball=*) TARBALL="${1#*=}" ;;
    -h | --help)
      printf 'usage: brew_formula.sh --out FILE [--version V] [--sha256 SUM] [--tarball FILE]\n' >&2
      exit 0
      ;;
    *)
      die "unknown option: $1" 2
      ;;
  esac
  shift
done

[ -n "$OUT" ] || die "--out is required" 2

if [ -z "$VER" ]; then
  [ -r "$ROOT/VERSION" ] || die "missing $ROOT/VERSION" 3
  VER=$(tr -d '[:space:]' <"$ROOT/VERSION")
fi
[ -n "$VER" ] || die "the version is empty" 3

if [ -z "$SHA" ] && [ -n "$TARBALL" ]; then
  [ -f "$TARBALL" ] || die "missing tarball: $TARBALL" 3
  if command -v sha256sum >/dev/null 2>&1; then
    SHA=$(sha256sum "$TARBALL" | awk '{print $1}')
  elif command -v shasum >/dev/null 2>&1; then
    SHA=$(shasum -a 256 "$TARBALL" | awk '{print $1}')
  elif command -v openssl >/dev/null 2>&1; then
    SHA=$(openssl dgst -sha256 "$TARBALL" | awk '{print $NF}')
  else
    die "no sha256 tool found (sha256sum, shasum or openssl)" 3
  fi
fi
[ -n "$SHA" ] || die "no sha256 given (use --sha256 or --tarball)" 3

case "$SHA" in
  [0-9a-fA-F]*) ;;
  *) die "the sha256 looks wrong: $SHA" 2 ;;
esac

mkdir -p "$(dirname "$OUT")" || die "cannot create the output directory" 1

{
  cat <<'RUBY'
# shellkit —— 写运维 shell 的起点：Bash 库 + 脚手架生成器 + CLI 框架。
#
# 这个文件是**生成物**：改它没用，下次发版会被 tools/brew_formula.sh 覆盖。
# 要改内容就改生成器（tools/brew_formula.sh）。
class Shellkit < Formula
  desc "Bash library and project scaffolding generator (Bash 3.2 baseline)"
  homepage "https://yi-nology.github.io/shellkit/"
RUBY
  printf '  version "%s"\n' "$VER"
  printf '  url "https://github.com/yi-nology/shellkit/releases/download/v%s/shellkit-%s.tar.gz"\n' "$VER" "$VER"
  printf '  sha256 "%s"\n' "$SHA"
  cat <<'RUBY'

  def install
    # 库、模板、语言包、文档、skill 包 —— CLI 靠自己在旁边的目录里找它们
    %w[lib templates locale po tools docs skills].each do |dir|
      libexec.install dir
    end
    libexec.install "shellkit"
    libexec.install "README.md" if File.exist?("README.md")
    libexec.install "LICENSE" if File.exist?("LICENSE")
    libexec.install "NOTICE" if File.exist?("NOTICE")
    bin.install_symlink libexec/"shellkit"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/shellkit --version")
    assert_match "library modules", shell_output("#{bin}/shellkit list")
  end
end
RUBY
} >"$OUT.tmp.$$" || die "cannot write $OUT" 1
mv -f "$OUT.tmp.$$" "$OUT" || die "cannot write $OUT" 1

printf 'brew_formula: wrote %s (version %s)\n' "$OUT" "$VER" >&2
exit 0
