#!/usr/bin/env bash
#
# mutation.sh —— 变异测试：验证回归用例有没有「判据能力」。
#
# 要防的事：「缺陷造回去了，用例却还是绿的」。回归网拦不拦得住某类缺陷，
# 不能靠想象 —— 把缺陷重新种进库里再跑一遍，用例必须变红。
#
# 做法：把 --root 指定的树拷进临时目录，枚举 --target 文件里的变异位点，
# 逐个把变异应用到副本上（真库一个字节都不动），在副本里跑 --test 命令：
#   退出码非 0 ⇒ KILLED   —— 用例抓到了这个缺陷，判据能力坐实
#   退出码 0   ⇒ SURVIVED —— 用例对这个缺陷没有判据，缺口显式可见
# 解析不过 bash -n 的变异直接跳过、不算分 —— 我们要的是「语义变异」，
# 不是「语法破坏」；测「用例会不会崩」没有意义。
#
# 变异算子（只改语义，不改结构；不许删函数、不许插 exit 1、不许改路径/超时）：
#   cond    [ x = y ] ⇄ [ x != y ]     条件取反
#   logic   || ⇄ &&（只认前后带空格的） 逻辑取反
#   return  return 0 ⇄ return 1        返回取反
#
# 用法：
#   bash tools/mutation.sh --target FILE --test "CMD" \
#     [--min-score N] [--report FILE] [--root DIR] \
#     [--from-line N] [--to-line N] [--skip N]...
#
#   --target      要变异的文件（相对 --root，或 --root 内的绝对路径）
#   --test        在副本根目录里执行的命令；退出码判 KILLED / SURVIVED
#   --min-score   最低得分（百分比整数，默认 100）
#   --report      把 TSV 明细写进这个文件
#   --root        被测树的根（默认：本脚本上一级，即仓库根）
#   --from-line   只枚举 >= N 行的位点（默认 1）
#   --to-line     只枚举 <= N 行的位点（默认到文件尾）
#   --skip        跳过某个行号的位点（可重复；给「当前无判据」的位点用）
#
# 退出码：得分 ≥ --min-score ⇒ 0；不达标 ⇒ 1；用法错或没有可计分位点 ⇒ 2。
#
# stdout 只给数据（位点表 + 得分），日志一律 stderr。
# 位点枚举是确定性的：按行号升序、每行内按 cond → logic → return 的固定
# 顺序 —— 同一份树跑两次，位点集合与顺序完全一样。
#
# 得分只对「计分位点」负责。报告与 stdout 都会写清四层口径：
#   enumerated  区间里一共枚举到多少个位点
#   window      --max-sites 裁出的 campaign 窗口有多大
#   scored      窗口里去掉白名单之后，真正计分的位点数
#   skipped     被白名单跳过的位点数（逐条列在报告里）
# 不把这层口径摆出来，100% 会被读成「全都验过了」—— 实际可能只验了五分之一。
#
# 本文件也可以被 source：tests/test_meta_gates.sh 复用下面的变异原语
# （mut_copy_tree / mut_replace_func / mut_replace_line / mut_replace_block /
# mut_run_testfile），被 source 时不执行 main。
#

# --------------------------------------------------------------------------
# 原语（tests/test_meta_gates.sh 也复用这部分）
# --------------------------------------------------------------------------

# mut_copy_tree SRC DEST —— 复制一份够用的树到 DEST。
#
# 是 shellkit 仓库布局就只拷这几样：CLI、库、模板、测试基建、locale、
# 版本号与许可证（.git / docs / site / reports 对变异没有影响，拷了只会慢）。
# 不是这个布局（合成用例的小树）就全量拷（跳过 .git）。
# 权限必须一起复制（-p）：副本里的 shellkit 要能被执行。
mut_copy_tree() {
  local src=$1 dest=$2 item
  mkdir -p "$dest" || return 1
  # shellkit + lib 都在 ⇒ 仓库布局，只拷够用的几样（.git / docs / site /
  # reports 对变异没有影响，拷了只会慢）。缺任何一个（合成用例的小树）
  # 就全量拷（跳过 .git）。
  if [ -e "$src/shellkit" ] && [ -d "$src/lib" ]; then
    for item in shellkit repair.sh lib templates tests locale; do
      [ -e "$src/$item" ] || continue
      cp -Rp "$src/$item" "$dest/" || return 1
    done
    for item in VERSION LICENSE NOTICE; do
      [ -f "$src/$item" ] || continue
      cp -p "$src/$item" "$dest/$item" || return 1
    done
    return 0
  fi
  for item in "$src"/* "$src"/.[!.]*; do
    [ -e "$item" ] || continue
    case "${item##*/}" in
      .git) continue ;;
    esac
    cp -Rp "$item" "$dest/" || return 1
  done
  return 0
}

# mut_tmp —— 申请一个临时文件（mktemp 的包装，统一落在 TEST_TMP_ROOT 下）
mut_tmp() {
  mktemp "${TEST_TMP_ROOT:-${TMPDIR:-/tmp}}/mut.XXXXXX"
}

# mut_replace_func FILE FUNC BODYFILE —— 把 FILE 里 FUNC 的函数体换成 BODYFILE 的内容。
#
# 按结构找（行首的 'name() {' 到行首单独的 '}'），不依赖函数体里的具体文本，
# 所以函数内部被重构过也不会误伤。找不到目标就返回 1 ——
# 调用方必须判红，不许放过（放过等于变异测试自己变成假绿）。
mut_replace_func() {
  local file=$1 fn=$2 bodyfile=$3 tmp
  tmp=$(mut_tmp) || return 1
  awk -v fn="$fn" -v bf="$bodyfile" '
    function emit(   line) {
      while ((getline line < bf) > 0) print line
      close(bf)
    }
    $0 ~ "^" fn "\\(\\)[[:space:]]*\\{" { emit(); skipping = 1; next }
    skipping && $0 == "}" { skipping = 0; next }
    skipping { next }
    { print }
  ' "$file" >"$tmp" || {
    rm -f "$tmp"
    return 1
  }
  if cmp -s "$file" "$tmp"; then
    rm -f "$tmp"
    printf 'MUTATION TARGET NOT FOUND: function %s in %s\n' "$fn" "$file" >&2
    return 1
  fi
  cat "$tmp" >"$file"
  rm -f "$tmp"
  return 0
}

# mut_replace_line FILE PATTERN REPLACEMENT —— 把第一行含 PATTERN 的行换成 REPLACEMENT。
# PATTERN 是**字面量**（内部用 index，不当正则用）—— 模式里常有 [ $ 这类字符。
mut_replace_line() {
  local file=$1 pat=$2 repl=$3 tmp n
  n=$(grep -F -c -- "$pat" "$file" 2>/dev/null || true)
  case "$n" in
    '' | *[!0-9]*) n=0 ;;
  esac
  if [ "$n" -eq 0 ]; then
    printf 'MUTATION TARGET NOT FOUND: %s in %s\n' "$pat" "$file" >&2
    return 1
  fi
  tmp=$(mut_tmp) || return 1
  awk -v pat="$pat" -v repl="$repl" '
    !done && index($0, pat) > 0 { print repl; done = 1; next }
    { print }
  ' "$file" >"$tmp" || {
    rm -f "$tmp"
    return 1
  }
  cat "$tmp" >"$file"
  rm -f "$tmp"
  return 0
}

# mut_replace_block FILE START END REPLFILE —— 把从含 START 的行到含 END 的行
# （含端点）整段换成 REPLFILE 的内容。START / END 都是字面量。
mut_replace_block() {
  local file=$1 start=$2 end=$3 replfile=$4 tmp n
  n=$(grep -F -c -- "$start" "$file" 2>/dev/null || true)
  case "$n" in
    '' | *[!0-9]*) n=0 ;;
  esac
  if [ "$n" -eq 0 ]; then
    printf 'MUTATION TARGET NOT FOUND: %s in %s\n' "$start" "$file" >&2
    return 1
  fi
  tmp=$(mut_tmp) || return 1
  awk -v s="$start" -v e="$end" -v rf="$replfile" '
    function emit(   line) {
      while ((getline line < rf) > 0) print line
      close(rf)
    }
    !inside && index($0, s) > 0 { emit(); inside = 1; next }
    inside && index($0, e) > 0 { inside = 0; next }
    inside { next }
    { print }
  ' "$file" >"$tmp" || {
    rm -f "$tmp"
    return 1
  }
  cat "$tmp" >"$file"
  rm -f "$tmp"
  return 0
}

# mut_run_testfile DIR TESTFILE LOG —— 在 DIR 里跑 tests/TESTFILE，返回退出码（日志写 LOG）
mut_run_testfile() {
  local dir=$1 testfile=$2 log=$3 rc=0
  mkdir -p "$dir/tmp" || return 1
  (
    cd "$dir" || exit 1
    TEST_TMP_ROOT="$dir/tmp" bash "tests/$testfile"
  ) >"$log" 2>&1 || rc=$?
  printf '%s' "$rc"
}

# --------------------------------------------------------------------------
# 位点枚举与应用
# --------------------------------------------------------------------------

# mut_enum_sites FILE [FROMLINE [TOLINE]] —— 枚举变异位点。
#
# 输出 TSV（每行一个位点）：line <TAB> op <TAB> from <TAB> to
#   op ∈ {cond, logic, return}；from/to 是**带原样空格**的替换 token
#   （cond: ' = '/' != '，logic: ' || '/' && '，return: 'return 0'/'return 1'），
#   应用时用 index() 字面量替换，正则特殊字符不会误入。
# 确定性：按行号升序；同一行内 cond → logic(|| 先于 &&) → return(0 先于 1)。
# 每行的每种算子至多一个位点（只替换第一次出现）；一行里 || 与 && 都有时
# 是两个独立位点。
mut_enum_sites() {
  local file=$1 from=${2:-1} to=${3:-2147483647}
  awk -v from="$from" -v to="$to" '
    # word_pos —— STR 里 WORD 作为独立命令词出现的位置（0 = 没有）。
    # 前面必须是行首/空白/分号/括号，后面必须是空白/分号/结尾 ——
    # 字符串里的 "return 0" 不算位点。
    # 边界判定用 index() 不用正则：注释行里 "return 0" 的前后是多字节
    # 字符时，BSD awk 在 C.UTF-8 locale 下对多字节字符跑字符类正则会
    # towc 崩掉（gawk / Linux 没问题，macOS 自带 awk 会）。
    function word_pos(str, word,   pos, before, after) {
      pos = index(str, word)
      if (pos == 0) return 0
      before = pos > 1 ? substr(str, pos - 1, 1) : " "
      after = substr(str, pos + length(word), 1)
      if (index(" \t;|(&(", before) == 0 && pos != 1) return 0
      if (after != "" && index(" \t;|)&", after) == 0) return 0
      return pos
    }
    NR < from || NR > to { next }
    {
      # cond：行里同时有 [ 和 ] 才算（避开 case 模式与字符串）
      if (index($0, "[") > 0 && index($0, "]") > 0) {
        if (index($0, " != ") > 0) printf "%d\tcond\t != \t = \n", NR
        if (index($0, " = ") > 0) printf "%d\tcond\t = \t != \n", NR
      }
      # logic：只认前后带空格的，免得误伤 ||: 这类紧凑惯用法
      if (index($0, " || ") > 0) printf "%d\tlogic\t || \t && \n", NR
      if (index($0, " && ") > 0) printf "%d\tlogic\t && \t || \n", NR
      if (word_pos($0, "return 0") > 0) printf "%d\treturn\treturn 0\treturn 1\n", NR
      if (word_pos($0, "return 1") > 0) printf "%d\treturn\treturn 1\treturn 0\n", NR
    }
  ' "$file"
}

# mut_apply_site FILE LINE FROM TO —— 把 FILE 第 LINE 行的第一个 FROM 换成 TO。
# FROM 是字面量（index 替换）。该行不含 FROM ⇒ 返回 3（枚举与应用脱节，要吵出来）。
mut_apply_site() {
  local file=$1 line=$2 from=$3 to=$4 tmp rc
  tmp=$(mut_tmp) || return 1
  awk -v l="$line" -v from="$from" -v to="$to" '
    NR == l {
      pos = index($0, from)
      if (pos == 0) {
        printf "site line %d does not contain %s\n", l, from > "/dev/stderr"
        exit 3
      }
      $0 = substr($0, 1, pos - 1) to substr($0, pos + length(from))
    }
    { print }
  ' "$file" >"$tmp" || {
    rc=$?
    rm -f "$tmp"
    return "$rc"
  }
  cat "$tmp" >"$file"
  rm -f "$tmp"
  return 0
}

# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

mut_usage() {
  cat >&2 <<'EOF'
usage: bash tools/mutation.sh --target FILE --test "CMD" [options]

  --target FILE     要变异的文件（相对 --root 或 --root 内的绝对路径）
  --test CMD        在副本根目录里执行的命令（退出码非 0 ⇒ KILLED）
  --min-score N     最低得分，百分比整数（默认 100）
  --report FILE     把 TSV 明细写进这个文件
  --root DIR        被测树的根（默认：tools/ 的上一级）
  --from-line N     只枚举 >= N 行的位点（默认 1）
  --to-line N       只枚举 <= N 行的位点（默认到文件尾）
  --skip N          跳过某行号的位点（可重复；"N:op" 只跳过某算子）
  --max-sites N     只跑枚举顺序里的前 N 个位点（有界 campaign 用）

报告里会写清四层口径：枚举到的位点、campaign 窗口、计分位点、白名单跳过的位点 ——
得分只对计分位点负责，不把「跳过了几个」藏起来。
  -h, --help        显示这段帮助
EOF
}

mut_die_usage() {
  printf 'mutation: %s\n' "$*" >&2
  mut_usage
  exit 2
}

mut_main() {
  local mut_tab
  mut_tab=$(printf '\t')
  local target="" test_cmd="" min_score=100 report="" root=""
  local from_line=1 to_line=2147483647 skips="" opt max_sites=0
  local script_dir rel work tree nsites rc
  local line op from to killed survived score
  local n_all n_window n_skipped

  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

  while [ $# -gt 0 ]; do
    opt=$1
    case $opt in
      --target | --test | --min-score | --report | --root | --from-line | --to-line | --skip | --max-sites)
        [ $# -ge 2 ] || mut_die_usage "$opt needs an argument"
        case $opt in
          --target) target=$2 ;;
          --test) test_cmd=$2 ;;
          --min-score) min_score=$2 ;;
          --report) report=$2 ;;
          --root) root=$2 ;;
          --from-line) from_line=$2 ;;
          --to-line) to_line=$2 ;;
          --skip) skips="$skips $2" ;;
          --max-sites) max_sites=$2 ;;
        esac
        shift 2
        ;;
      --target=* | --test=* | --min-score=* | --report=* | --root=* | --from-line=* | --to-line=* | --skip=* | --max-sites=*)
        case $opt in
          --target=*) target=${opt#*=} ;;
          --test=*) test_cmd=${opt#*=} ;;
          --min-score=*) min_score=${opt#*=} ;;
          --report=*) report=${opt#*=} ;;
          --root=*) root=${opt#*=} ;;
          --from-line=*) from_line=${opt#*=} ;;
          --to-line=*) to_line=${opt#*=} ;;
          --skip=*) skips="$skips ${opt#*=}" ;;
          --max-sites=*) max_sites=${opt#*=} ;;
        esac
        shift
        ;;
      -h | --help)
        mut_usage
        exit 0
        ;;
      *)
        mut_die_usage "unknown option: $opt"
        ;;
    esac
  done

  # ---- 校验 ----
  [ -n "$target" ] || mut_die_usage "--target is required"
  [ -n "$test_cmd" ] || mut_die_usage "--test is required"
  case $min_score in
    '' | *[!0-9]*) mut_die_usage "--min-score must be an integer percentage" ;;
  esac
  [ "$min_score" -ge 0 ] && [ "$min_score" -le 100 ] ||
    mut_die_usage "--min-score must be between 0 and 100"
  for opt in "$from_line" "$to_line"; do
    case $opt in
      '' | *[!0-9]*) mut_die_usage "--from-line/--to-line must be positive integers" ;;
    esac
  done
  [ "$root" ] || root=$(cd "$script_dir/.." && pwd)
  [ -d "$root" ] || mut_die_usage "--root is not a directory: $root"

  # target 归一化成 root 内的相对路径
  case $target in
    "$root"/*) rel=${target#"$root"/} ;;
    /*) mut_die_usage "--target must be inside --root: $target" ;;
    *) rel=$target ;;
  esac
  [ -f "$root/$rel" ] || mut_die_usage "--target not found: $root/$rel"
  case $rel in
    */../* | ../*) mut_die_usage "--target must stay inside --root: $rel" ;;
  esac

  # ---- 搭副本 ----
  work=$(mktemp -d "${TMPDIR:-/tmp}/shellkit-mut.XXXXXX") ||
    mut_die_usage "cannot create workdir"
  trap 'rm -rf "$work"' EXIT
  tree=$work/tree
  printf 'mutation: copying %s ...\n' "$root" >&2
  mut_copy_tree "$root" "$tree" || mut_die_usage "cannot copy the tree"
  [ -f "$tree/$rel" ] || mut_die_usage "copy missed the target: $rel"
  cp -p "$tree/$rel" "$work/pristine"

  # ---- 未变异前测必须是绿的 ----
  # 「变异后变红」说明不了任何事，如果这套测试在没动过的副本上本来就是红的
  # （环境缺东西、夹具坏了、tmp 建不出来）——那样每个变异都会「假被杀灭」。
  mkdir -p "$tree/tmp" || mut_die_usage "cannot create $tree/tmp"
  printf 'mutation: sanity-checking the test on the unmutated copy ...\n' >&2
  (
    cd "$tree" || exit 97
    TEST_TMP_ROOT="$tree/tmp" bash -c "$test_cmd"
  ) >"$work/preflight.log" 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'mutation: the test is red on an UNMUTATED copy (rc=%d) — fix the test or the tree first (log: %s)\n' \
      "$rc" "$work/preflight.log" >&2
    exit 2
  fi

  # ---- 枚举位点 ----
  # --max-sites 先裁：只取枚举顺序里的前 N 个位点；--skip 再从中过滤 ——
  # 这样「前 12 个位点、白名单除外」的 campaign 口径是稳定的，与位点
  # 内容无关。--skip 的匹配口径："N" 跳过第 N 行的全部位点，"N:op" 只跳过某算子。
  case $max_sites in
    '' | *[!0-9]*) mut_die_usage "--max-sites must be a positive integer" ;;
  esac
  : >"$work/all_sites"
  n_all=0
  while IFS=$mut_tab read -r line op from to; do
    [ -n "$line" ] || continue
    n_all=$((n_all + 1))
    printf '%s\t%s\t%s\t%s\n' "$line" "$op" "$from" "$to" >>"$work/all_sites"
  done <<MUT_SITES_EOF
$(mut_enum_sites "$root/$rel" "$from_line" "$to_line")
MUT_SITES_EOF

  # --max-sites 先裁：只取枚举顺序里的前 N 个位点；--skip 再从中过滤 ——
  # 这样「前 12 个位点、白名单除外」的 campaign 口径是稳定的，与位点
  # 内容无关。--skip 的匹配口径："N" 跳过第 N 行的全部位点，"N:op" 只跳过某算子。
  n_window=0
  : >"$work/window"
  while IFS=$mut_tab read -r line op from to; do
    [ -n "$line" ] || continue
    if [ "$max_sites" -gt 0 ]; then
      [ "$n_window" -ge "$max_sites" ] && break
    fi
    n_window=$((n_window + 1))
    printf '%s\t%s\t%s\t%s\n' "$line" "$op" "$from" "$to" >>"$work/window"
  done <"$work/all_sites"

  : >"$work/sites"
  : >"$work/skipped_sites"
  n_skipped=0
  while IFS=$mut_tab read -r line op from to; do
    [ -n "$line" ] || continue
    case " $skips " in
      *" $line "* | *" $line:$op "*)
        n_skipped=$((n_skipped + 1))
        printf '%s\t%s\t%s\t%s\n' "$line" "$op" "$from" "$to" >>"$work/skipped_sites"
        continue
        ;;
    esac
    printf '%s\t%s\t%s\t%s\n' "$line" "$op" "$from" "$to" >>"$work/sites"
  done <"$work/window"

  nsites=$(grep -c '' "$work/sites" 2>/dev/null || true)
  case $nsites in
    '' | *[!0-9]*) nsites=0 ;;
  esac
  if [ "$nsites" -eq 0 ]; then
    printf 'mutation: no mutation sites in range %s-%s (skips:%s)\n' \
      "$from_line" "$to_line" "${skips# }" >&2
    exit 2
  fi
  printf 'mutation: %d site(s) to test (enumerated %d, window %d, skipped %d, max-sites %s, skips:%s)\n' \
    "$nsites" "$n_all" "$n_window" "$n_skipped" "$max_sites" "${skips# }" >&2

  # ---- 逐个变异 ----
  : >"$work/results"
  while IFS=$mut_tab read -r line op from to; do
    [ -n "$line" ] || continue
    mut_apply_site "$tree/$rel" "$line" "$from" "$to" || {
      printf 'mutation: line %d: cannot apply %s -> %s\n' "$line" "$from" "$to" >&2
      exit 2
    }
    if ! bash -n "$tree/$rel" 2>"$work/basn.log"; then
      # 解析不过的变异跳过且不算分 —— 只认语义变异，不认语法破坏
      cat "$work/pristine" >"$tree/$rel"
      printf 'mutation: line %d: %s -> %s unparsable, skipped\n' "$line" "$from" "$to" >&2
      printf '%s\t%s\t%s\t%s\tSKIPPED(unparsable)\n' "$line" "$op" "$from" "$to" >>"$work/results"
      continue
    fi
    printf 'mutation: line %d: %s -> %s running test ...\n' "$line" "$from" "$to" >&2
    (
      cd "$tree" || exit 97
      TEST_TMP_ROOT="$tree/tmp" bash -c "$test_cmd"
    ) >"$work/run.log" 2>&1
    rc=$?
    cat "$work/pristine" >"$tree/$rel"
    if [ "$rc" -ne 0 ]; then
      printf 'mutation: line %d: KILLED (rc=%d)\n' "$line" "$rc" >&2
      printf '%s\t%s\t%s\t%s\tKILLED\n' "$line" "$op" "$from" "$to" >>"$work/results"
    else
      printf 'mutation: line %d: SURVIVED\n' "$line" >&2
      printf '%s\t%s\t%s\t%s\tSURVIVED\n' "$line" "$op" "$from" "$to" >>"$work/results"
    fi
  done <"$work/sites"

  # ---- 计分 ----
  score=$(awk -F '\t' '
    $5 == "KILLED" { k += 1 }
    $5 == "SURVIVED" { s += 1 }
    END {
      if (k + s == 0) { printf "-1" }
      else { printf "%d", k * 100 / (k + s) }
    }
  ' "$work/results")
  case $score in
    -1)
      printf 'mutation: no scorable sites (all skipped as unparsable)\n' >&2
      exit 2
      ;;
  esac

  # ---- 输出 ----
  # stdout：表 + 得分（数据只走 stdout，进度与判读一律 stderr）
  printf '%-6s %-7s %-18s %s\n' LINE OP MUTATION RESULT
  printf '%-6s %-7s %-18s %s\n' ---- --- ------- ------
  awk -F '\t' '{ printf "%-6s %-7s %-18s %s\n", $1, $2, $3 " ->" $4, $5 }' "$work/results"
  killed=$(awk -F '\t' '$5 == "KILLED" { n += 1 } END { printf "%d", n + 0 }' "$work/results")
  survived=$(awk -F '\t' '$5 == "SURVIVED" { n += 1 } END { printf "%d", n + 0 }' "$work/results")
  printf 'score: %d%% (%d/%d killed)\n' "$score" "$killed" "$((killed + survived))"
  # 得分只对「计分位点」负责：枚举了多少、窗口多大、白名单跳过了几个，
  # 一起写出来 —— 否则 100% 会被读成「全都验过了」。
  printf 'scope: %d enumerated, %d in the campaign window, %d scored, %d skipped by the whitelist\n' \
    "$n_all" "$n_window" "$nsites" "$n_skipped"

  if [ -n "$report" ]; then
    {
      printf '# shellkit mutation report\n'
      printf 'target: %s\n' "$rel"
      printf 'test: %s\n' "$test_cmd"
      printf 'range: %s-%s\n' "$from_line" "$to_line"
      printf 'sites enumerated: %d\n' "$n_all"
      printf 'campaign window: %d\n' "$n_window"
      printf 'scored: %d\n' "$nsites"
      printf 'skipped: %d\n' "$n_skipped"
      if [ -n "${skips# }" ]; then
        printf 'skipped lines: %s\n' "${skips# }"
      fi
      printf 'killed: %d\n' "$killed"
      printf 'survived: %d\n' "$survived"
      printf 'score: %d%%\n' "$score"
      printf '\n'
      printf 'LINE\tOP\tFROM\tTO\tRESULT\n'
      cat "$work/results"
      if [ "$n_skipped" -gt 0 ]; then
        printf '\n'
        printf '# skipped by the whitelist (not scored)\n'
        printf 'LINE\tOP\tFROM\tTO\n'
        cat "$work/skipped_sites"
      fi
    } >"$work/report"
    mv -f "$work/report" "$report" || {
      printf 'mutation: cannot write report: %s\n' "$report" >&2
      exit 2
    }
  fi

  if [ "$score" -ge "$min_score" ]; then
    exit 0
  fi
  printf 'mutation: score %d%% below minimum %d%%\n' "$score" "$min_score" >&2
  exit 1
}

# 被 source（tests/test_meta_gates.sh 复用原语）时不执行 main
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  mut_main "$@"
fi
