# 检查公开函数上方是否有注释行相邻。输出 file:line:name，空输出即全部覆盖。
/^#/ { prev = 1; next }
/^[A-Za-z_][A-Za-z0-9_]*\(\)/ {
  name = $0
  sub(/\(.*/, "", name)
  if (name !~ /^_/ && prev == 0) print file ":" NR ":" name
  prev = 0
  next
}
{ prev = 0 }
