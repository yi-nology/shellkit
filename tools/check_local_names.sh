#!/usr/bin/env bash
#
# 门禁：库内部命名空间 + 出参保留名单必须一致。
#
# 为什么需要这道门：printf -v 写的是「最近一层声明了该名字的作用域」。
# 从公开入口（ask / str_trim / cli_opt）到真正落笔的那一层，中间任何一层只要
# 声明了和目标变量同名的 local，内容就写回自己那层 —— 调用方拿到的还是原值。
# 不报错、不崩，只是静默失效，比普通 bug 更难查。
#
# 查三件事：
#   1. lib/ 与 shellkit 里每个 local 声明的变量名都以 __ 开头
#      （库内部命名空间；「保留名单」才有确定含义）
#   2. 出参链路上的函数（_sk_check_out_name 里那份名单对应的链路）声明的每一个
#      具名局部变量，都必须出现在保留名单里 —— 新增局部变量忘了进名单，
#      就会多出一个「静默失效」的名字
#   3. 每个公开的出参入口都必须调用 _sk_check_out_name
#
# 实现：一次 awk 扫描把每个文件读成「函数 → 正文 + 具名局部变量」的表，
# 三条规则全在表上判定。
#   为什么不用纯 bash 逐行扫：原实现是「文件 × 函数」两层循环，每个函数都要
#   重扫一遍文件（O(N²) 次 fork）—— 本机单跑 37~76s，CI 上是每个 job 的固定
#   开销。改成一次 awk 扫描后只剩一次 fork。
#   判定口径与失败文案保持逐字不变（既有测试断的就是文案）。
#
#   bash tools/check_local_names.sh   # 0 合格；5 不合格
set -u

# SHELLKIT_CHECK_ROOT 只给自测用：在一棵假的树副本上跑本门禁。
ROOT="${SHELLKIT_CHECK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)}"
_bad=0

_fail() {
  printf 'check_local_names: %s\n' "$1" >&2
  _bad=1
}

# 出参链路：从公开入口一路走到 printf -v 的每一环。
# 名单里任何一个函数新增了具名局部变量，都要同步进 _sk_check_out_name 的名单。
CHAIN_FUNCS="str_trim str_lower str_upper str_repeat _sk_ref_get
ask ask_yn ask_choice confirm
_sk_ask_raw _sk_ask_yn_raw _sk_ask_choice_raw _sk_read_line
cli_opt cli_opts _sk_opt_set"

# 公开的出参入口：必须自己挡住保留名。
OUT_PARAM_FUNCS="str_trim str_lower str_upper str_repeat ask ask_yn ask_choice cli_opt"

# 扫描器内嵌在本文件里，不拆成独立的 .awk 文件：
#   门禁自测（tests/test_local_names.sh）会把本脚本单独复制到一棵假树上跑，
#   内嵌 ⇒ 假树不需要第二个文件，判据不会因为「少拷了一个文件」而假红。
__scan_prog=$(mktemp "${TMPDIR:-/tmp}/sk-local-names.XXXXXX") || {
  printf 'check_local_names: 临时文件创建失败（TMPDIR 不可写？）\n' >&2
  exit 5
}
__scan_list=$(mktemp "${TMPDIR:-/tmp}/sk-local-names-list.XXXXXX") || {
  rm -f "$__scan_prog"
  printf 'check_local_names: 临时文件创建失败（TMPDIR 不可写？）\n' >&2
  exit 5
}
trap 'rm -f "$__scan_prog" "$__scan_list"' EXIT

cat >"$__scan_prog" <<'SK_LOCAL_NAMES_AWK'
# 一次扫描：读文件 → 建「函数 → 正文 + 具名局部变量」的表 → 三条规则。
# 口径与原 bash 实现逐字对齐（失败文案、退出码、判定顺序都不变）。

function fail(msg) {
  printf "check_local_names: %s\n", msg > "/dev/stderr"
  bad = 1
}

# lex —— 按 shell 词法把一段文本拆成词（处理单双引号与反斜杠转义）
function lex(s,   i, n, c, q, tok) {
  lnw = 0
  n = length(s)
  i = 1
  q = ""
  tok = ""
  while (i <= n) {
    c = substr(s, i, 1)
    i++
    if (q == "") {
      if (c == " " || c == "\t") {
        if (tok != "") { lw[++lnw] = tok; tok = "" }
        continue
      }
      if (c == "'" || c == "\"") { q = c; continue }
      if (c == "\\") {
        if (i <= n) { c = substr(s, i, 1); i++ } else { c = "" }
      }
    } else {
      if (c == q) { q = ""; continue }
      if (c == "\\" && q == "\"") {
        if (i <= n) { c = substr(s, i, 1); i++ } else { c = "" }
      }
    }
    tok = tok c
  }
  if (tok != "") lw[++lnw] = tok
}

# names_from —— 从「local 后面那段」里取出变量名（跳过选项、去掉 =默认值）
#   注意：原实现把拆出来的词用未加引号的 $__tokens 展开，展开时会按 IFS
#   再切一次（引号里带空格的名字会被切成两个）。这里照样再切一次，口径一致。
function names_from(rest, out,   i, j, m, t, name) {
  lex(rest)
  no = 0
  for (i = 1; i <= lnw; i++) {
    m = split(lw[i], wpart, /[ \t]+/)
    for (j = 1; j <= m; j++) {
      t = wpart[j]
      if (t == "") continue
      if (t ~ /^-/) continue
      if (index(t, "=") > 0) name = substr(t, 1, index(t, "=") - 1)
      else name = t
      if (name == "") continue
      out[++no] = name
    }
  }
  return no
}

# rule1_names —— 规则 1 的取名：去掉行首空白后，只认正好是 local 或 local+空格
function rule1_names(line, out,   rest) {
  rest = line
  sub(/^[[:space:]]+/, "", rest)
  if (rest != "local" && rest !~ /^local /) return 0
  sub(/^local/, "", rest)
  return names_from(rest, out)
}

# chain_names —— 出参链路的取名：原实现用 [[:space:]]*local 前缀匹配
function chain_names(line, out,   rest) {
  if (line !~ /^[[:space:]]*local/) return 0
  rest = line
  sub(/^[[:space:]]+/, "", rest)
  sub(/^local/, "", rest)
  return names_from(rest, out)
}

# close_def —— 收尾一个函数：正文落表
function close_def() {
  dbody[cur] = body
  inbody = 0
  cur = 0
  body = ""
}

# merge_func —— 把「文件里某个名字」的所有定义合并起来看
#   （原实现取函数正文时会把同名定义全都收进来，判据按合并后的正文走）
function merge_func(fi, nm,   key, cnt, j, d, k) {
  key = fi SUBSEP nm
  mpv = 0
  mg = 0
  mnl = 0
  if (!(key in nfnd)) return
  cnt = nfnd[key]
  for (j = 1; j <= cnt; j++) {
    d = fnd[key SUBSEP j]
    if (haspv[d]) mpv = 1
    if (hasguard[d]) mg = 1
    for (k = 1; k <= nfloc[d]; k++) mergedloc[++mnl] = floc[d SUBSEP k]
  }
}

# extract_guard —— 从保留名单正文里抽出所有 __xxx（等价 grep -o '__[A-Za-z0-9_]*'）
function extract_guard(text,   i, n, j, tok) {
  ng = 0
  n = length(text)
  i = 1
  while (i <= n) {
    if (substr(text, i, 2) == "__") {
      tok = "__"
      j = i + 2
      while (j <= n && substr(text, j, 1) ~ /[A-Za-z0-9_]/) {
        tok = tok substr(text, j, 1)
        j++
      }
      if (!(tok in gset)) { gset[tok] = 1; gnames[++ng] = tok }
      i = j
    } else {
      i++
    }
  }
}

BEGIN {
  bad = 0

  # ---- 读文件清单（core 在前，bootstrap/shellkit 在后）----
  n = 0
  while ((getline p < listfile) > 0) {
    if (p != "") paths[++n] = p
  }
  close(listfile)

  # ---- 第一遍：扫文件，建表；同时判规则 1 ----
  for (fi = 1; fi <= n; fi++) {
    base = paths[fi]
    sub(/^.*\//, "", base)
    inbody = 0
    cur = 0
    body = ""
    lineno = 0
    while ((getline line < paths[fi]) > 0) {
      lineno++

      # 规则 1：局部变量名一律 __ 前缀
      m = rule1_names(line, r1n)
      for (i = 1; i <= m; i++) {
        if (r1n[i] !~ /^__/) {
          fail(base ":" lineno ": 局部变量 " r1n[i] " 必须用 __ 前缀（库内部命名空间）")
        }
      }

      if (inbody) {
        if (line ~ /^}/) { close_def(); continue }
        body = body line "\n"
        m = chain_names(line, c1n)
        for (i = 1; i <= m; i++) floc[cur SUBSEP (++nfloc[cur])] = c1n[i]
        if (index(line, "printf -v \"$")) haspv[cur] = 1
        if (index(line, "_sk_check_out_name")) hasguard[cur] = 1
        continue
      }

      # 函数定义行：第一个 { 之前的内容，去掉尾部空白后形如 name()
      p = index(line, "{")
      if (p > 0) head = substr(line, 1, p - 1)
      else head = line
      sub(/[[:space:]]+$/, "", head)
      if (head !~ /\(\)$/) continue
      nm = substr(head, 1, length(head) - 2)
      if (nm == "") continue

      cur = ++ndefs
      dname[cur] = nm
      dfile[cur] = fi
      fdef[fi SUBSEP (++nfdef[fi])] = cur
      ckey = fi SUBSEP nm
      fnd[ckey SUBSEP (++nfnd[ckey])] = cur
      if (!(nm in firstfile)) firstfile[nm] = fi
      if (fi <= ncore && !(nm in firstcore)) firstcore[nm] = fi
      body = ""
      inbody = 1
    }
    close(paths[fi])
    if (inbody) close_def()
  }

  # ---- 保留名单：str.sh 里 _sk_check_out_name 的正文 ----
  guardfound = 0
  guardtext = ""
  gfi = 0
  for (i = 1; i <= n; i++) if (paths[i] == strfile) gfi = i
  if (gfi > 0) {
    gkey = gfi SUBSEP "_sk_check_out_name"
    if (gkey in nfnd) {
      cnt = nfnd[gkey]
      for (j = 1; j <= cnt; j++) {
        d = fnd[gkey SUBSEP j]
        guardtext = guardtext dbody[d]
      }
      guardfound = 1
    }
  }
  if (guardfound) {
    extract_guard(guardtext)
  } else {
    fail("读不到 _sk_check_out_name 的保留名单（str.sh 被改坏了？）")
  }

  # ---- 规则 2：出参链路上的每个具名局部变量都必须在保留名单里 ----
  if (guardfound && ng > 0) {
    # 2a 自动 —— 公开的动态出参函数，它声明的每个具名局部变量都必须在名单里
    for (fi = 1; fi <= ncore; fi++) {
      for (j = 1; j <= nfdef[fi]; j++) {
        d = fdef[fi SUBSEP j]
        nm = dname[d]
        if (nm ~ /^_/) continue
        if (nm !~ /^[A-Za-z0-9_]+$/) continue
        merge_func(fi, nm)
        if (!mpv) continue
        for (k = 1; k <= mnl; k++) {
          ln = mergedloc[k]
          if (ln !~ /^__/) continue
          if (!(ln in gset)) {
            fail(nm "() 的局部变量 " ln " 没进 _sk_check_out_name 的保留名单（用这个名字的调用方会静默拿到旧值）")
          }
        }
      }
    }
    # 2b 硬名单 —— 转手交给私有函数的公开入口
    cnt = split(chain, cfn)
    for (j = 1; j <= cnt; j++) {
      nm = cfn[j]
      if (nm == "") continue
      if (!(nm in firstcore)) {
        fail("链路上找不到函数 " nm "（它被删了还是改了名？）")
        continue
      }
      merge_func(firstcore[nm], nm)
      for (k = 1; k <= mnl; k++) {
        ln = mergedloc[k]
        if (ln !~ /^__/) continue
        if (!(ln in gset)) {
          fail(nm "() 的局部变量 " ln " 没进 _sk_check_out_name 的保留名单（用这个名字的调用方会静默拿到旧值）")
        }
      }
    }
  }

  # ---- 规则 3：公开的出参入口必须挡住保留名 ----
  #   3a 自动 —— 公开的动态出参函数
  for (fi = 1; fi <= ncore; fi++) {
    for (j = 1; j <= nfdef[fi]; j++) {
      d = fdef[fi SUBSEP j]
      nm = dname[d]
      if (nm ~ /^_/) continue
      if (nm !~ /^[A-Za-z0-9_]+$/) continue
      merge_func(fi, nm)
      if (!mpv) continue
      if (!mg) {
        fail(nm "() 是公开出参入口，必须调用 _sk_check_out_name 挡住保留名")
      }
    }
  }
  #   3b 硬名单
  cnt = split(outp, ofn)
  for (j = 1; j <= cnt; j++) {
    nm = ofn[j]
    if (nm == "") continue
    if (!(nm in firstcore)) {
      fail("找不到公开出参函数 " nm)
      continue
    }
    merge_func(firstcore[nm], nm)
    if (!mg) {
      fail(nm "() 是公开出参入口，必须调用 _sk_check_out_name 挡住保留名")
    }
  }

  if (bad) exit 5
  exit 0
}
SK_LOCAL_NAMES_AWK

# 文件清单：core 在前（规则 2/3 只看这一组），再 bootstrap.sh 与 shellkit（规则 1 看）
: >"$__scan_list"
__core_n=0
for __f in "$ROOT"/lib/core/*.sh; do
  [ -f "$__f" ] || continue
  printf '%s\n' "$__f" >>"$__scan_list"
  __core_n=$((__core_n + 1))
done
if [ -f "$ROOT/lib/bootstrap.sh" ]; then
  printf '%s\n' "$ROOT/lib/bootstrap.sh" >>"$__scan_list"
fi
if [ -f "$ROOT/shellkit" ]; then
  printf '%s\n' "$ROOT/shellkit" >>"$__scan_list"
fi

# CHAIN_FUNCS 在上面是分成三行写的；awk 的 -v 不接受值里带换行，
# 先把换行换成空格（一份名单而已，词与词之间的分隔符无所谓）。
__chain=${CHAIN_FUNCS//$'\n'/ }
__outp=${OUT_PARAM_FUNCS//$'\n'/ }

awk -v listfile="$__scan_list" \
  -v strfile="$ROOT/lib/core/str.sh" \
  -v ncore="$__core_n" \
  -v chain="$__chain" \
  -v outp="$__outp" \
  -f "$__scan_prog"
__rc=$?
if [ "$__rc" -ne 0 ]; then
  _bad=1
fi

if [ "$_bad" -ne 0 ]; then
  printf 'check_local_names: 库内部命名空间与出参保留名单不合格\n' >&2
  exit 5
fi
printf 'check_local_names: ok\n'
exit 0
