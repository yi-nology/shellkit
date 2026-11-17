#!/usr/bin/env bash
#
# API 冻结清单（docs/API-FREEZE.md）：生成与对账。
#
#   bash tools/api_freeze.sh            # 检查已提交清单是否与源码一致（0 一致 / 5 漂移）
#   bash tools/api_freeze.sh --write    # 重新生成清单
#
# 为什么要有（#129 的「Stable API 冻结」门槛）：1.0 的承诺面必须是一份
# **可 diff 的快照**，不能只靠散文说「50 个 stable」。清单从四处真相源生成：
#
#   tools/api_baseline.txt   分级（stable/experimental）、承诺返回码、探针状态
#   lib/core/*.sh            函数属于哪个模块、一句话说明
#   lib/modules.txt          模块顺序（与 bootstrap / 站点同一份真相源）
#   shellkit 的 cli_cmd      公开的 CLI 子命令与参数形状
#   lib/bootstrap.sh         SK_* 退出码常量
#
# 任何一处漂移（晋升一个 stable、改了一组返回码、加/删子命令）⇒ 已提交的
# 清单与源码对不上 ⇒ make check 红，必须显式重生成并在 review 里看到 diff。
#
# 退出码：0 一致 / 2 用法错 / 3 输入不可读 / 5 与已提交清单不一致
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE=check

say() { printf 'api_freeze: %s\n' "$*" >&2; }
die() {
  say "$1"
  exit "${2:-3}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --write) MODE='write' ;;
    --check) MODE='check' ;;
    --root)
      [ $# -ge 2 ] || die "--root needs a directory" 2
      ROOT=$2
      shift
      ;;
    --root=*) ROOT=${1#*=} ;;
    -h | --help)
      printf 'usage: bash tools/api_freeze.sh [--write] [--root DIR]\n'
      exit 0
      ;;
    *) die "unknown argument: $1" 2 ;;
  esac
  shift
done

ROOT="$(cd "$ROOT" 2>/dev/null && pwd)" || die "cannot enter the root directory" 3
BASELINE="$ROOT/tools/api_baseline.txt"
MODULES="$ROOT/lib/modules.txt"
LIB="$ROOT/lib/core"
CLI="$ROOT/shellkit"
BOOT="$ROOT/lib/bootstrap.sh"
TARGET="$ROOT/docs/API-FREEZE.md"
VERSION_FILE="$ROOT/VERSION"

for __f in "$BASELINE" "$MODULES" "$BOOT" "$CLI" "$VERSION_FILE"; do
  [ -f "$__f" ] || die "missing input: $__f" 3
done
[ -d "$LIB" ] || die "missing library directory: $LIB" 3

work=$(mktemp -d "${TMPDIR:-/tmp}/shellkit-freeze.XXXXXX") || die "cannot create a temp dir" 3
trap 'rm -rf "${work:?}"' EXIT INT TERM HUP

# ---------------------------------------------------------------------------
# 1) 扫源码：公开函数 → 模块 + 一句话说明
# ---------------------------------------------------------------------------

_scan_module() {
  local __mod=$1
  awk -v mod="$__mod" '
    /^#/ { block = block $0 "\n"; next }
    /^[A-Za-z_][A-Za-z0-9_]*\(\)/ {
      name = $0
      sub(/\(.*/, "", name)
      if (name !~ /^_/) {
        desc = ""
        n = split(block, L, "\n")
        for (i = 1; i <= n; i++) {
          if (L[i] ~ /^#/) {
            d = L[i]
            sub(/^#+[ \t]*/, "", d)
            if (d == "") continue
            if (index(d, "——") > 0) sub(/^.*——[ \t]*/, "", d)
            desc = d
            break
          }
        }
        gsub(/\t/, " ", desc)
        gsub(/\|/, "\\|", desc)
        gsub(/`/, "'"'"'", desc)
        printf "%s\t%s\t%s\n", name, mod, desc
      }
      block = ""
      next
    }
    { block = "" }
  ' "$LIB/$__mod.sh"
}

: >"$work/funcs.tsv"
while IFS= read -r __line || [ -n "$__line" ]; do
  case "$__line" in
    '' | '#'*) continue ;;
  esac
  __mod=${__line%%[[:space:]]*}
  [ -n "$__mod" ] || continue
  [ -f "$LIB/$__mod.sh" ] || die "lib/modules.txt names a missing module: $__mod" 3
  _scan_module "$__mod" >>"$work/funcs.tsv"
done <"$MODULES"

[ -s "$work/funcs.tsv" ] || die "no public functions were found in $LIB" 3

# ---------------------------------------------------------------------------
# 2) 基线：只取 stable（experimental 不在承诺面内）
# ---------------------------------------------------------------------------

awk -F'\t' '
  $0 ~ /^#/ { next }
  $1 == "" { next }
  $1 ~ /^baseline-version:/ { next }
  $8 == "stable" { print $1 "\t" $2 "\t" $5 }
' "$BASELINE" >"$work/stable.tsv" || die "cannot read $BASELINE" 3

exp=$(awk -F'\t' '
  $0 ~ /^#/ { next }
  $1 ~ /^baseline-version:/ { next }
  $8 == "experimental" { n++ }
  END { print n + 0 }
' "$BASELINE")
[ -n "$exp" ] || exp=0

# 3) 合并成 rows.tsv：模块顺序 / 模块 / 函数 / 承诺返回码 / 探针 / 说明
awk -F'\t' -v modfile="$MODULES" -v funcfile="$work/funcs.tsv" '
  FILENAME == modfile {
    if ($0 !~ /^#/ && NF) {
      # modules.txt 是「模块名 + 依赖」空格分隔；本 awk 的 FS 是制表符，
      # 所以这里必须自己按空白拆 —— 直接取 $1 会拿到整行。
      split($0, w, /[ \t]+/)
      m = w[1]
      if (m != "" && !(m in order)) order[m] = ++n
    }
    next
  }
  FILENAME == funcfile { desc[$1] = $3; fmod[$1] = $2; next }
  {
    name = $1
    m = fmod[name]
    if (m == "") m = "unknown"
    ord = (m in order) ? order[m] : 999
    printf "%d\t%s\t%s\t%s\t%s\t%s\n", ord, m, name, $2, $3, desc[name]
  }
' "$MODULES" "$work/funcs.tsv" "$work/stable.tsv" | LC_ALL=C sort -t "$(printf '\t')" -k1,1n -k3,3 >"$work/rows.tsv"

stable_count=$(awk 'END { print NR }' "$work/rows.tsv")
[ "$stable_count" -gt 0 ] || die "no stable functions found in the baseline" 5

# ---------------------------------------------------------------------------
# 4) 退出码表：常量必须齐全（新增 SK_* 却不在语义表里 ⇒ 报错，而不是漏写）
# ---------------------------------------------------------------------------

_meaning() {
  case "$1" in
    SK_OK) printf '成功' ;;
    SK_ERR) printf '一般错误' ;;
    SK_USAGE) printf '用法错（参数不对）' ;;
    SK_PRECOND) printf '前置条件不满足（缺命令、非 root、该交互却没有默认值）' ;;
    SK_NET) printf '网络失败' ;;
    SK_VERIFY) printf '校验失败（sha256 不匹配、文档与代码不一致）' ;;
    *) return 1 ;;
  esac
}

awk -F= '/^SK_[A-Z_]+=[0-9]+$/ { print $1 "\t" $2 }' "$BOOT" >"$work/codes.tsv"
[ -s "$work/codes.tsv" ] || die "no SK_* exit codes found in $BOOT" 3

: >"$work/codes.md"
while IFS=$'\t' read -r __name __num; do
  [ -n "$__name" ] || continue
  __meaning=$(_meaning "$__name") || die "unknown exit-code constant: $__name (add its meaning to tools/api_freeze.sh)" 3
  printf '| %s | `%s` | %s |\n' "$__num" "$__name" "$__meaning" >>"$work/codes.md"
done <"$work/codes.tsv"

# ---------------------------------------------------------------------------
# 5) CLI 形状：cli_cmd 注册表（子命令 + 用法串；说明文案不承诺、可本地化）
# ---------------------------------------------------------------------------

awk '
  /^[ \t]*cli_cmd[ \t]/ {
    line = $0
    sub(/^[ \t]*cli_cmd[ \t]+/, "", line)
    name = line
    sub(/[ \t].*/, "", name)
    n = split(line, q, "\"")
    usage = ""
    if (n >= 2) usage = q[n - 1]
    gsub(/\|/, "\\|", usage)
    printf "| `%s` | `%s` |\n", name, usage
  }
' "$CLI" >"$work/cli.md"
[ -s "$work/cli.md" ] || die "no cli_cmd registrations found in $CLI" 3

# ---------------------------------------------------------------------------
# 6) 组装文档
# ---------------------------------------------------------------------------

: >"$work/API-FREEZE.md"
{
  printf '# API 冻结清单（v1.0.0）\n\n'
  printf '> 生成物：由 `bash tools/api_freeze.sh --write` 从 `tools/api_baseline.txt`、\n'
  printf '> `lib/core/*.sh`、`lib/modules.txt`、`lib/bootstrap.sh` 与 `shellkit` 的\n'
  printf '> `cli_cmd` 注册生成 —— **不要手改**。\n'
  printf '>\n'
  # 不写当前 VERSION：清单是「1.x 承诺面」的快照，不该每次发版都漂移
  # （否则每次 release 的 make check 都会因 frozen-at 变化而红）。
  printf '> 冻结基线：v1.0.0（1.x 内不变；变更必须走 minor + docs/MIGRATING.md）\n'
  printf '> 承诺面：%s 个 `@stability stable` 公开函数 + 退出码表 + CLI 子命令形状。\n' "$stable_count"
  printf '> 其余 %s 个 `@stability experimental` 函数**不在兼容承诺内**（见 `docs/COMPATIBILITY.md`）。\n\n' "$exp"
  printf '## 冻结口径（1.x）\n\n'
  printf -- '- 表内函数的**返回码集合、stdout 数据、产出文件名与路径**在 1.x 内不变；\n'
  printf -- '- **stderr 的日志措辞与译文不在承诺内**（可以改、可以本地化）；\n'
  printf -- '- 表外函数（experimental）随时可变，变更仍要写进 `docs/MIGRATING.md`；\n'
  printf -- '- 改动表内函数的任何结果 ⇒ 升 **minor** + 迁移表 + 重生成此清单；\n'
  printf -- '- 这份清单由门禁对账：源码与已提交清单不一致 ⇒ `make check` 红。\n\n'
  printf '## 退出码\n\n'
  printf '| 码 | 常量 | 含义 |\n|---|---|---|\n'
  cat "$work/codes.md"
  printf '\n单次调用实际可能返回的码集合见下表的「承诺返回码」列；不在该列里的码不承诺。\n\n'
  printf '## 按模块（stable 函数）\n\n'
  awk -F'\t' '
    {
      if ($2 != prev) {
        if (prev != "") printf "\n"
        printf "### %s\n\n| 函数 | 承诺返回码 | 探针 | 说明 |\n|---|---|---|---|\n", $2
        prev = $2
      }
      printf "| `%s` | %s | %s | %s |\n", $3, $4, $5, $6
    }
  ' "$work/rows.tsv"
  printf '\n## CLI 形状（承诺子命令与参数形状）\n\n'
  printf '| 子命令 | 用法 |\n|---|---|\n'
  cat "$work/cli.md"
  printf '\n说明文案不承诺：它们会按 `SHELLKIT_LANG` 本地化，措辞也可能改进；\n'
  printf '子命令名、参数与选项形状、以及退出码属于承诺面。\n'
} >"$work/API-FREEZE.md" || die "cannot assemble the freeze document" 3

# ---------------------------------------------------------------------------
# 7) 写盘或对账
# ---------------------------------------------------------------------------

if [ "$MODE" = "write" ]; then
  mkdir -p "$(dirname "$TARGET")" || die "cannot create $(dirname "$TARGET")" 3
  cp "$work/API-FREEZE.md" "$TARGET.tmp.$$" && mv -f "$TARGET.tmp.$$" "$TARGET" ||
    die "cannot write $TARGET" 3
  say "已重生成 ${TARGET}（${stable_count} 个 stable / ${exp} 个 experimental，冻结基线 v1.0.0）"
  exit 0
fi

[ -f "$TARGET" ] || die "missing $TARGET — run: bash tools/api_freeze.sh --write" 5
if ! cmp -s "$TARGET" "$work/API-FREEZE.md"; then
  say "docs/API-FREEZE.md 与源码不一致（承诺面漂移）"
  diff -u "$TARGET" "$work/API-FREEZE.md" | sed -n '1,40p' >&2
  say "确认这是有意的变更后跑：bash tools/api_freeze.sh --write"
  exit 5
fi

say "ok（${stable_count} 个 stable / ${exp} 个 experimental，冻结基线 v1.0.0）"
exit 0
