#!/usr/bin/env bash
#
# 标识符边界检查：$ident 紧跟非 ASCII 字符 ⇒ 红（issue #73 的根因门禁）
#
# bash 3.2 在 UTF-8 locale 下扫描变量名时，会把紧跟其后的多字节字符的首字节
# 当成名字的一部分：
#
#     LC_ALL=en_US.UTF-8 /bin/bash -c 'set -u; n=x; echo "$n（"'
#     /bin/bash: n\xef: unbound variable      # 退出码 1，且没有别的输出
#
# 本机 LC_ALL=C 一切正常、Linux 的 bash 5 已修 —— 所以这类缺陷只在 UTF-8 locale
# 的 macOS CI 上爆，表现为「门禁以契约外的 1 退出，日志里只有一行 unbound」。
# 判据用 C locale 的字节类：[^[:alnum:][:space:][:punct:]] 在 C locale 下恰好只命中
# ≥0x80 的字节，且不会误伤制表符（制表符结束标识符是安全的）。
#
# 两种情况放过（它们不发生展开，改了反而会动文案）：
#   1. 整行注释；2. 单引号跨度内的文本（shell 的单引号里不能转义，'[^']*' 是精确的）。
#
# 用法：bash tools/check_ident_boundary.sh [--root DIR]
# 退出码：0 通过 / 1 有违规 / 2 用法错
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      shift
      [ "$#" -gt 0 ] || {
        printf 'check_ident_boundary: --root needs a directory\n' >&2
        exit 2
      }
      ROOT="$1"
      ;;
    --root=*) ROOT="${1#*=}" ;;
    -h | --help)
      printf 'usage: bash %s [--root DIR]\n' "${0##*/}" >&2
      exit 0
      ;;
    *)
      printf 'check_ident_boundary: unknown option: %s\n' "$1" >&2
      exit 2
      ;;
  esac
  shift
done
[ -d "$ROOT" ] || {
  printf 'check_ident_boundary: no such directory: %s\n' "$ROOT" >&2
  exit 2
}

PAT='\$[A-Za-z_][A-Za-z0-9_]*[^[:alnum:][:space:][:punct:]]'
__bad=0
__n=0

while IFS= read -r __f; do
  [ -n "$__f" ] || continue
  __n=$((__n + 1))
  # 剥掉单引号跨度与整行注释（不删行，行号才对得上），再按 C locale 的字节类找
  __hits=$(LC_ALL=C sed -e "s/'[^']*'/''/g" -e 's/^[[:space:]]*#.*$//' "$__f" |
    LC_ALL=C grep -n "$PAT" || true)
  [ -n "$__hits" ] || continue
  printf '%s\n' "${__f#"$ROOT"/}" | sed 's/^/check_ident_boundary: /' >&2
  printf '%s\n' "$__hits" | sed 's/^/  line /' >&2
  __bad=1
done <<EOF
$(find "$ROOT/lib" "$ROOT/tools" "$ROOT/tests" "$ROOT/templates" -type f \( -name '*.sh' -o -name 'shellkit' -o -name 'install.sh' -o -name 'repair.sh' -o -name 'demo.sh' \) 2>/dev/null | LC_ALL=C sort)
EOF

if [ "$__bad" -ne 0 ]; then
  printf '%s\n' 'check_ident_boundary: $ident must be braced (${ident}) when a non-ASCII character follows it — bash 3.2 in a UTF-8 locale folds the first byte into the name (issue #73)' >&2
  exit 1
fi
printf 'check_ident_boundary: ok (%s files)\n' "$__n"
exit 0
