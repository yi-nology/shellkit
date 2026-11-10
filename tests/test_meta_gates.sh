#!/usr/bin/env bash
#
# 元测试：门禁自己也要被测。
#
# 要防的是这件事：「缺陷 1 存在，而门禁全绿」——
# 回归用例自己写错了（比如只断言了退出码、没断言实际行为），
# 绿灯就没有意义，缺陷会一路漏到用户手里。
#
# 做法：把已经修好的缺陷**重新造回库里**，再跑对应的回归用例，
# 用例**必须变红**。不变红 ⇒ 这个用例对那个缺陷没有判据能力。
#
# 三条纪律：
#   1) 变异只在副本里做，真库一个字节都不动；
#   2) 变异目标找不到（库被重构了）⇒ 直接判红并说明「元测试需要更新」，
#      不静默放过 —— 放过就等于元测试自己变成假绿；
#   3) 每个用例先在**未变异的副本**上跑一遍确认是绿的，
#      否则「变红了」说明不了任何事。
#
# 依赖：只有 bash + awk + 基础 coreutils。
# CI 的最小容器里没有 jq / python3 / curl，这个文件照样要能跑。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

# --------------------------------------------------------------------------
# 工具
# --------------------------------------------------------------------------

# _meta_copy_tree DEST —— 复制一份够用的树到 DEST。
#
# 只复制这几个：CLI、库、模板、测试基建、locale、版本号与许可证。
# 不复制 .git / docs / site / reports —— 对这几个用例没有影响，复制只会慢。
# 权限必须一起复制（-p）：副本里的 shellkit 要能被执行。
_meta_copy_tree() {
  local dest=$1 item
  mkdir -p "$dest" || return 1
  for item in shellkit lib templates tests locale; do
    [ -e "$TEST_ROOT/$item" ] || continue
    cp -Rp "$TEST_ROOT/$item" "$dest/" || return 1
  done
  for item in VERSION LICENSE NOTICE; do
    [ -f "$TEST_ROOT/$item" ] || continue
    cp -p "$TEST_ROOT/$item" "$dest/$item" || return 1
  done
  return 0
}

# _meta_mutate_func FILE FUNC BODYFILE —— 把 FILE 里 FUNC 的函数体换成 BODYFILE 的内容。
#
# 按结构找（行首的 `name() {` 到行首单独的 `}`），不依赖函数体里的具体文本，
# 所以函数内部被重构过也不会误伤。找不到目标就返回 1 ——
# 调用方必须判红，不许放过（放过等于元测试自己变成假绿）。
_meta_mutate_func() {
  local file=$1 fn=$2 bodyfile=$3 tmp
  tmp=$(mktemp "$TEST_TMP_ROOT/meta.XXXXXX") || return 1
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

# _meta_mutate_line FILE PATTERN REPLACEMENT —— 把第一行含 PATTERN 的行换成 REPLACEMENT。
# PATTERN 是**字面量**（内部用 index，不当正则用）—— 模式里常有 [ $ 这类字符。
_meta_mutate_line() {
  local file=$1 pat=$2 repl=$3 tmp n
  n=$(grep -F -c -- "$pat" "$file" 2>/dev/null || true)
  case "$n" in
    '' | *[!0-9]*) n=0 ;;
  esac
  if [ "$n" -eq 0 ]; then
    printf 'MUTATION TARGET NOT FOUND: %s in %s\n' "$pat" "$file" >&2
    return 1
  fi
  tmp=$(mktemp "$TEST_TMP_ROOT/meta.XXXXXX") || return 1
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

# _meta_mutate_block FILE START END REPLFILE —— 把从含 START 的行到含 END 的行
# （含端点）整段换成 REPLFILE 的内容。START / END 都是字面量。
_meta_mutate_block() {
  local file=$1 start=$2 end=$3 replfile=$4 tmp n
  n=$(grep -F -c -- "$start" "$file" 2>/dev/null || true)
  case "$n" in
    '' | *[!0-9]*) n=0 ;;
  esac
  if [ "$n" -eq 0 ]; then
    printf 'MUTATION TARGET NOT FOUND: %s in %s\n' "$start" "$file" >&2
    return 1
  fi
  tmp=$(mktemp "$TEST_TMP_ROOT/meta.XXXXXX") || return 1
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

# _meta_run DIR TESTFILE LOG —— 在 DIR 里跑 TESTFILE，返回退出码（日志写 LOG）
_meta_run() {
  local dir=$1 testfile=$2 log=$3 rc=0
  mkdir -p "$dir/tmp" || return 1
  (
    cd "$dir" || exit 1
    TEST_TMP_ROOT="$dir/tmp" bash "tests/$testfile"
  ) >"$log" 2>&1 || rc=$?
  printf '%s' "$rc"
}

# _meta_expect_red INDEX LABEL TARGET MUTATOR —— 造一次变异，要求 TARGET 变红。
#
# MUTATOR 收到副本根目录，成功返回 0；找不到变异目标返回 1（此时判红，
# 因为「库被重构了」本身就是要人知道的事，不该静默变成绿灯）。
#
# ⚠️ 目录名只能用编号，不能带意义的词：临时目录名会出现在被测用例的
# 输出里（路径），目标用例常有 assert_contains "$out" "关键词" 这种断言 ——
# 目录名里的词一旦撞上关键词，那条断言就被路径白送了，变异会显得「没打中」。
# （这个坑真的踩过：目录名叫 case.symlink-guard，守卫用例断言输出里有
# "symlink"，结果路径里的目录名就把断言满足了，缺陷造回去了用例还是绿的。）
_meta_expect_red() {
  local idx=$1 label=$2 target=$3 mutator=$4
  local dir="$TEST_TMP_ROOT/case.$idx" log="$TEST_TMP_ROOT/case.$idx.log" rc
  rm -rf "${dir:?}"
  _meta_copy_tree "$dir" || _fail "meta[$label]: cannot copy the tree"
  if ! "$mutator" "$dir"; then
    _fail "meta[$label]: the mutation target is gone — the library was refactored, so this meta test needs an update (log: $log)"
  fi
  rc=$(_meta_run "$dir" "$target" "$log")
  if [ "$rc" -eq 0 ]; then
    _fail "meta[$label]: with the defect back, $target is still green — that test cannot detect this defect (log: $log)"
  fi
  printf 'ok  %-16s %s went red (exit %s)\n' "$label" "$target" "$rc"
}

# _meta_expect_green INDEX LABEL TARGET —— 未变异的副本里 TARGET 必须是绿的。
# 不然「变红了」说明不了任何事（可能只是这个用例本来就红）。
_meta_expect_green() {
  local idx=$1 label=$2 target=$3
  local dir="$TEST_TMP_ROOT/green.$idx" log="$TEST_TMP_ROOT/green.$idx.log" rc
  rm -rf "${dir:?}"
  _meta_copy_tree "$dir" || _fail "meta[$label]: cannot copy the tree"
  rc=$(_meta_run "$dir" "$target" "$log")
  if [ "$rc" -ne 0 ]; then
    _fail "meta[$label]: $target is already red on an unmutated copy (log: $log)"
  fi
}

# --------------------------------------------------------------------------
# 变异器：每个都把一个已修好的缺陷重新造回去
# --------------------------------------------------------------------------

# 变异 1：清单里的项目名校验失效（什么都接受）
_meta_mut_name_ok() {
  local dir=$1 body="$TEST_TMP_ROOT/body.name_ok"
  cat >"$body" <<'EOF'
{
  return 0
}
EOF
  _meta_mutate_func "$dir/shellkit" "_sk_valid_name" "$body"
}

# 变异 2：目标是不是符号链接的判定被关掉（跟着链接写穿）
_meta_mut_symlink_ok() {
  local dir=$1
  _meta_mutate_line "$dir/shellkit" 'if [ -L "$__target" ]; then' 'if false; then'
}

# 变异 3：原子拷贝退回 cp -f（写一半被打断 ⇒ 留下半截文件）
_meta_mut_atomic_copy() {
  local dir=$1 body="$TEST_TMP_ROOT/body.atomic_copy"
  cat >"$body" <<'EOF'
{
  cp -f "$1" "$2"
  return 0
}
EOF
  _meta_mutate_func "$dir/lib/core/fs.sh" "fs_atomic_copy" "$body"
}

# 变异 4：http 的 jq-less 兜底退回「一行 JSON 上贪婪匹配」（取最后一个资产）
_meta_mut_http_greedy() {
  local dir=$1 repl="$TEST_TMP_ROOT/body.http_greedy"
  cat >"$repl" <<'EOF'
    __out=$(printf '%s\n' "$__body" | grep '"browser_download_url"' | grep -E -- "$__pat" |
      sed -E 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/') || __out=""
EOF
  _meta_mutate_block "$dir/lib/core/http.sh" \
    "__out=\$(printf '%s' \"\$__body\" | tr ','" \
    "sed -n '1p') || __out=\"\"" \
    "$repl"
}

# --------------------------------------------------------------------------
# 用例
# --------------------------------------------------------------------------

# CASE: 清单里的项目名校验坏掉时，升级守卫用例必须变红
_meta_expect_green 1 "name-check" "test_upgrade_guard.sh"
_meta_expect_red 1 "name-check" "test_upgrade_guard.sh" _meta_mut_name_ok

# CASE: 符号链接的判定坏掉时，升级守卫用例必须变红
_meta_expect_red 2 "link-check" "test_upgrade_guard.sh" _meta_mut_symlink_ok

# CASE: 原子拷贝退回 cp -f 时，原子写用例必须变红
_meta_expect_green 3 "atomic-copy" "test_upgrade_atomic.sh"
_meta_expect_red 3 "atomic-copy" "test_upgrade_atomic.sh" _meta_mut_atomic_copy

# CASE: http 的兜底退回贪婪匹配时，http 用例必须变红
_meta_expect_green 4 "http-fallback" "test_http.sh"
_meta_expect_red 4 "http-fallback" "test_http.sh" _meta_mut_http_greedy

exit 0
