#!/usr/bin/env bash
#
# 组装 AI skill 包（skills/shellkit/）。
#
#   bash tools/skill_pack.sh OUT_DIR
#
# 产出结构：
#   SKILL.md            入口：何时用、怎么引入、最小脚本、硬事实、任务落点
#   references/         细节，按需读 —— AI 先读 SKILL.md，要细节再翻这里
#     reference.md      完整 API（投影自 docs/REFERENCE.md）
#     cookbook.md       场景手册（投影自 docs/COOKBOOK.md）
#     bash32.md         Bash 3.2 兼容写法（投影自 docs/BASH32.md）
#     cli.md            CLI 命令速查（解析自 shellkit 的 cli_cmd 注册表）
#
# 为什么是「投影」而不是各写一份：同一份事实写两遍必然漂移，而漂移的 AI 说明
# 比没有更糟 —— 它会让人写出错的代码。所以这里每一份 references 都从既有真相源
# 投影出来：文档层是 docs/ 下的原文，命令层是 CLI 注册表本身。
#
# 产物必须逐字节可复现：同一份源码在任何机器上生成的结果必须一样，
# 否则 `shellkit docs --check` 会在别人的机器上假红。
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT=${1:-}

if [ -z "$OUT" ]; then
  printf 'usage: skill_pack.sh OUT_DIR\n' >&2
  exit 2
fi

die() {
  printf 'skill_pack: %s\n' "$1" >&2
  exit "${2:-1}"
}

[ -f "$ROOT/tools/ai_doc.sh" ] || die "missing $ROOT/tools/ai_doc.sh" 3
[ -f "$ROOT/shellkit" ] || die "missing $ROOT/shellkit" 3
[ -f "$ROOT/docs/REFERENCE.md" ] || die "missing $ROOT/docs/REFERENCE.md (run shellkit docs first)" 3
[ -f "$ROOT/docs/COOKBOOK.md" ] || die "missing $ROOT/docs/COOKBOOK.md" 3
[ -f "$ROOT/docs/BASH32.md" ] || die "missing $ROOT/docs/BASH32.md" 3

mkdir -p "$OUT/references" || die "cannot create $OUT/references" 1

# _copy SRC DST —— 落盘一个文件。
# 先写临时文件再 rename：rename 换掉的是**符号链接本身**，不会顺着链接写到别处；
# 直接 `cat > DST` 在 DST 是软链时会写穿到链接指向的那个文件。
_copy() {
  local __src=$1 __dst=$2 __tmp
  [ -f "$__src" ] || die "missing source: $__src" 3
  __tmp="$__dst.tmp.$$"
  cat "$__src" >"$__tmp" || {
    rm -f "$__tmp"
    die "failed to write $__dst" 1
  }
  mv -f "$__tmp" "$__dst" || {
    rm -f "$__tmp"
    die "failed to write $__dst" 1
  }
}

# SKILL.md —— 入口。与 AGENTS.md 同源（头 + 共用契约）。
bash "$ROOT/tools/ai_doc.sh" skill >"$OUT/SKILL.md.tmp.$$" ||
  die 'failed to render SKILL.md' 1
mv -f "$OUT/SKILL.md.tmp.$$" "$OUT/SKILL.md" || die 'failed to write SKILL.md' 1

# references/ —— 投影自 docs/ 与 CLI 注册表
_copy "$ROOT/docs/REFERENCE.md" "$OUT/references/reference.md"
_copy "$ROOT/docs/COOKBOOK.md" "$OUT/references/cookbook.md"
_copy "$ROOT/docs/BASH32.md" "$OUT/references/bash32.md"

# references/cli.md —— 从 CLI 注册表解析。
# 注册表是 CLI 自己的真相源（cli_cmd 那几行），加一个命令这里自动多一行，
# 不用另维护一份命令清单 —— 另维护的那份一定漂移（少列过 uninstall-self 与 update）。
{
  printf '# CLI 速查\n\n'
  printf '> 由 `tools/skill_pack.sh` 从 `shellkit` 的 `cli_cmd` 注册表解析生成 —— 加命令不用改这里。\n\n'

  awk '
    # firstq S —— 取出第一个 "..." 里的内容
    function firstq(s) {
      if (match(s, /"[^"]*"/)) return substr(s, RSTART + 1, RLENGTH - 2)
      return ""
    }
    # lastq S —— 取出最后一个 "..." 里的内容
    function lastq(s) {
      if (match(s, /"[^"]*"$/)) return substr(s, RSTART + 1, RLENGTH - 2)
      return ""
    }
    # qcount S —— 数一数这一行里有几个双引号
    function qcount(s,   t) { t = s; return gsub(/"/, "", t) }
    # msgid S —— 从 $ (_t ...) 里取出 msgid 本体
    #
    # 这里刻意不用字面单引号：整个 awk 程序被包在 bash 的单引号里，
    # 里面再出现单引号会把 bash 的字符串提前结束，报错还落在莫名其妙的地方。
    function msgid(s,   q) {
      q = sprintf("%c", 39)
      sub("^\\$\\(_t " q, "", s)
      sub(q "\\)$", "", s)
      return s
    }
    /^[[:space:]]*cli_group[[:space:]]/ {
      line = $0
      sub(/^[[:space:]]*cli_group[[:space:]]+/, "", line)
      if (qcount(line) < 2) next
      grp = msgid(firstq(line))
      if (seen) printf "\n"
      seen = 1
      printf "## %s\n\n", grp
      printf "| 命令 | 用法 | 说明 |\n| --- | --- | --- |\n"
      next
    }
    /^[[:space:]]*cli_cmd[[:space:]]/ {
      line = $0
      sub(/^[[:space:]]*cli_cmd[[:space:]]+/, "", line)
      if (match(line, /^[A-Za-z0-9_-]+/) == 0) next
      name = substr(line, RSTART, RLENGTH)
      nq = qcount(line)
      desc = ""
      usage = name
      if (nq >= 2) desc = msgid(firstq(line))
      if (nq >= 4) {
        usage = lastq(line)
        if (usage == "") usage = name
      }
      printf "| `shellkit %s` | `%s` | %s |\n", name, usage, desc
      next
    }
  ' "$ROOT/shellkit"

  printf '\n## 退出码\n\n'
  printf '| 码 | 含义 |\n| --- | --- |\n'
  printf '| 0 | 成功 |\n'
  printf '| 1 | 一般错误 |\n'
  printf '| 2 | 用法错（参数不对） |\n'
  printf '| 3 | 前置条件不满足（缺命令、非 root、该交互却没有默认值） |\n'
  printf '| 4 | 网络失败 |\n'
  printf '| 5 | 校验失败（sha256 不匹配、文档与代码不一致） |\n'
} >"$OUT/references/cli.md.tmp.$$" || die 'failed to render cli.md' 1
mv -f "$OUT/references/cli.md.tmp.$$" "$OUT/references/cli.md" || die 'failed to write cli.md' 1

exit 0
