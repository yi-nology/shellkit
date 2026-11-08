# shellkit 的 shdoc 内核：把函数上方的注释块渲染成 markdown。
# 约定：注释块第一行即摘要；${@brief} / @param / @exitcode / @example / @see
# 是可选的结构化标注；@internal 表示不导出。

BEGIN {
  nc = 0
  header = 0
}

/^#/ {
  line = substr($0, 2)
  sub(/^ /, "", line)
  block[++nc] = line
  next
}

/^[A-Za-z_][A-Za-z0-9_]*\(\)/ {
  fname = $0
  sub(/\(.*/, "", fname)
  emit(fname)
  nc = 0
  next
}

{ nc = 0 }

function emit(fname,   i, l, brief, hidden, np, ne, ns, has_ex, params, exits, sees, ex, t) {
  brief = ""
  hidden = 0
  np = 0
  ne = 0
  ns = 0
  has_ex = 0
  ex = ""

  for (i = 1; i <= nc; i++) {
    l = block[i]
    if (l ~ /^@internal/) { hidden = 1; continue }
    if (l ~ /^@brief /) { brief = substr(l, 8); continue }
    if (l ~ /^@param /) { params[++np] = substr(l, 8); continue }
    if (l ~ /^@exitcode /) { exits[++ne] = substr(l, 11); continue }
    if (l ~ /^@see /) { sees[++ns] = substr(l, 6); continue }
    if (l ~ /^@example/) { has_ex = 1; continue }
    if (has_ex == 1) {
      ex = ex (ex == "" ? "" : "\n") l
      continue
    }
    if (l !~ /^@/ && l != "") {
      if (brief == "") { brief = l } else { brief = brief " " l }
    }
  }

  if (hidden == 1) return
  if (fname ~ /^_/) return

  if (header == 0) {
    printf "## %s\n\n", mod
    header = 1
  }

  printf "### `%s`\n\n", fname
  if (brief != "") printf "%s\n\n", brief
  if (np > 0) {
    printf "**参数**\n\n"
    for (i = 1; i <= np; i++) printf "- %s\n", params[i]
    printf "\n"
  }
  if (ne > 0) {
    printf "**退出码**\n\n"
    for (i = 1; i <= ne; i++) printf "- %s\n", exits[i]
    printf "\n"
  }
  if (has_ex == 1 && ex != "") {
    printf "**示例**\n\n`@bash\n%s\n`@\n\n", ex
  }
  if (ns > 0) {
    printf "**参见**\n\n"
    for (i = 1; i <= ns; i++) printf "- `%s`\n", sees[i]
    printf "\n"
  }
}
