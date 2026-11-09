# 模块加载顺序与依赖声明检查。输入是 lib/core/*.sh，
# 顺序 / 依赖 / 函数表都由 shell 侧喂进来（见 tools/check_module_order.sh）。
#
# 三条规则：
#   1. 模块 M 里出现了函数 F，而 F 定义在模块 O，那么 O 必须排在 M 前面。
#      否则加载完 M 之后调用 F 会得到 command not found —— 而且是在别人的机器上炸。
#   2. 清单第二列声明的每个依赖必须排在它前面（依赖必须先加载）。
#   3. 第二列声明必须完整：M 用到了 O 的函数，O 就必须在 M 的依赖闭包里 ——
#      可以直接声明，也可以通过别的依赖间接声明。

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

  # 第二列：模块名 + 直接依赖（空白分隔）
  ndeps = 0
  while ((getline line < depsfile) > 0) {
    if (line == "") continue
    p = index(line, " ")
    if (p == 0) {
      dn = line
      dd = ""
    } else {
      dn = substr(line, 1, p - 1)
      dd = substr(line, p + 1)
    }
    depname[++ndeps] = dn
    deplist[dn] = dd
  }

  # 规则 2：声明的依赖必须排在它前面
  for (i = 1; i <= ndeps; i++) {
    dn = depname[i]
    if (!(dn in idx)) {
      printf "check_module_order: module %s is not listed in lib/modules.txt\n", dn
      continue
    }
    m = split(deplist[dn], arr, " ")
    for (j = 1; j <= m; j++) {
      d = arr[j]
      if (d == "") continue
      if (!(d in idx)) {
        printf "check_module_order: module %s depends on %s, but %s is not listed in lib/modules.txt\n", dn, d, d
      } else if (idx[d] >= idx[dn]) {
        printf "check_module_order: module %s depends on %s, but %s is listed after %s (a dependency must be loaded first)\n", dn, d, d, dn
      }
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
  gsub(/\|\||&&|;\|/, "\n", text)
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
      # 记住「谁用了谁」，规则 3 要靠它算依赖闭包
      if (!((cur, owner[id]) in usedset)) {
        usedset[cur, owner[id]] = 1
        usedlist[cur] = usedlist[cur] " " owner[id]
        usesample[cur, owner[id]] = id
      }
      if (idx[owner[id]] > curidx) {
        printf "check_module_order: %s uses %s() from %s, but %s is loaded after %s\n", cur, id, owner[id], owner[id], cur
      }
    }
  }
}

END {
  # 依赖闭包：closure(m) = deps(m) ∪ closure(d)，d 取遍 deps(m)。
  # 用不动点迭代：即使清单顺序写错了，闭包也算得对（顺序问题由规则 2 报）。
  changed = 1
  while (changed) {
    changed = 0
    for (i = 1; i <= norder; i++) {
      m = order[i]
      s = ""
      n = split(deplist[m], arr, " ")
      for (j = 1; j <= n; j++) {
        d = arr[j]
        if (d == "") continue
        s = add_to_set(s, d)
        s = union_sets(s, closure[d])
      }
      if (s != closure[m]) {
        closure[m] = s
        changed = 1
      }
    }
  }

  # 规则 3：用了谁的函数，谁就得在依赖闭包里。
  # i18n 例外：它恒定加载（_t 是公共依赖），不强制每个模块都声明。
  for (i = 1; i <= norder; i++) {
    a = order[i]
    n = split(usedlist[a], arr, " ")
    for (j = 1; j <= n; j++) {
      b = arr[j]
      if (b == "" || b == a || b == "i18n") continue
      if (!in_set(closure[a], b)) {
        printf "check_module_order: module %s uses %s() from %s, but %s is not in %s dependency closure (declare it in lib/modules.txt)\n", a, usesample[a, b], b, b, a
      }
    }
  }
}

# 集合用空格分隔的字符串表示。模块名里没有空格，够用。
function in_set(set, x,   n, arr, i) {
  n = split(set, arr, " ")
  for (i = 1; i <= n; i++) {
    if (arr[i] == x) return 1
  }
  return 0
}

function add_to_set(set, x) {
  if (x == "") return set
  if (in_set(set, x)) return set
  return (set == "") ? x : set " " x
}

function union_sets(a, b,   n, arr, i) {
  n = split(b, arr, " ")
  for (i = 1; i <= n; i++) {
    a = add_to_set(a, arr[i])
  }
  return a
}
