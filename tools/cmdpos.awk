# 找出 shell 脚本里「命令位置」上的标识符，一个一行。
#
# 命令位置 = 一行的开头，或 | / || / && / ; 之后。
# 为什么要这么挑：
#   - 注释先剥掉，否则 "# 所以 v=$(conf_get KEY) 不会脏" 里的 conf_get 会被当成调用
#   - 引号里的内容不算（否则 'must be run as root' 里的 run 会被当成调用）
#   - 整行赋值与 local/export 声明不算（否则 unit_path 会被当成函数）
#   - 命令替换 $(...) 里的内容单独扫，否则 "$(_t 'x')" 里的 _t 会漏掉
#
# 输出的是标识符本身，不判断它是不是函数 —— 判断留给调用方。
{
  line = $0
  sub(/^[ \t]*#.*/, "", line)     # 整行注释
  sub(/[ \t]+#.*/, "", line)       # 行尾注释（引号里的 # 前没有空格，不受影响）

  # 1) 命令替换：内容单独处理，扫完就把这段挖掉
  work = line
  while (match(work, /\$\([^)]*\)/)) {
    inner = substr(work, RSTART + 2, RLENGTH - 3)
    emit(inner)
    work = substr(work, 1, RSTART - 1) " " substr(work, RSTART + RLENGTH)
  }

  # 2) 剩下的：去掉双引号内容再扫
  rest = work
  gsub(/"[^"]*"/, "", rest)
  emit(rest)
}

# emit SEG —— 从一段文本里取出命令位置的标识符
function emit(text,   seg, n, i, s) {
  gsub(/\|\||&&|;|\|/, "\n", text)
  n = split(text, seg, "\n")
  for (i = 1; i <= n; i++) {
    s = seg[i]
    sub(/^[[:space:]]+/, "", s)
    while (s ~ /^(if|then|else|elif|do|while|until|!|time)[[:space:]]+/) {
      sub(/^(if|then|else|elif|do|while|until|!|time)[[:space:]]+/, "", s)
    }
    sub(/[[:space:]].*$/, "", s)
    if (s ~ /^[A-Za-z_][A-Za-z0-9_]*$/) print s
  }
}
