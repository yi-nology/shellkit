#!/usr/bin/env bash
#
# 复核 v0.12.0 规划所依据的每条缺陷。
#
# 用法:
#   bash reports/repro/verify-0.12.sh            # 跑全部用例
#   bash reports/repro/verify-0.12.sh cmds-csv   # 只跑一个
#
# 每个用例都打印一行结论:
#   缺陷存在  —— 复现成功，规划里的判断成立
#   未复现    —— 现在已经好了（或者结论要改）
#
# 全部用例都是确定性的：不依赖网络，不用 root，不用 sleep 猜时间。
set -u

ROOT="${SHELLKIT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sk-verify.XXXXXX")"
trap 'rm -rf "${WORK:?}"' EXIT

# clean_path —— 去掉 PATH 里的 mavis shim（本机 rm 会被接管成回收站，很慢）
CLEAN_PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -v 'minimax/shims' | paste -sd: -)"

pass() { printf '  结论: %s\n' "$1"; }
case_() { printf '\n=== %s ===\n' "$1"; }

make_project() {
  # make_project DIR —— 在 DIR 造一个 shellkit 生成的工程
  local d=$1
  "$ROOT/shellkit" new --name tool "$d" --cmd run --yes >/dev/null 2>&1
}

make_tpl() {
  # make_tpl DIR —— 把模板拷一份出来待改
  local d=$1
  cp -R "$ROOT/templates" "$d"
}

# ---------------------------------------------------------------- 用例 1
# 缺陷：升级的「写盘失败」分支引用了尚未赋值的 __cmds_csv
#       => set -u 下直接崩溃（unbound variable），清单不落盘、临时目录不清理
case_cmds_csv() {
  case_ "cmds-csv：写盘失败分支上的 unbound variable"
  local tpl="$WORK/tpl" proj="$WORK/proj" shim="$WORK/shim"
  make_tpl "$tpl"
  make_project "$proj"
  printf '\nTEMPLATE CHANGED\n' >>"$tpl/AGENTS.md"

  mkdir -p "$shim"
  cat >"$shim/cp" <<'EOS'
#!/usr/bin/env bash
dest=""
for a in "$@"; do dest="$a"; done
case "$dest" in
*/AGENTS.md) echo "cp: injected failure" >&2; exit 1 ;;
esac
exec /bin/cp "$@"
EOS
  chmod +x "$shim/cp"

  local out rc=0
  out=$(PATH="$shim:$CLEAN_PATH" "$ROOT/shellkit" upgrade "$proj" --template "$tpl" 2>&1) || rc=$?
  printf '  退出码: %s\n' "$rc"
  printf '%s\n' "$out" | grep 'unbound variable' | sed 's/^/  /'
  printf '%s\n' "$out" | grep -q 'unbound variable' &&
    pass "缺陷存在" || pass "未复现"
}

# ---------------------------------------------------------------- 用例 2
# 缺陷：清单里的 name 没做校验 => 路径穿越，升级会写到工程目录之外
case_traversal() {
  case_ "traversal：清单 name 里的 ../ 会写到工程外"
  local tpl="$WORK/tpl" victim="$WORK/victim" outside="$WORK/OUTSIDE"
  make_tpl "$tpl"
  mkdir -p "$victim"
  printf 'ORIGINAL CONTENT\n' >"$outside"
  local hash
  hash=$(shasum -a 256 "$outside" | awk '{print $1}')
  cat >"$victim/.shellkit-manifest" <<EOF
# shellkit manifest v1
manifest_version=2
version=0.11.0
template_version=0.11.0
name=../../OUTSIDE
commands=run
@file bin/../../OUTSIDE $hash
EOF

  local out rc=0
  out=$("$ROOT/shellkit" upgrade "$victim" --template "$tpl" 2>&1) || rc=$?
  printf '  退出码: %s（缺陷存在时这里是 0 —— 静默越界）\n' "$rc"
  if head -1 "$outside" | grep -q 'ORIGINAL CONTENT'; then
    printf '  工程外的文件: 未被改动\n'
    pass "未复现"
  else
    printf '  工程外的文件已被覆盖，首行变成: %s\n' "$(head -1 "$outside")"
    pass "缺陷存在"
  fi
}

# ---------------------------------------------------------------- 用例 3
# 缺陷：升级写文件时跟随符号链接 => 写穿到工程目录之外
case_symlink() {
  case_ "symlink：升级写穿符号链接"
  local tpl="$WORK/tpl" proj="$WORK/proj" outside="$WORK/OUTSIDE"
  make_tpl "$tpl"
  make_project "$proj"
  printf 'ORIGINAL CONTENT\n' >"$outside"

  # 变体一：悬空链接（目标还不存在）=> 升级「补文件」时在工程外创建文件
  local dangling="$WORK/DANGLING"
  rm -f "$proj/README.md"
  ln -s "$dangling" "$proj/README.md"
  "$ROOT/shellkit" upgrade "$proj" --template "$tpl" >/dev/null 2>&1
  if [ -e "$dangling" ]; then
    printf '  变体一（悬空链接）: 工程外的文件被创建了（内容首行: %s）\n' "$(head -1 "$dangling")"
  else
    printf '  变体一（悬空链接）: 工程外未被创建\n'
  fi

  # 变体二：链接指向既有文件 + --force => 覆盖工程外的文件
  rm -f "$proj/README.md"
  ln -s "$outside" "$proj/README.md"
  printf 'ORIGINAL CONTENT\n' >"$outside"
  "$ROOT/shellkit" upgrade --force "$proj" --template "$tpl" >/dev/null 2>&1
  if head -1 "$outside" | grep -q 'ORIGINAL CONTENT'; then
    printf '  变体二（--force）: 工程外的文件未被改动\n'
    pass "未复现"
  else
    printf '  变体二（--force）: 工程外的文件被覆盖了\n'
    pass "缺陷存在"
  fi
}

# ---------------------------------------------------------------- 用例 4
# 缺陷：run 的日志脱敏漏掉 X-*-Key/Token 头与 curl -u
case_redact() {
  case_ "redact：日志脱敏的漏网形态"
  # shellcheck source=/dev/null
  . "$ROOT/lib/bootstrap.sh"
  local leak=0
  local probe
  for probe in 'curl -H X-API-Key:secretvalue' 'curl -H X-Auth-Token:secretvalue' 'curl -u admin:secretvalue'; do
    # shellcheck disable=SC2086
    local line
    line=$(run --no-die sh -c "exit 1" $probe 2>&1 | grep 'command failed' || true)
    if printf '%s' "$line" | grep -q 'secretvalue'; then
      printf '  漏网: %s\n' "$probe"
      leak=1
    fi
  done
  [ "$leak" = "1" ] && pass "缺陷存在" || pass "未复现"
}

# ---------------------------------------------------------------- 用例 5
# 缺陷：后台启动的进程默认忽略 SIGINT => 「中途被杀」用例根本没杀到
case_interrupt() {
  case_ "interrupt：SIGINT 送不到后台进程"
  bash -c 'trap "echo GOT_INT" INT; sleep 1; echo FINISHED' &
  local p=$!
  sleep 0.2
  kill -INT "$p" 2>/dev/null || true
  wait "$p" 2>/dev/null || true
  echo
}

# ---------------------------------------------------------------- 用例 6
# 缺陷：cp 写到一半被打断 => 目标文件被截断（不是旧内容，也不是新内容）
case_atomicity() {
  case_ "atomicity：cp 被打断后目标被截断"
  local src="$WORK/src.bin" dst="$WORK/dst.bin"
  dd if=/dev/zero of="$src" bs=1m count=200 2>/dev/null
  cp "$src" "$dst" &
  local p=$!
  sleep 0.03
  kill -9 "$p" 2>/dev/null || true
  wait "$p" 2>/dev/null || true
  if [ -e "$dst" ]; then
    printf '  目标文件大小: %s 字节（源 209715200）\n' "$(wc -c <"$dst" | tr -d ' ')"
    pass "缺陷存在（目标被截断）"
  else
    pass "未复现"
  fi
}

main() {
  local only="${1:-}"
  local all="cmds-csv traversal symlink redact interrupt atomicity"
  local c fn
  for c in $all; do
    if [ -n "$only" ] && [ "$only" != "$c" ]; then continue; fi
    fn="case_$(printf '%s' "$c" | tr '-' '_')"
    "$fn"
  done
  printf '\n（工作目录已清理）\n'
}

main "$@"
