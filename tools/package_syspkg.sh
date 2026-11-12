#!/usr/bin/env bash
#
# deb / rpm 系统包：tarball 是唯一真相源，包只是它的另一种封装（issue #65）。
#
#   bash tools/package_syspkg.sh --tarball dist/shellkit-1.2.3.tar.gz [--out dist] deb
#   bash tools/package_syspkg.sh --tarball dist/shellkit-1.2.3.tar.gz [--out dist] rpm
#   bash tools/package_syspkg.sh --tarball dist/shellkit-1.2.3.tar.gz --stage DIR
#   bash tools/package_syspkg.sh --verify-prefix DIR [--tarball FILE]
#
# 布局（不引入第二份内容）：
#   /usr/lib/shellkit   tarball 解开后的完整子树（与 tarball 逐字节一致）
#   /usr/bin/shellkit   -> ../lib/shellkit/shellkit（软链，内容只有一份）
#
# 可分段验证：--stage 只铺文件树 + 逐项点名自检 + 与 tarball 的逐文件比对，
# 不依赖 dpkg-deb / rpmbuild —— 没有打包工具的机器（macOS）也能验「内容一致」
# 这一半；「真实构建 + 装上跑通 + 卸干净」由 tools/package_smoke.sh 在 CI 验。
#
# 自检为什么逐项点名（release.yml 里的教训）：少拷一个目录，smoke test 要到
# 几百行之后才会以 127 的形式炸掉，看不出是打包漏了东西。这里每个关键路径都
# 单独报名字，缺哪个当场点名哪个；模块清单按 lib/modules.txt 逐个点名。
#
# 退出码：0 成功 / 1 一般错误 / 2 用法错 / 3 缺工具（dpkg-deb / rpmbuild）/
#         5 校验失败（逐项自检、版本对不上、或与 tarball 一致性比对不过）
set -u

PROG=package_syspkg.sh
tarball=""
out_dir="dist"
action=""
stage_dir=""
prefix_dir=""
tmp=""
extracted_root=""
ver=""
_checked=0
_missing=0

say() { printf '[pkg] %s\n' "$*" >&2; }
ok() { printf '[ OK ] %s\n' "$*" >&2; }

die() {
  printf '[FAIL] %s\n' "$1" >&2
  exit "${2:-1}"
}

usage() {
  {
    printf 'Usage:\n'
    printf '  bash %s --tarball FILE [--out DIR] deb        build a .deb\n' "$PROG"
    printf '  bash %s --tarball FILE [--out DIR] rpm        build a .rpm\n' "$PROG"
    printf '  bash %s --tarball FILE --stage DIR            stage the file tree + run the named checks only\n' "$PROG"
    printf '  bash %s --verify-prefix DIR [--tarball FILE]  run the named checks against an installed prefix\n' "$PROG"
    printf '\n'
    printf 'Exit codes: 0 ok / 1 error / 2 usage / 3 missing tool / 5 verification failed\n'
  } >&2
}

while [ "$#" -gt 0 ]; do
  case $1 in
    --tarball)
      [ "$#" -ge 2 ] || {
        usage
        exit 2
      }
      tarball=$2
      shift
      ;;
    --out)
      [ "$#" -ge 2 ] || {
        usage
        exit 2
      }
      out_dir=$2
      shift
      ;;
    --stage)
      [ "$#" -ge 2 ] || {
        usage
        exit 2
      }
      stage_dir=$2
      action=stage
      shift
      ;;
    --verify-prefix)
      [ "$#" -ge 2 ] || {
        usage
        exit 2
      }
      prefix_dir=$2
      action=verify
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      printf '%s: unknown option: %s\n' "$PROG" "$1" >&2
      usage
      exit 2
      ;;
    *)
      [ -z "$action" ] || {
        printf '%s: unexpected argument: %s\n' "$PROG" "$1" >&2
        usage
        exit 2
      }
      action=$1
      ;;
  esac
  shift
done

case $action in
  deb | rpm | stage | verify) ;;
  '')
    usage
    exit 2
    ;;
  *)
    printf '%s: unknown action: %s\n' "$PROG" "$action" >&2
    usage
    exit 2
    ;;
esac

# ---------------------------------------------------------------- 逐项点名自检
# _req_* 的入参一律是绝对路径；缺了就点名到具体文件（issue #65 的「逐项点名」）。
_req_file() {
  _checked=$((_checked + 1))
  if [ ! -f "$1" ]; then
    printf 'package check: MISSING file: %s\n' "$1" >&2
    _missing=$((_missing + 1))
  fi
}

_req_exec() {
  _checked=$((_checked + 1))
  if [ ! -x "$1" ]; then
    printf 'package check: NOT EXECUTABLE (or missing): %s\n' "$1" >&2
    _missing=$((_missing + 1))
  fi
}

_req_dir() {
  _checked=$((_checked + 1))
  if [ ! -d "$1" ]; then
    printf 'package check: MISSING directory: %s\n' "$1" >&2
    _missing=$((_missing + 1))
  fi
}

# _req_symlink PATH TARGET —— 必须是软链且指向 TARGET；拷成实体文件也过不了
_req_symlink() {
  _checked=$((_checked + 1))
  if [ ! -L "$1" ]; then
    printf 'package check: NOT A SYMLINK (or missing): %s\n' "$1" >&2
    _missing=$((_missing + 1))
    return 0
  fi
  if [ "$(readlink "$1")" != "$2" ]; then
    printf 'package check: SYMLINK POINTS ELSEWHERE: %s -> %s (want %s)\n' \
      "$1" "$(readlink "$1")" "$2" >&2
    _missing=$((_missing + 1))
  fi
}

# _verify_prefix PREFIX —— 逐项点名 + 真跑一次 shellkit --version
# PREFIX 是同时含 bin/ 与 lib/ 的前缀（stage 里是 .../usr，装完之后是 /usr）。
_verify_prefix() {
  local __p=$1 __root="$1/lib/shellkit" __line __name __got __want
  _checked=0
  _missing=0
  say "named checks under: $__p"

  _req_symlink "$__p/bin/shellkit" "../lib/shellkit/shellkit"
  _req_exec "$__root/shellkit"
  _req_exec "$__root/install.sh"
  _req_exec "$__root/repair.sh"
  _req_exec "$__root/demo.sh"
  _req_file "$__root/lib/bootstrap.sh"
  _req_file "$__root/lib/modules.txt"
  _req_dir "$__root/templates"
  _req_file "$__root/locale/shellkit.pot"
  _req_file "$__root/po/messages.sh"
  _req_file "$__root/tests/run.sh"
  _req_file "$__root/tests/test_helper.sh"
  _req_file "$__root/docs/REFERENCE.md"
  _req_file "$__root/docs/MIGRATING.md"
  _req_file "$__root/skills/shellkit/SKILL.md"
  _req_file "$__root/skills/shellkit/references/reference.md"
  _req_file "$__root/README.md"
  _req_file "$__root/AGENTS.md"
  _req_file "$__root/VERSION"
  _req_file "$__root/LICENSE"
  _req_file "$__root/NOTICE"
  _req_file "$__root/Makefile"
  _req_file "$__root/CHANGELOG.md"

  # 模块按 lib/modules.txt 逐个点名：它是模块的唯一真相源，
  # 少打一个 .sh 就是「装完之后 doctor 才炸」的经典路径。
  if [ -f "$__root/lib/modules.txt" ]; then
    while IFS= read -r __line || [ -n "$__line" ]; do
      __line=${__line%%#*}
      case $__line in
        '' | '#'*) continue ;;
      esac
      __name=${__line%%[[:space:]]*}
      [ -n "$__name" ] || continue
      _req_file "$__root/lib/core/$__name.sh"
    done <"$__root/lib/modules.txt"
  fi

  # 版本要真的跑得出来，且与包内 VERSION 一致 —— 装完跑不通只有真跑才知道
  _checked=$((_checked + 1))
  __want=$(tr -d '[:space:]' <"$__root/VERSION" 2>/dev/null || true)
  __got=$("$__p/bin/shellkit" --version 2>/dev/null) || __got=""
  if [ -z "$__got" ]; then
    printf 'package check: RUNNING FAILED: %s --version produced no output\n' "$__p/bin/shellkit" >&2
    _missing=$((_missing + 1))
  elif [ "$__got" != "$__want" ]; then
    printf 'package check: VERSION MISMATCH: %s --version says %s, package VERSION says %s\n' \
      "$__p/bin/shellkit" "$__got" "$__want" >&2
    _missing=$((_missing + 1))
  fi

  if [ "$_missing" -ne 0 ]; then
    die "named checks failed: $_missing of $_checked items under $__p" 5
  fi
  ok "named checks passed: $_checked items (every module in lib/modules.txt named, shellkit $__got runs)"
}

# _check_consistency SRC DST —— DST 与 tarball 解开的 SRC 必须逐字节一致
# 这是「同一真相源、不引入第二份内容」的机器判据。
_check_consistency() {
  local __src=$1 __dst=$2
  if diff -r "$__src" "$__dst" >"$tmp/diff.out" 2>&1; then
    ok "consistent with the tarball: diff -r found no differences"
    return 0
  fi
  printf 'package check: content differs from the tarball:\n' >&2
  sed 's/^/    /' "$tmp/diff.out" >&2
  die "the staged tree is not byte-identical to the tarball (single source of truth violated)" 5
}

# ---------------------------------------------------------------- tarball → 树
# _extract DEST —— 解包并定位包根；设置 extracted_root 与 ver
_extract() {
  local __dest=$1 __d __bn __inside
  [ -n "$tarball" ] || die "--tarball FILE is required for this action" 2
  [ -f "$tarball" ] || die "tarball not found: $tarball" 3
  mkdir -p "$__dest" || die "cannot create $__dest" 1
  tar -C "$__dest" -xzf "$tarball" || die "cannot extract $tarball" 5

  extracted_root=""
  for __d in "$__dest"/*/; do
    if [ -f "${__d}shellkit" ] && [ -d "${__d}lib" ]; then
      extracted_root=${__d%/}
    fi
  done
  if [ -z "$extracted_root" ] && [ -f "$__dest/shellkit" ] && [ -d "$__dest/lib" ]; then
    extracted_root=$__dest
  fi
  [ -n "$extracted_root" ] || die "the archive does not look like a shellkit release: $tarball" 5

  __inside=$(tr -d '[:space:]' <"$extracted_root/VERSION" 2>/dev/null || true)
  [ -n "$__inside" ] || die "the tarball has no readable VERSION" 5
  ver=$__inside
  __bn=${tarball##*/}
  case $__bn in
    shellkit-*.tar.gz)
      if [ "${__bn#shellkit-}" != "$ver.tar.gz" ]; then
        die "VERSION inside the tarball ($ver) does not match its file name ($__bn)" 5
      fi
      ;;
  esac
}

# _stage DEST —— 把包根铺进 DEST/usr/{lib/shellkit,bin/shellkit}
_stage() {
  local __s=$1
  rm -rf "$__s"
  mkdir -p "$__s/usr/lib/shellkit" "$__s/usr/bin" || die "cannot create the stage tree under $__s" 1
  cp -R -p "$extracted_root/." "$__s/usr/lib/shellkit/" || die "cannot stage the tarball into $__s" 1
  ln -s ../lib/shellkit/shellkit "$__s/usr/bin/shellkit" || die "cannot create the bin/shellkit symlink" 1
}

# ---------------------------------------------------------------- 打包
_build_deb() {
  local __stage=$1 __out=$2
  command -v dpkg-deb >/dev/null 2>&1 ||
    die "dpkg-deb not found (install it with: apt-get install dpkg-dev) — run --stage to check content without it" 3
  mkdir -p "$__stage/DEBIAN" || die "cannot create the DEBIAN control directory" 1
  cat >"$__stage/DEBIAN/control" <<EOF
Package: shellkit
Version: $ver
Section: devel
Priority: optional
Architecture: all
Maintainer: shellkit maintainers <yi-nology@users.noreply.github.com>
Homepage: https://github.com/yi-nology/shellkit
Depends: bash
Description: shellkit - bash 3.2+ library and project scaffold generator
 shellkit ships a tested bash library (log, config, fs, net, retry, lock, cli, i18n)
 and a generator that scaffolds testable ops scripts. Everything lives under
 /usr/lib/shellkit; /usr/bin/shellkit is a symlink into it, so the content is
 exactly the release tarball — no second copy. Upgrade with your package manager,
 not with "shellkit update".
EOF
  dpkg-deb --build --root-owner-group "$__stage" "$__out" >&2 ||
    die "dpkg-deb failed to build $__out" 1
}

_build_rpm() {
  local __stage=$1 __out=$2 __top="$tmp/rpmbuild" __found=""
  command -v rpmbuild >/dev/null 2>&1 ||
    die "rpmbuild not found (install it with: apt-get install rpm / dnf install rpm-build) — run --stage to check content without it" 3
  mkdir -p "$__top/BUILD" "$__top/BUILDROOT" "$__top/RPMS" "$__top/SOURCES" "$__top/SPECS" "$__top/SRPMS" ||
    die "cannot create the rpmbuild tree" 1
  # spec 是 heredoc 模板：$__stage 是真实 stage 路径，%{buildroot} 留给 rpm 展开。
  cat >"$__top/SPECS/shellkit.spec" <<EOF
Name: shellkit
Version: $ver
Release: 1
Summary: bash 3.2+ library and project scaffold generator
License: MIT
URL: https://github.com/yi-nology/shellkit
BuildArch: noarch
Requires: bash

%description
shellkit ships a tested bash library (log, config, fs, net, retry, lock, cli, i18n)
and a generator that scaffolds testable ops scripts. Everything lives under
/usr/lib/shellkit; /usr/bin/shellkit is a symlink into it, so the content is
exactly the release tarball — no second copy. Upgrade with your package manager,
not with "shellkit update".

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}
cp -R -p "$__stage/." %{buildroot}/

%files
%defattr(-,root,root,-)
/usr/lib/shellkit
/usr/bin/shellkit
EOF
  rpmbuild -bb --define "_topdir $__top" "$__top/SPECS/shellkit.spec" >&2 ||
    die "rpmbuild failed to build the rpm" 1
  find "$__top/RPMS" -type f -name "shellkit-$ver-*.rpm" >"$__top/found"
  IFS= read -r __found <"$__top/found"
  [ -n "$__found" ] || die "rpmbuild reported success but no rpm was produced" 1
  cp -p "$__found" "$__out" || die "cannot copy the rpm to $__out" 1
}

# ---------------------------------------------------------------- 主流程
case $action in
  verify)
    [ -n "$prefix_dir" ] || die "--verify-prefix DIR is required" 2
    [ -d "$prefix_dir" ] || die "prefix not found: $prefix_dir" 3
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/shellkit-pkg.XXXXXX") || die "cannot create a temporary directory" 1
    trap 'rm -rf "${tmp:?}"' EXIT INT TERM
    if [ -n "$tarball" ]; then
      _extract "$tmp/x"
      _verify_prefix "$prefix_dir"
      _check_consistency "$extracted_root" "$prefix_dir/lib/shellkit"
    else
      _verify_prefix "$prefix_dir"
    fi
    printf '%s\n' "ok"
    ;;
  stage)
    [ -n "$tarball" ] || die "--tarball FILE is required with --stage" 2
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/shellkit-pkg.XXXXXX") || die "cannot create a temporary directory" 1
    trap 'rm -rf "${tmp:?}"' EXIT INT TERM
    _extract "$tmp/x"
    _stage "$stage_dir"
    _verify_prefix "$stage_dir/usr"
    _check_consistency "$extracted_root" "$stage_dir/usr/lib/shellkit"
    printf '%s\n' "$stage_dir"
    ;;
  deb | rpm)
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/shellkit-pkg.XXXXXX") || die "cannot create a temporary directory" 1
    trap 'rm -rf "${tmp:?}"' EXIT INT TERM
    _extract "$tmp/x"
    _stage "$tmp/stage"
    _verify_prefix "$tmp/stage/usr"
    _check_consistency "$extracted_root" "$tmp/stage/usr/lib/shellkit"
    mkdir -p "$out_dir" || die "cannot create $out_dir" 1
    if [ "$action" = deb ]; then
      _build_deb "$tmp/stage" "$out_dir/shellkit-$ver.deb"
      printf '%s\n' "$out_dir/shellkit-$ver.deb"
    else
      _build_rpm "$tmp/stage" "$out_dir/shellkit-$ver.rpm"
      printf '%s\n' "$out_dir/shellkit-$ver.rpm"
    fi
    ;;
esac
exit 0
