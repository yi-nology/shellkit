#!/usr/bin/env bash
#
# 兼容承诺的事实判据（docs/COMPATIBILITY.md）。
#
# 为什么要有这道门：承诺文档最容易烂的方式是「写得很好，但与源码无关」——
# 文中说「每个公开函数都有等级」，实际上又悄悄往豁免名单里加了一条；
# 文中写「50 个 stable / 112 个 experimental」，源码里早就是另一个数。
# 这类漂移不会让任何东西报错，只会让用户在升级时踩到「文档没说会变」的行为变化。
#
# 判据（全部满足才返回 0）：
#   1. 四个必备小节都在（版本号语义 / 每个公开函数都有承诺等级 / 弃用流程 / 判据在哪）；
#   2. 每个公开函数都有 @stability，取值只能是 stable 或 experimental；
#   3. tools/stability_exempt.txt 为空 —— 文档说「没有未分级的公开函数」，名单里就不能有人；
#   4. 文档表格里的 stable / experimental 数量与源码实际数量一致（手抄的数字必须自查）。
#
# 用法：bash tools/check_compatibility.sh
# 退出码：0 通过 / 2 用法错 / 5 校验失败（门禁红）
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOC="$ROOT/docs/COMPATIBILITY.md"
EXEMPT="$ROOT/tools/stability_exempt.txt"
LIB_DIR="$ROOT/lib/core"

bad=0
say() { printf 'compatibility: %s\n' "$*" >&2; }

case "${1:-}" in
  '') ;;
  -h | --help)
    printf 'usage: bash tools/check_compatibility.sh\n'
    exit 0
    ;;
  *)
    say "unknown argument: $1"
    exit 2
    ;;
esac

[ -f "$DOC" ] || {
  say "missing docs/COMPATIBILITY.md — the compatibility policy is part of the contract"
  exit 5
}

doc_text=$(cat "$DOC")

# --- 1. 必备小节 ---
for __sec in '版本号语义' '每个公开函数都有承诺等级' '弃用流程' '判据在哪'; do
  case "$doc_text" in
    *"$__sec"*) ;;
    *)
      say "docs/COMPATIBILITY.md is missing the section: $__sec"
      bad=1
      ;;
  esac
done

# --- 2. 源码扫描：公开函数 → 分级 ---
# 取法与 tools/api_baseline.sh 同源：^name() 且不以 _ 开头；紧邻的注释块里找 @stability。
src=$(awk '
  /^[A-Za-z_][A-Za-z0-9_]*\(\)/ {
    fname = $0
    sub(/\(.*/, "", fname)
    blk = ""
    if (prev ~ /^#/) {
      blk = prev
      for (i = NR - 2; i >= 1; i--) {
        if (lines[i] ~ /^#/) { blk = lines[i] "\n" blk }
        else { break }
      }
    }
    if (fname !~ /^_/) {
      stab = ""
      n = split(blk, L, "\n")
      for (j = 1; j <= n; j++) {
        if (L[j] ~ /@stability[ \t]+/) {
          rest = L[j]
          sub(/^[^@]*@stability[ \t]+/, "", rest)
          split(rest, W, /[ \t]+/)
          stab = W[1]
        }
      }
      printf "%s\t%s\n", fname, stab
    }
    next
  }
  { lines[NR] = $0; prev = $0 }
' "$LIB_DIR"/*.sh)

total=0
stable=0
experimental=0
missing=""
while IFS=$'\t' read -r __name __stab; do
  [ -n "$__name" ] || continue
  total=$((total + 1))
  case "$__stab" in
    stable) stable=$((stable + 1)) ;;
    experimental) experimental=$((experimental + 1)) ;;
    '') missing="$missing $__name" ;;
    *)
      say "invalid @stability value for $__name: $__stab (use stable or experimental)"
      bad=1
      ;;
  esac
done <<EOF
$src
EOF

if [ -n "$missing" ]; then
  say "public functions without @stability:$missing"
  say "  (declare them stable|experimental in the doc comment right above the definition)"
  bad=1
fi

# --- 3. 豁免名单必须为空 ---
if [ -f "$EXEMPT" ]; then
  exempt_entries=""
  while IFS= read -r __line || [ -n "$__line" ]; do
    case "$__line" in
      '' | '#'*) continue ;;
    esac
    exempt_entries="$exempt_entries $__line"
  done <"$EXEMPT"
  if [ -n "$exempt_entries" ]; then
    say "tools/stability_exempt.txt must stay empty; it lists:$exempt_entries"
    say "  (the policy claims every public function has a level; an exemption makes that false)"
    bad=1
  fi
else
  say "missing tools/stability_exempt.txt"
  bad=1
fi

# --- 4. 文档里的数字必须与源码一致 ---
claimed=$(awk -F'|' '
  $2 ~ /`stable`/ {
    v = $4
    gsub(/[^0-9]/, "", v)
    if (v != "") print "stable " v
  }
  $2 ~ /`experimental`/ {
    v = $4
    gsub(/[^0-9]/, "", v)
    if (v != "") print "experimental " v
  }
' "$DOC")

claimed_stable=""
claimed_experimental=""
while read -r __level __n; do
  case "$__level" in
    stable) claimed_stable=$__n ;;
    experimental) claimed_experimental=$__n ;;
  esac
done <<EOF
$claimed
EOF

if [ -z "$claimed_stable" ] || [ -z "$claimed_experimental" ]; then
  say "docs/COMPATIBILITY.md must state the stable and experimental counts in its level table"
  bad=1
else
  [ "$claimed_stable" = "$stable" ] || {
    say "docs/COMPATIBILITY.md says $claimed_stable stable functions, the source has $stable"
    bad=1
  }
  [ "$claimed_experimental" = "$experimental" ] || {
    say "docs/COMPATIBILITY.md says $claimed_experimental experimental functions, the source has $experimental"
    bad=1
  }
fi

if [ "$bad" -ne 0 ]; then
  say "FAILED — the compatibility policy and the source disagree"
  exit 5
fi

printf 'compatibility: ok（%s 个公开函数：%s stable / %s experimental，豁免名单为空）\n' \
  "$total" "$stable" "$experimental"
exit 0
