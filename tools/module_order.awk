# 模块加载顺序检查。输入是 lib/core/*.sh，顺序与函数表由 shell 侧喂进来。
#
# 规则：模块 M 里出现了函数 F，而 F 定义在模块 O，那么 O 必须排在 M 前面。
# 否则加载完 M 之后调用 F 会得到 command not found —— 而且是在别人的机器上炸。

BEGIN {
  norder = 0
  while ((getline line < list) > 0) {
    if (line == "" || substr(line, 1, 1) == "#") continue
    order[++norder] = line
    idx[line] = norder
  }
  while ((getline line < owners) > 0) {
    if (line == "") continue
    p = index(line, " ")
    if (p == 0) continue
    fn = substr(line, 1, p - 1)
    mod = substr(line, p + 1)
    if (!(fn in owner)) {
      owner[fn] = mod
    } else if (owner[fn] != mod) {
      printf "check_module_order: function %s defined in both %s and %s\n", fn, owner[fn], mod
    }
  }
}

FNR == 1 {
  base = FILENAME
  sub(/^.*\//, "", base)
  sub(/\.sh$/, "", base)
  cur = base
  curidx = (cur in idx) ? idx[cur] : 0
  if (curidx == 0) next
}

{
  line = $0
  sub(/^[ \t]*#.*/, "", line)
  sub(/[ \t]+#.*/, "", line)

  work = line
  while (match(work, /\$\([^)]*\)/)) {
    inner = substr(work, RSTART + 2, RLENGTH - 3)
    scan(inner)
    work = substr(work, 1, RSTART - 1) " " substr(work, RSTART + RLENGTH)
  }
  rest = work
  gsub(/"[^"]*"/, "", rest)
  scan(rest)
}

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
    if (owner[id] in idx) {
      if (idx[owner[id]] > curidx) {
        printf "check_module_order: %s uses %s() from %s, but %s is loaded after %s\n", cur, id, owner[id], owner[id], cur
      }
    }
  }
}
