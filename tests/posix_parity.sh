#!/bin/sh
#
# POSIX 子集与 bash core 的**差分对拍**探针。
#
# 为什么要有它：v1.4.1 那轮对拍只查了 4 个函数（lock ×2 / ver_cmp / retry），
# 就挖出 4 条真分叉（含一条静默失效）。剩下二十来个同名函数**从没对拍过** ——
# 「同名不同义」的缺陷在设备侧是静默的：脚本从主库抄到 POSIX 子集（或反过来），
# 退出码、消息、清理内容悄悄变了，而现场装不了 shellkit 补救。
#
# 用法（两侧各跑一次，输出逐行比对）：
#   sh   tests/posix_parity.sh                     # POSIX 子集一侧
#   SK_PARITY_SIDE=bash bash tests/posix_parity.sh  # bash core 一侧
#
# 输出格式：一行一条，字段用 TAB 分隔：
#   用例名 <TAB> 退出码 <TAB> stdout（压成一行） <TAB> stderr（压成一行）
#
# **调用一律按主库口径写**（die 先退出码后消息、trap_push 收全部参数…）：
# 这份文件要能原样在两边跑 —— 它测的就是「同一份调用在两边是否同义」。
#
# 不在差集里的：conf_init。主库支持 dotenv，POSIX 子集只支持 env ⇒ 这是
# **声明过的能力边界**（capabilities.tsv 里写明），不是隐藏分叉。
set -u

_pp_root=$(cd "$(dirname "$0")/.." && pwd)
_pp_side="${SK_PARITY_SIDE:-posix}"

# 两边都要安静可比：把会改变输出的环境变量钉死
SHELLKIT_LANG=en
SHELLKIT_LOG_LEVEL=info
SHELLKIT_LOG_FORMAT=text
SHELLKIT_STATUS_MODE=human
SHELLKIT_COLOR=never
SK_COLOR_ON=0
SHELLKIT_DEBUG=0
export SHELLKIT_LANG SHELLKIT_LOG_LEVEL SHELLKIT_LOG_FORMAT SHELLKIT_STATUS_MODE
export SHELLKIT_COLOR SK_COLOR_ON SHELLKIT_DEBUG

# SK_POSIX_LIB 指向别的副本（变异自证要用）；不设就是仓库里那份
_pp_posix_lib="${SK_POSIX_LIB:-$_pp_root/lib/posix/shellkit-posix.sh}"

if [ "$_pp_side" = "bash" ]; then
  # shellcheck disable=SC1090
  . "$_pp_root/lib/bootstrap.sh" || exit 1
else
  # shellcheck disable=SC1090
  . "$_pp_posix_lib" || exit 1
fi

_pp_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sk-parity.XXXXXX") || exit 1
trap 'rm -rf "$_pp_tmp"' 0 1 2 15

printf 'hello\n' >"$_pp_tmp/known"

# ---- 输出压成一行（换行 → '|'），便于逐行比对 ----
_pp_flat() {
  # 外部工具自己的诊断**不算**库的行为：sha256sum 的报错措辞各家不同
  # （GNU 说 "No such file or directory"，busybox 说 "can't open"）
  # ⇒ 过滤掉，只比库自己的输出与退出码。
  _pp_flat_v=$(grep -v -e '^sha256sum:' -e '^shasum:' "$1" 2>/dev/null | tr '\n' '|')
  case "$_pp_flat_v" in
    *'|') _pp_flat_v=${_pp_flat_v%|} ;;
  esac
  # 把本次运行的临时目录路径抹成 <TMP>：两次运行的路径不同，不抹就永远对不上
  printf '%s' "$_pp_flat_v" | sed "s|$_pp_tmp|<TMP>|g"
}

_pp_run() {
  _pp_name=$1
  # 每个用例用**自己的**输出文件：一个用例把临时目录删掉，不会连累后面的用例
  (eval "_pp_case_$_pp_name") >"$_pp_tmp/out.$_pp_name" 2>"$_pp_tmp/err.$_pp_name"
  _pp_rc=$?
  printf '%s\t%s\t%s\t%s\n' "$_pp_name" "$_pp_rc" \
    "$(_pp_flat "$_pp_tmp/out.$_pp_name")" "$(_pp_flat "$_pp_tmp/err.$_pp_name")"
}

# ================== 用例（全部按主库口径写） ==================

# ---- die / fail：主库是「先退出码，后消息」----
_pp_case_die_code() { die 3 "boom"; }
_pp_case_die_msg_only() { die "boom"; }
_pp_case_die_code_zero() { die 0 "bye"; }
_pp_case_fail_code() { fail 3 "boom"; }
_pp_case_fail_msg_only() { fail "boom"; }
_pp_case_fail_noargs() { fail; }

# ---- 日志：主库收**全部**参数；OK 的标签是 " OK "（带空格）----
_pp_case_log_info_multi() { log_info "a" "b"; }
_pp_case_log_ok() { log_ok "done"; }
_pp_case_log_warn() { log_warn "careful"; }
_pp_case_log_error() { log_error "bad"; }
_pp_case_log_error_errmsg() {
  log_error "bad"
  printf 'errmsg=%s\n' "${SK_ERRMSG:-<unset>}"
}
_pp_case_log_section() { log_section "Title"; }

# ---- status：人类/机器两种模式、转义、缺参 ----
_pp_case_status_emit_human() { status_emit running "Service is up"; }
_pp_case_status_emit_escape() { status_emit running 'a\nb'; }
_pp_case_status_emit_noargs() { status_emit; }
_pp_case_status_emit_machine() {
  SHELLKIT_STATUS_MODE=machine
  export SHELLKIT_STATUS_MODE
  status_emit running "x"
}
_pp_case_status_state_valid_ok() { status_state_valid installed; }
_pp_case_status_state_valid_bad() { status_state_valid bogus; }
_pp_case_status_version_machine() {
  SHELLKIT_STATUS_MODE=machine
  export SHELLKIT_STATUS_MODE
  status_version 1.2.3
}

# ---- 清理栈：登记的**命令与参数**必须完整 ----
_pp_case_trap_push_noargs() { trap_push; }
_pp_case_trap_push_args() {
  trap_push echo hello
  trap_install
}
_pp_case_trap_push_order() {
  trap_push "echo A"
  trap_push "echo B"
  trap_install
}

# ---- fs ----
_pp_case_fs_ensure_dir_noargs() { fs_ensure_dir; }
_pp_case_fs_ensure_dir_ok() { fs_ensure_dir "$_pp_tmp/d"; }

# ---- net ----
_pp_case_net_sha256_missing() { net_sha256 "$_pp_tmp/nope"; }
_pp_case_net_verify_empty() { net_verify "$_pp_tmp/known" ""; }
_pp_case_net_verify_missing() { net_verify "$_pp_tmp/nope" "deadbeef"; }

# ---- conf ----
_pp_case_conf_get_any_one_arg() { conf_get_any SK_PARITY_PROBE_KEY; }
_pp_case_conf_get_any_bad_key() { conf_get_any "bad-key" "dflt"; }

# ---- os / 前置检查：同名同义；id() 函数注入让 root 判定在任何机器上都可判 ----
# 为什么是函数不是 PATH 假 id（2026-11-22 CI 实证）：PATH 里的假 id 在
# busybox-static（applet 解析优先于 PATH）上被内置 id 盖掉 ⇒ busybox 腿
# 永远 notroot、sh 腿 root ⇒ 对拍必红。POSIX 命令解析顺序是
# 函数 → 内置/applet → PATH，函数在三处都赢；且 os_is_root 的
# $(id -u) 是命令替换（子 shell），子 shell 继承函数定义。
_pp_case_os_name_ok() { os_name; }
_pp_case_os_arch_ok() { os_arch; }
_pp_case_os_is_root_as_root() {
  id() { printf '0\n'; }
  if os_is_root; then printf 'root'; else printf 'notroot'; fi
}
_pp_case_os_is_root_as_user() {
  id() { printf '1000\n'; }
  if os_is_root; then printf 'root'; else printf 'notroot'; fi
}
_pp_case_os_has_cmd_present() { os_has_cmd sh; }
_pp_case_os_has_cmd_missing() { os_has_cmd shellkit-no-such-cmd-xyz; }
_pp_case_os_has_cmd_noargs() { os_has_cmd; }
_pp_case_require_cmd_present() { require_cmd sh; }
_pp_case_require_cmd_missing() { require_cmd shellkit-no-such-cmd-xyz; }
_pp_case_require_cmd_noargs() { require_cmd; }

for _pp_name in \
  die_code die_msg_only die_code_zero \
  fail_code fail_msg_only fail_noargs \
  log_info_multi log_ok log_warn log_error log_error_errmsg log_section \
  status_emit_human status_emit_escape status_emit_noargs status_emit_machine \
  status_state_valid_ok status_state_valid_bad status_version_machine \
  trap_push_noargs trap_push_args trap_push_order \
  fs_ensure_dir_noargs fs_ensure_dir_ok \
  net_sha256_missing net_verify_empty net_verify_missing \
  conf_get_any_one_arg conf_get_any_bad_key \
  os_name_ok os_arch_ok os_is_root_as_root os_is_root_as_user \
  os_has_cmd_present os_has_cmd_missing os_has_cmd_noargs \
  require_cmd_present require_cmd_missing require_cmd_noargs; do
  _pp_run "$_pp_name"
done
