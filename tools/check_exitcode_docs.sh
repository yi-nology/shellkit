#!/usr/bin/env bash
#
# 公开函数的返回码必须写进注释。
#
# 为什么需要这道门：README 里写着「返回码就是接口的一部分」，但接口的一半
# 是空的 —— 早期写下的 16 个模块里，一个 `@exitcode` 都没有，调用方只能靠
# 猜或者去读实现。http.sh 是后来才立的规矩（每个函数都写明返回什么），
# 但规矩没回填到旧模块。
#
# 查两件事：
#   1. 公开函数的注释块必须**紧邻**函数（中间有空行，shdoc.awk 就整段丢掉，
#      API 参考里会出现一个没有说明的函数）
#   2. 注释块里必须有至少一条 `@exitcode`，写明这个函数返回什么
#
#   bash tools/check_exitcode_docs.sh   # 0 合格；5 不合格
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"
_bad=0

_fail() {
  printf 'check_exitcode_docs: %s\n' "$1" >&2
  _bad=1
}

for f in "$ROOT"/lib/core/*.sh; do
  [ -f "$f" ] || continue
  base=${f##*/}
  awk -v base="$base" '
    # 函数定义行
    /^[A-Za-z_][A-Za-z0-9_]*\(\)/ {
      fname = $0
      sub(/\(.*/, "", fname)
      if (fname ~ /^_/) { want = 0 }
      else { want = 1 }
      fname = fname
      # 收集紧邻的注释块：注释必须紧贴函数，中间有空行就等于没有
      blk = ""
      if (prev ~ /^#/) {
        blk = prev
        # 往上把整块都收进来
        for (i = NR - 2; i >= 1; i--) {
          if (lines[i] ~ /^#/) { blk = lines[i] "\n" blk }
          else { break }
        }
      }
      if (want == 1) {
        if (prev !~ /^#/) {
          printf "%s:%d: %s() 的上方没有紧邻注释块（中间有空行会让 API 参考丢掉说明）\n", base, NR, fname
          bad = 1
        } else if (blk !~ /@exitcode[ \t]/) {
          printf "%s:%d: %s() 没有 @exitcode 说明（返回码是接口的一部分）\n", base, NR, fname
          bad = 1
        }
      }
      want = 0
      next
    }
    { lines[NR] = $0; prev = $0 }
    END { if (bad) exit 1 }
  ' "$f" >"$ROOT/.check_exitcode.$$" 2>/dev/null
  if [ $? -ne 0 ]; then
    cat "$ROOT/.check_exitcode.$$" >&2
    _bad=1
  fi
  rm -f "$ROOT/.check_exitcode.$$"
done

if [ "$_bad" -ne 0 ]; then
  printf 'check_exitcode_docs: 公开函数必须写明返回码\n' >&2
  exit 5
fi
printf 'check_exitcode_docs: ok\n'
exit 0
