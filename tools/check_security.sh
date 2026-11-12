#!/usr/bin/env bash
#
# 门禁：四条安全边界（路径 / 权限 / 敏感参数 / 执行隔离）的机器判据。
#
# 规范在 docs/SECURITY.md —— 那里写的是「要遵守什么」，这里守的是「能自动查的
# 那一半」。判据分两类：
#
#   行为判据  把库里的函数真的跑一遍，看它拦不拦得住违规输入。
#             改坏实现就红 ⇒ 判据有牙齿（自证见 tests/test_security.sh）。
#   结构判据  查源码里该出现的守卫 / 标记在不在（删掉守卫就红）。
#
# 用法：
#   bash tools/check_security.sh                     # 全查
#   bash tools/check_security.sh --only path.write   # 只查一条（自证用）
#   bash tools/check_security.sh --root /tmp/fake    # 在副本上查（不碰真实工作树）
#   bash tools/check_security.sh --list              # 列出判据
#
# 退出码：0 通过 / 1 有违规 / 2 用法错
set -u

ROOT_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${SHELLKIT_CHECK_ROOT:-$ROOT_DEFAULT}"
ONLY=""
LIST_ONLY=0

ALL_CHECKS="path.write path.symlink path.name perm.mode secret.redact secret.tracked exec.lock exec.trap exec.atomic exec.concurrent"

_usage() {
  printf 'usage: bash %s [--root DIR] [--only ID[,ID...]] [--list]\n' "${0##*/}"
}

_die_usage() {
  printf 'check_security: %s\n' "$1" >&2
  _usage >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      shift
      [ "$#" -gt 0 ] || _die_usage "--root needs a directory"
      ROOT="$1"
      ;;
    --root=*) ROOT="${1#*=}" ;;
    --only)
      shift
      [ "$#" -gt 0 ] || _die_usage "--only needs a list of check ids"
      ONLY="$1"
      ;;
    --only=*) ONLY="${1#*=}" ;;
    --list) LIST_ONLY=1 ;;
    -h | --help)
      _usage
      exit 0
      ;;
    *) _die_usage "unknown option: $1" ;;
  esac
  shift
done

if [ -n "$ONLY" ]; then
  for __id in ${ONLY//,/ }; do
    case " $ALL_CHECKS " in
      *" $__id "*) ;;
      *) _die_usage "unknown check id: $__id" ;;
    esac
  done
fi

if [ "$LIST_ONLY" -eq 1 ]; then
  printf 'path.write     结构  写原语（fs_atomic_write / fs_atomic_copy / fs_ensure_line /
'
  printf '                         fs_ensure_block）的调用点所在函数必须带路径边界守卫
'
  printf 'path.symlink   行为  不可信软链一律拒绝：_sk_fs_no_symlink_below / _sk_fs_rel_safe /
'
  printf '                         _sk_fs_in_dir 拦得住根外路径、.. 与软链目录
'
  printf 'path.name      行为  名字先过合法性校验：_sk_valid_name 拒绝 a/b 与 ..；
'
  printf '                         cmd_new / cmd_upgrade / cmd_demo 必须调用它
'
  printf 'perm.mode      行为  fs_atomic_write 新建 600；fs_atomic_copy 覆盖保留原权限、
'
  printf '                         新建跟随源的权限
'
  printf 'secret.redact  行为  run --secret-arg / --redact-value 真的遮住口令；
'
  printf '                         调用点传敏感变量时必须显式声明
'
  printf 'secret.tracked 结构  凭据文件（.env / *.pem / id_rsa …）不得进版本库
'
  printf 'exec.lock      行为  锁可回收：pid 文件缺失且过了宽限期就回收，活着的持有者不回收
'
  printf 'exec.trap      结构  调用了 trap_push 的文件必须调用 trap_install
'
  printf 'exec.atomic    行为  原子写走「临时文件 + rename」，且不写穿软链
'
  printf 'exec.concurrent 结构  run_concurrent 的每个实例输出各写各的文件
'
  printf '\n'
  _usage
  exit 0
fi

_fail() {
  # 违规明细一律走 stderr，stdout 只留给「通过」这一句
  printf 'check_security: %s: %s\n' "$1" "$2" >&2
}

_failed=0
_fail_check() {
  _failed=$((_failed + 1))
}

# _selected ID —— 这条判据要不要跑
_selected() {
  [ -n "$ONLY" ] || return 0
  case ",$ONLY," in
    *",$1,"*) return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------- 扫描范围
# 库 + CLI + 安装/修复脚本 + 模板里的 shell —— 会被 vendor 走、会被用户抄走的都在内。
_SCAN_FILES=()
_load_scan_files() {
  _SCAN_FILES=()
  local __f
  for __f in \
    "$ROOT"/lib/core/*.sh \
    "$ROOT"/lib/bootstrap.sh \
    "$ROOT"/shellkit \
    "$ROOT"/install.sh \
    "$ROOT"/repair.sh \
    "$ROOT"/templates/bin/* \
    "$ROOT"/templates/commands/*.sh \
    "$ROOT"/templates/lib/*.sh \
    "$ROOT"/templates/tests/*.sh; do
    [ -f "$__f" ] || continue
    _SCAN_FILES[${#_SCAN_FILES[@]}]="$__f"
  done
}

# ---------------------------------------------------------------- 小工具
# _func_body FILE NAME —— 函数体（不含函数头与结尾的 }）
#
# 本仓库的函数一律顶格定义、顶格收尾（缩进的是函数体），按行切是准的。
# 单行函数（_sk_install_dest() { ... }）不在本门禁的查询范围里。
_func_body() {
  sed -n "/^$2()/,/^}/p" "$1" | sed -e '1d' -e '$d'
}

# _lib MODULES —— 载入库（只在子 shell 里用）
_lib() {
  SHELLKIT_MODULES="$1" . "$ROOT/lib/bootstrap.sh"
}

# ---------------------------------------------------------------- path.write
# 写原语的调用点，所在函数必须带路径边界守卫。
#
# 例外（都是「边界由调用方保证」的写原语本身）：
#   fs_atomic_write / fs_atomic_copy / fs_ensure_line / fs_ensure_block
#       —— 这四个就是写原语，校验是调用方的责任
#   _sk_upgrade_journal_write
#       —— 目标是工程目录下的固定文件名（不是清单里的名字），根由 cmd_upgrade 先校验
_path_write_exempt() {
  case "$1" in
    fs_atomic_write | fs_atomic_copy | fs_ensure_line | fs_ensure_block) return 0 ;;
    _sk_upgrade_journal_write) return 0 ;;
  esac
  return 1
}

_PATH_WRITE_GUARDS="_sk_fs_in_dir|_sk_fs_rel_safe|_sk_fs_no_symlink_below|_sk_upgrade_rel_safe|_sk_upgrade_in_dir|_sk_valid_name|-L[[:space:]]"

# _write_call_funcs FILE —— 哪些函数里出现了写原语的调用
_write_call_funcs() {
  awk '
    /^[A-Za-z_][A-Za-z0-9_]*\(\)[ 	]*\{/ {
      fn = $0
      sub(/\(\).*/, "", fn)
      if ($0 ~ /}[ 	]*$/) { inf = 0 } else { inf = 1 }
      next
    }
    inf && /^}/ { inf = 0; next }
    inf {
      line = $0
      sub(/[ 	]*#.*$/, "", line)
      if (line ~ /(^|[ 	;()])(fs_atomic_write|fs_atomic_copy|fs_ensure_line|fs_ensure_block)[ 	]/) {
        print fn
      }
    }
  ' "$1" | sort -u
}

_check_path_write() {
  local __f __rel __fn __body
  for __f in "${_SCAN_FILES[@]+"${_SCAN_FILES[@]}"}"; do
    __rel="${__f#"$ROOT"/}"
    for __fn in $(_write_call_funcs "$__f"); do
      _path_write_exempt "$__fn" && continue
      __body=$(_func_body "$__f" "$__fn")
      [ -n "$__body" ] || continue
      if ! printf '%s\n' "$__body" | grep -Eq "$_PATH_WRITE_GUARDS"; then
        _fail "path.write" "$__rel: $__fn 写文件前没有路径边界守卫（_sk_fs_in_dir / _sk_fs_rel_safe / _sk_fs_no_symlink_below / _sk_upgrade_rel_safe / _sk_upgrade_in_dir / _sk_valid_name，或显式的 -L 拒绝）"
        _fail_check
      fi
    done
  done
}

# ---------------------------------------------------------------- path.symlink
# 不可信软链一律拒绝 —— 行为判据：真的建一个软链试试拦不拦得住。
_check_path_symlink() {
  (
    __rc=0
    _fail() {
      printf 'check_security: %s: %s\n' "$1" "$2" >&2
      __rc=1
    }
    _lib "log fs str i18n error trap" || exit 1
    __t=$(mktemp -d "${TMPDIR:-/tmp}/shellkit-sec.XXXXXX") || exit 1
    # 清理用 find -delete 而不是 rm -rf：有些机器上的 rm 是回收站包装器，
    # 一次 rm 要 1–9 秒（lib/core/trap.sh 里记过这个现象）。
    trap 'find "$__t" -depth -delete 2>/dev/null || true' EXIT
    mkdir -p "$__t/root/real"
    mkdir -p "$__t/outside"
    ln -s "$__t/outside" "$__t/root/link"
    __root=$(cd "$__t/root" && pwd -P)

    # 1. 根外的目标必须被拒
    if _sk_fs_in_dir "$__root" "$__t/outside/file"; then
      _fail "path.symlink" "_sk_fs_in_dir 放行了根外的目标"
    fi
    # 2. 根内的目标必须放行
    if ! _sk_fs_in_dir "$__root" "$__root/real/file"; then
      _fail "path.symlink" "_sk_fs_in_dir 误拒了根内的目标"
    fi
    # 3. .. 必须被拒
    if _sk_fs_rel_safe "../x"; then
      _fail "path.symlink" "_sk_fs_rel_safe 放行了带 .. 的相对路径"
    fi
    if _sk_fs_rel_safe "a/../../x"; then
      _fail "path.symlink" "_sk_fs_rel_safe 放行了带 .. 的相对路径"
    fi
    if ! _sk_fs_rel_safe "bin/x"; then
      _fail "path.symlink" "_sk_fs_rel_safe 误拒了正常的相对路径"
    fi
    # 4. 指向根内的软链也必须被拒 —— 不可信一律拒绝，不做「看起来安全就放行」
    if _sk_fs_no_symlink_below "$__root" "link"; then
      _fail "path.symlink" "_sk_fs_no_symlink_below 放行了软链目录"
    fi
    if ! _sk_fs_no_symlink_below "$__root" "real"; then
      _fail "path.symlink" "_sk_fs_no_symlink_below 误拒了真目录"
    fi
    exit "$__rc"
  ) || _fail_check
}

# ---------------------------------------------------------------- path.name
# 名字先过合法性校验：用户给的名字不许直接变成文件名。
_check_path_name() {
  local __fn __body
  for __fn in cmd_new cmd_upgrade cmd_demo; do
    __body=$(_func_body "$ROOT/shellkit" "$__fn")
    if [ -z "$__body" ]; then
      _fail "path.name" "shellkit: 找不到函数 $__fn"
      _fail_check
      continue
    fi
    if ! printf '%s\n' "$__body" | grep -q '_sk_valid_name'; then
      _fail "path.name" "shellkit: $__fn 没有调用 _sk_valid_name（用户给的名字必须先过合法性校验）"
      _fail_check
    fi
  done
  (
    __rc=0
    _fail() {
      printf 'check_security: %s: %s\n' "$1" "$2" >&2
      __rc=1
    }
    eval "$(sed -n '/^_sk_valid_name()/,/^}/p' "$ROOT/shellkit")"
    if _sk_valid_name "a/b"; then
      _fail "path.name" "_sk_valid_name 放行了带 / 的名字（a/b）"
    fi
    if _sk_valid_name ".."; then
      _fail "path.name" "_sk_valid_name 放行了 .."
    fi
    if ! _sk_valid_name "ok-name_1"; then
      _fail "path.name" "_sk_valid_name 误拒了正常名字（ok-name_1）"
    fi
    exit "$__rc"
  ) || _fail_check
}

# ---------------------------------------------------------------- perm.mode
# 新建文件默认 600；覆盖既有文件时权限按显式口径走（fs_atomic_copy 保留原权限）。
# _mode_of FILE —— 文件权限位（八进制）；取不到就返回非 0
#
# 直接用库里的 _sk_fs_mode，不在门禁里另写一套更弱的判断（两套实现必然漂移）。
# 教训见 CI run 43238779798：GNU 的 stat -f 是 --file-system，会吐出
# `File: "..."` 这种非权限内容；只要它退出码为 0，原来
# `stat -f ... || stat -c ...` 的兜底根本不触发，垃圾值被当成权限，
# perm.mode 在 Linux 上恒红。_sk_fs_mode 有内容校验：不是八进制就当没取到。
_mode_of() {
  _sk_fs_mode "$1"
}

_check_perm_mode() {
  (
    __rc=0
    _fail() {
      printf 'check_security: %s: %s\n' "$1" "$2" >&2
      __rc=1
    }
    _lib "log fs str i18n error trap" || exit 1
    __t=$(mktemp -d "${TMPDIR:-/tmp}/shellkit-sec.XXXXXX") || exit 1
    # 清理用 find -delete 而不是 rm -rf：有些机器上的 rm 是回收站包装器，
    # 一次 rm 要 1–9 秒（lib/core/trap.sh 里记过这个现象）。
    trap 'find "$__t" -depth -delete 2>/dev/null || true' EXIT

    # 1. 新建文件默认 600
    __f="$__t/new.txt"
    fs_atomic_write "$__f" "hello" || {
      _fail "perm.mode" "fs_atomic_write 写不进去"
      exit 1
    }
    __m=$(_mode_of "$__f")
    if [ "$__m" != "600" ]; then
      _fail "perm.mode" "fs_atomic_write 新建的文件权限是 ${__m}，应为 600"
    fi

    # 2. fs_atomic_copy 覆盖既有文件：保留原权限
    printf 'x\n' >"$__t/src"
    chmod 600 "$__t/src"
    printf 'y\n' >"$__t/dst"
    chmod 644 "$__t/dst"
    fs_atomic_copy "$__t/src" "$__t/dst" || {
      _fail "perm.mode" "fs_atomic_copy 写不进去"
      exit 1
    }
    __m=$(_mode_of "$__t/dst")
    if [ "$__m" != "644" ]; then
      _fail "perm.mode" "fs_atomic_copy 覆盖既有文件后权限变成 ${__m}，应保留 644"
    fi

    # 3. fs_atomic_copy 新建目标：跟随源的权限
    fs_atomic_copy "$__t/src" "$__t/dst2" || {
      _fail "perm.mode" "fs_atomic_copy 写不进去"
      exit 1
    }
    __m=$(_mode_of "$__t/dst2")
    if [ "$__m" != "600" ]; then
      _fail "perm.mode" "fs_atomic_copy 新建的文件权限是 ${__m}，应跟随源（600）"
    fi
    exit "$__rc"
  ) || _fail_check
}

# ---------------------------------------------------------------- secret.redact
# 命令行里的口令 / 令牌必须显式声明脱敏。
#
# 静态：调用点把敏感变量递给 run 时，必须声明 --secret-arg / --redact-value
#       （或用 SHELLKIT_SECRET_ARGS 统一声明）。
# 行为：声明了确实遮得住 —— 遮不住的话声明就是摆设。
#
# 位置敏感：只有当敏感变量**前面那个词**不是敏感选项名时才算违规 ——
#   run cmd --password "$PW"   的口令会被 run 的启发式遮掉（选项名本身就敏感）
#   run mysql -u root "$PW"    的口令遮不住（-u 遮的是它后面那个）
# 正则直接写在 awk 程序里：awk -v 会对赋值做转义，正则里的反斜杠会被吃掉。
_check_secret_redact() {
  local __f __rel __line
  for __f in "${_SCAN_FILES[@]+"${_SCAN_FILES[@]}"}"; do
    __rel="${__f#"$ROOT"/}"
    while IFS= read -r __line; do
      [ -n "$__line" ] || continue
      _fail "secret.redact" "$__rel: run 调用点把敏感变量递了出去却没有声明脱敏（--secret-arg / --redact-value / SHELLKIT_SECRET_ARGS）：$__line"
      _fail_check
    done <<EOF
$(awk '
  {
    line = $0
    sub(/[ \t]*#.*$/, "", line)
    low = tolower(line)
    if (low !~ /(^|[ \t;|(])run[ \t]/) next
    # 已经显式声明过脱敏的，整行放过
    if (low ~ /--secret-arg|--redact-value|shellkit_secret_args/) next
    n = split(line, tok, /[ \t]+/)
    prev = ""
    for (i = 1; i <= n; i++) {
      t = tok[i]
      if (t == "") continue
      tl = tolower(t)
      if (tl ~ /\$\{?[a-z_]*(password|passwd|passphrase|token|secret|api_?key|access_key|private_key|credential)/ && tolower(prev) !~ /^--[a-z-]*(password|passwd|passphrase|token|secret|api-?key|access-key|credential)$/) {
        print line
        break
      }
      prev = t
    }
  }
' "$__f" 2>/dev/null || true)
EOF
  done
  (
    __rc=0
    _fail() {
      printf 'check_security: %s: %s\n' "$1" "$2" >&2
      __rc=1
    }
    _lib "run error i18n log str trap" || exit 1
    __out=$(SHELLKIT_DRY_RUN=1 run --secret-arg 1 mycmd "s3cr3t-value" 2>&1)
    case "$__out" in
      *s3cr3t-value*)
        _fail "secret.redact" "run --secret-arg 1 没有遮住第 1 个参数"
        ;;
      *'***'*) ;;
      *)
        _fail "secret.redact" "run --secret-arg 1 没有把参数遮成 ***"
        ;;
    esac
    exit "$__rc"
  ) || _fail_check
}

# ---------------------------------------------------------------- secret.tracked
# 凭据文件不得进版本库。
_SECRET_FILE_RE='(^|/)(\.env(\.|$)|\.netrc$|\.htpasswd$|id_rsa|id_dsa|id_ecdsa|id_ed25519|[^/]*\.pem$|[^/]*\.key$|[^/]*\.p12$|[^/]*\.pfx$|[^/]*\.jks$|[^/]*\.keystore$|[^/]*\.secret$|credentials[^/]*$)'

_check_secret_tracked() {
  local __f
  if ! command -v git >/dev/null 2>&1; then
    _fail "secret.tracked" "找不到 git，这条判据查不了"
    _fail_check
    return
  fi
  if ! git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # 不是 git 仓库（自证用的副本可能没初始化）—— 查不了就明说，不当成通过
    printf 'check_security: secret.tracked: %s 不是 git 仓库，这条判据跳过了\n' "$ROOT" >&2
    return
  fi
  while IFS= read -r __f; do
    [ -n "$__f" ] || continue
    _fail "secret.tracked" "$__f 看着像凭据文件，却进了版本库"
    _fail_check
  done <<EOF
$(git -C "$ROOT" ls-files | grep -E "$_SECRET_FILE_RE" || true)
EOF
}

# ---------------------------------------------------------------- exec.lock
# 锁必须可回收：pid 文件缺失时不许永久不可用。
_check_exec_lock() {
  local __body
  __body=$(_func_body "$ROOT/lib/core/lock.sh" "_sk_lock_is_stale")
  if [ -z "$__body" ]; then
    _fail "exec.lock" "lib/core/lock.sh: 找不到 _sk_lock_is_stale"
    _fail_check
    return
  fi
  if ! printf '%s\n' "$__body" | grep -q 'SHELLKIT_LOCK_STALE'; then
    _fail "exec.lock" "lib/core/lock.sh: _sk_lock_is_stale 没有 SHELLKIT_LOCK_STALE 宽限逻辑（pid 文件缺失就会永久不可用）"
    _fail_check
  fi
  (
    __rc=0
    _fail() {
      printf 'check_security: %s: %s\n' "$1" "$2" >&2
      __rc=1
    }
    _lib "str i18n log" || exit 1
    eval "$(sed -n '/^_sk_lock_pid_alive()/,/^}/p' "$ROOT/lib/core/lock.sh")"
    eval "$(sed -n '/^_sk_lock_mtime()/,/^}/p' "$ROOT/lib/core/lock.sh")"
    eval "$(sed -n '/^_sk_lock_is_stale()/,/^}/p' "$ROOT/lib/core/lock.sh")"
    __t=$(mktemp -d "${TMPDIR:-/tmp}/shellkit-sec.XXXXXX") || exit 1
    # 清理用 find -delete 而不是 rm -rf：有些机器上的 rm 是回收站包装器，
    # 一次 rm 要 1–9 秒（lib/core/trap.sh 里记过这个现象）。
    trap 'find "$__t" -depth -delete 2>/dev/null || true' EXIT

    # 1. 目录在、pid 不在、且过了宽限期 —— 必须能回收
    mkdir -p "$__t/lock"
    touch -t 202001010000 "$__t/lock" 2>/dev/null || true
    if ! (
      export SHELLKIT_LOCK_STALE=1
      _sk_lock_is_stale "$__t/lock"
    ); then
      _fail "exec.lock" "pid 文件缺失的锁过了宽限期仍不可回收（永久不可用）"
    fi

    # 2. 持有者还活着 —— 绝不回收
    mkdir -p "$__t/live"
    printf '%s\n' "$$" >"$__t/live/pid"
    if (
      export SHELLKIT_LOCK_STALE=1
      _sk_lock_is_stale "$__t/live"
    ); then
      _fail "exec.lock" "持有者还活着的锁被判成僵锁（会把正在干活的进程的锁抢走）"
    fi

    # 3. 刚建的、还没写 pid —— 宽限期内不许回收
    mkdir -p "$__t/fresh"
    if (
      export SHELLKIT_LOCK_STALE=600
      _sk_lock_is_stale "$__t/fresh"
    ); then
      _fail "exec.lock" "宽限期内的锁被判成僵锁（mkdir 与写 pid 之间会被抢）"
    fi
    exit "$__rc"
  ) || _fail_check
}

# ---------------------------------------------------------------- exec.trap
# 注册了清理动作就必须真的装上 trap —— 否则退出时什么都不会收尾。
_check_exec_trap() {
  local __f __rel
  for __f in "${_SCAN_FILES[@]+"${_SCAN_FILES[@]}"}"; do
    __rel="${__f#"$ROOT"/}"
    grep -q 'trap_push' "$__f" 2>/dev/null || continue
    # 定义 trap_push 的那个文件不算「注册了却没安装」
    if ! grep -Eq '(^|[[:space:];(])trap_install([[:space:]]|$)' "$__f"; then
      _fail "exec.trap" "$__rel: 调用了 trap_push 却没有调用 trap_install（退出时不会收尾）"
      _fail_check
    fi
  done
}

# ---------------------------------------------------------------- exec.atomic
# 原子写走「临时文件 + rename」，而且不写穿软链（cp -f 会顺着软链写穿）。
_check_exec_atomic() {
  local __fn __body
  for __fn in fs_atomic_write fs_atomic_copy; do
    __body=$(_func_body "$ROOT/lib/core/fs.sh" "$__fn")
    if [ -z "$__body" ]; then
      _fail "exec.atomic" "lib/core/fs.sh: 找不到 $__fn"
      _fail_check
      continue
    fi
    if ! printf '%s\n' "$__body" | grep -q 'mktemp'; then
      _fail "exec.atomic" "lib/core/fs.sh: $__fn 没有落临时文件（写入被打断会留下半截文件）"
      _fail_check
    fi
    if ! printf '%s\n' "$__body" | grep -Eq 'mv -f'; then
      _fail "exec.atomic" "lib/core/fs.sh: $__fn 没有用 mv（rename）收尾（写成 cp -f 就会留下半截文件）"
      _fail_check
    fi
  done
  (
    __rc=0
    _fail() {
      printf 'check_security: %s: %s\n' "$1" "$2" >&2
      __rc=1
    }
    _lib "log fs str i18n error trap" || exit 1
    __t=$(mktemp -d "${TMPDIR:-/tmp}/shellkit-sec.XXXXXX") || exit 1
    # 清理用 find -delete 而不是 rm -rf：有些机器上的 rm 是回收站包装器，
    # 一次 rm 要 1–9 秒（lib/core/trap.sh 里记过这个现象）。
    trap 'find "$__t" -depth -delete 2>/dev/null || true' EXIT
    printf 'src\n' >"$__t/src"
    printf 'target\n' >"$__t/target"
    ln -s "$__t/target" "$__t/link"
    fs_atomic_copy "$__t/src" "$__t/link" || {
      _fail "exec.atomic" "fs_atomic_copy 写不进去"
      exit 1
    }
    # rename 换掉的是链接本身 —— 判据是「链接指向的文件没被动」，
    # 不是「链接还在」：链接被替换成新文件同样是正确行为（坑 8 的修法）。
    if ! grep -q 'target' "$__t/target"; then
      _fail "exec.atomic" "fs_atomic_copy 顺着软链写穿了（链接指向的文件内容被改了）"
    fi
    if [ ! -L "$__t/link" ] && ! grep -q 'src' "$__t/link"; then
      _fail "exec.atomic" "fs_atomic_copy 既没写穿软链，也没把内容落到链接的位置"
    fi
    exit "$__rc"
  ) || _fail_check
}

# ---------------------------------------------------------------- exec.concurrent
# 并发实例互相隔离：每个实例的 stdout / stderr 各写各的文件。
_check_exec_concurrent() {
  local __body
  __body=$(_func_body "$ROOT/lib/core/run.sh" "run_concurrent")
  if [ -z "$__body" ]; then
    _fail "exec.concurrent" "lib/core/run.sh: 找不到 run_concurrent"
    _fail_check
    return
  fi
  # 判据取「重定向」这个形状：__i}.out" 2> 只出现在每个实例各写各的文件那一行，
  # 读回结果的那几处（[ -s ... ] / done < ...）不带这个形状。
  if ! printf '%s\n' "$__body" | grep -Fq '__i}.out" 2>'; then
    _fail "exec.concurrent" "lib/core/run.sh: run_concurrent 没有把每个实例的 stdout / stderr 写进各自的文件"
    _fail_check
  fi
}

# ---------------------------------------------------------------- 主流程
_load_scan_files

[ -d "$ROOT/lib/core" ] || {
  printf 'check_security: %s/lib/core not found\n' "$ROOT" >&2
  exit 1
}

if [ "${#_SCAN_FILES[@]}" -eq 0 ]; then
  printf 'check_security: nothing was scanned under %s\n' "$ROOT" >&2
  exit 1
fi

_selected path.write && _check_path_write
_selected path.symlink && _check_path_symlink
_selected path.name && _check_path_name
_selected perm.mode && _check_perm_mode
_selected secret.redact && _check_secret_redact
_selected secret.tracked && _check_secret_tracked
_selected exec.lock && _check_exec_lock
_selected exec.trap && _check_exec_trap
_selected exec.atomic && _check_exec_atomic
_selected exec.concurrent && _check_exec_concurrent

if [ "$_failed" -ne 0 ]; then
  printf 'check_security: %s check(s) failed\n' "$_failed" >&2
  exit 1
fi
printf 'check_security: ok (%s files)\n' "${#_SCAN_FILES[@]}"
exit 0
