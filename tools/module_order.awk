# 模块之间的调用关系提取器。
#
# 输入：lib/core/*.sh（外加 shell 侧喂进来的函数归属表）。
# 输出：每行一条调用关系 —— `uses <调用方模块> <被调用方模块> <函数名>`。
#
# 为什么只做提取，把判断留给 shell：
#   依赖闭包、拓扑序这些逻辑原本写在 awk 的 END 块里，而某些 gawk 版本
#   在那段代码上会直接崩（fatal: internal error / segfault / double free），
#   BWK awk 与 mawk 却都容忍 —— 本机全绿、CI 才炸。
#   awk 只保留它擅长且稳定的部分：从源码里认出函数调用。
#   顺序与依赖的判断在 tools/check_module_order.sh 里用 bash 做。
BEGIN {
  while ((getline line < owners) > 0) {
    if (line == "") continue
    p = index(line, " ")
    if (p == 0) continue
    fn = substr(line, 1, p - 1)
    mod = substr(line, p + 1)
    if (!(fn in owner)) {
      owner[fn] = mod
    }
  }
  while ((getline line < list) > 0) {
    if (line == "" || substr(line, 1, 1) == "#") continue
    order[++norder] = line
    idx[line] = norder
  }
}

FNR == 1 {
  base = FILENAME
  sub(/^.*\//, "", base)
  sub(/\.sh$/, "", base)
  cur = base
  curidx = (cur in idx) ? idx[cur] : 0
}

{
  line = $0
  sub(/^[ \t]*#.*/, "", line)
  sub(/[ \t]+#.*/, "", line)

  # 1) 命令替换：内容单独处理，扫完就把这段挖掉
  work = line
  while (match(work, /\$\([^)]*\)/)) {
    inner = substr(work, RSTART + 2, RLENGTH - 3)
    scan(inner)
    work = substr(work, 1, RSTART - 1) " " substr(work, RSTART + RLENGTH)
  }

  # 2) 剩下的：去掉双引号内容再扫
  rest = work
  gsub(/"[^"]*"/, "", rest)
  scan(rest)
}

# scan TEXT —— 从一段文本里取出命令位置的标识符
function scan(text,   seg, n, i, s, id) {
  gsub(/\|\||&&|;|\|/, "\n", text)
  n = split(text, seg, "\n")
  for (i = 1; i <= n; i++) {
    s = seg[i]
    sub(/^[[:space:]]+/, "", s)
    while (s ~ /^(if|then|else|elif|do|while|until|!|time)[[:space:]]+/) {
      sub(/^(if|then|else|elif|do|while|until|!|time)[[:space:]]+/, "", s)
    }
    sub(/[[:space:]].*$/, "", s)
    if (s !~ /^[A-Za-z_][A-Za-z0-9_]*$/) continue
    id = s
    if (!(id in owner)) continue
    if (owner[id] == cur) continue
    if (!(owner[id] in idx)) continue
    # 同一个「谁用了谁」只报一次，后面 shell 侧要靠它算依赖闭包
    if (!((cur, owner[id]) in seen)) {
      seen[cur, owner[id]] = 1
      printf "uses %s %s %s\n", cur, owner[id], id
    }
    # 规则 1：被调用的模块必须排在调用方前面
    if (idx[owner[id]] > curidx) {
      printf "check_module_order: %s uses %s() from %s, but %s is loaded after %s\n", cur, id, owner[id], owner[id], cur
    }
  }
}
