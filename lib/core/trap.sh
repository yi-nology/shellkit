#!/usr/bin/env bash
#
# 清理栈：让「失败也要收尾」不必每次都重新想一遍。
#
#   trap_push 'rm -rf "$workdir"'
#   trap_push 'lock_release deploy'
#   trap_install
#
# 注册不等于安装 —— 只有 trap_install 才真正改变调用方的信号行为。
# 这是刻意的：库被 source 时不该悄悄接管别人的 trap。

_SK_TRAP_CMDS=()
# _SK_TRAP_LVL 与 _SK_TRAP_CMDS 平行：每条动作是「在哪一层 shell 注册的」。
# 清理栈是普通数组 ⇒ fork 出来的子 shell 会**继承**一份副本 ⇒ 不标归属的话，
# 子 shell 退出时会把**父进程**的清理动作也跑一遍 ⇒ 替父进程收尾
# （父进程还在跑，它的临时目录已经被删了 ⇒ 后续写文件 "No such file or directory"）。
_SK_TRAP_LVL=()
# _SK_TRAP_SELF_LVL —— **本 shell 实例**属于哪一层（0 = 顶层）。
#
# 为什么不能在使用时现读 BASH_SUBSHELL：**bash 3.2 的陷阱** ——
# 当 EXIT trap 的处理器是一个**函数**时，bash 3.2 执行它的时候会把
# BASH_SUBSHELL 复位成 0（字符串型处理器则仍是 1；bash 5 两者都是 1）。
# ⇒ 在处理器里现读 BASH_SUBSHELL，会把「子 shell」误判成「顶层」
# ⇒ 归属判定全错 ⇒ 子 shell 又替父进程收尾（实测：只按层级过滤仍复现）。
# ⇒ 层级一律在**正常执行路径**上取（那一刻 BASH_SUBSHELL 是准的），
#   取完存进这里；处理器里只用这个存下来的值。
_SK_TRAP_SELF_LVL=${BASH_SUBSHELL:-0}
_SK_TRAP_N=0
_SK_TRAP_RUNNING=0
_SK_TRAP_INSTALLED=0
_SK_TRAP_HAD_EXIT=0
_SK_TRAP_SAVED_EXIT=""
# _SK_TRAP_SAVED_EXIT_LVL —— 这份调用方 EXIT handler 是在哪一层捕获的。
# 同样是普通变量 ⇒ 子 shell 会继承 ⇒ 不标归属的话，子 shell 退出时
# 照样替父进程执行它（这是「替父进程收尾」的第一层）。
_SK_TRAP_SAVED_EXIT_LVL=""
_SK_TRAP_SAVED_INT=""
_SK_TRAP_SAVED_TERM=""
_SK_TRAP_SAVED_HUP=""

# _sk_trap_claim —— 认领「本 shell 实例属于哪一层」
#
# 只能在**正常执行路径**上调用（处理器里 BASH_SUBSHELL 已被 bash 3.2 复位）。
_sk_trap_claim() {
  _SK_TRAP_SELF_LVL=${BASH_SUBSHELL:-0}
  return 0
}

# trap_push CMD... —— 注册一个清理动作；后注册的先执行
# @exitcode 0 压栈成功
# @exitcode 2 没给命令
# @stability stable
trap_push() {
  if [ "$#" -eq 0 ]; then
    log_error "$(_t 'trap_push requires a command')"
    return "$SK_USAGE"
  fi
  _sk_trap_claim
  _SK_TRAP_CMDS[$_SK_TRAP_N]="$*"
  _SK_TRAP_LVL[$_SK_TRAP_N]=$_SK_TRAP_SELF_LVL
  _SK_TRAP_N=$((_SK_TRAP_N + 1))
  return 0
}

# trap_pop —— 丢弃最近注册的一个动作（不执行）
# @exitcode 0 弹栈成功（或栈本来就是空的）
# @stability experimental
trap_pop() {
  if [ "$_SK_TRAP_N" -gt 0 ]; then
    _SK_TRAP_N=$((_SK_TRAP_N - 1))
    _SK_TRAP_CMDS[$_SK_TRAP_N]=""
    _SK_TRAP_LVL[$_SK_TRAP_N]=""
  fi
  return 0
}

# trap_list —— 逐行输出已注册的动作（调试用）
# @exitcode 0 总是成功（stdout 逐行输出栈里的命令）
# @stability experimental
trap_list() {
  local __i=0
  while [ "$__i" -lt "$_SK_TRAP_N" ]; do
    printf '%d %s\n' "$__i" "${_SK_TRAP_CMDS[$__i]}"
    __i=$((__i + 1))
  done
  return 0
}

# trap_cleanup —— 逆序执行全部清理动作；幂等；单个失败不中断其余
# @exitcode 0 清理完成（单个清理失败不中断其余）
# @stability experimental
trap_cleanup() {
  local __i __cmd __ent __lvl
  if [ "${_SK_TRAP_RUNNING:-0}" = "1" ]; then
    return 0
  fi
  _SK_TRAP_RUNNING=1

  # 只清理**本层**注册的动作：继承来的那份属于父进程 ⇒ 跑它就是替父进程收尾。
  # 用**存下来的**层级（_SK_TRAP_SELF_LVL），不现读 BASH_SUBSHELL ——
  # 本函数跑在 trap 处理器里，而 bash 3.2 会在那里把 BASH_SUBSHELL 复位成 0。
  # 归属标记缺省按 0 算 ⇒ 子 shell（层级 ≥1）绝不会把没标记的继承条目当成自己的。
  # ⚠ 已知边界：在子 shell 里**手调** trap_cleanup（不经 trap_install）时，
  #   本 shell 没认领过层级 ⇒ 仍按继承来的层级算 ⇒ 父进程登记的条目会被执行。
  #   库自己的路径都是先 trap_install（⇒ 已认领）⇒ 不受影响。
  __lvl=$_SK_TRAP_SELF_LVL
  __i=$_SK_TRAP_N
  while [ "$__i" -gt 0 ]; do
    __i=$((__i - 1))
    __cmd=${_SK_TRAP_CMDS[$__i]}
    __ent=${_SK_TRAP_LVL[$__i]:-0}
    _SK_TRAP_CMDS[$__i]=""
    _SK_TRAP_LVL[$__i]=""
    if [ -n "$__cmd" ] && [ "$__ent" = "$__lvl" ]; then
      if ! eval "$__cmd"; then
        log_warn "$(_t 'cleanup step failed'): $__cmd"
      fi
    fi
  done
  _SK_TRAP_N=0

  # 调用方原有的 EXIT trap 放在最后跑，保证它看到的是已收尾的状态。
  # 但只在**本层捕获**的那份才跑：继承来的那份属于父进程 ⇒ 跑了就是替父进程收尾。
  if [ "${_SK_TRAP_HAD_EXIT:-0}" = "1" ] && [ -n "${_SK_TRAP_SAVED_EXIT:-}" ] &&
    [ "${_SK_TRAP_SAVED_EXIT_LVL:-0}" = "$__lvl" ]; then
    __cmd=$_SK_TRAP_SAVED_EXIT
    _SK_TRAP_SAVED_EXIT=""
    _SK_TRAP_HAD_EXIT=0
    if ! eval "$__cmd"; then
      log_warn "$(_t 'cleanup step failed'): $__cmd"
    fi
  fi

  _SK_TRAP_RUNNING=0
  return 0
}

# _sk_trap_has CMD —— 栈里是否已有这个动作
#
# 只看**本层**登记的：父进程登记过的那份**不算数**。
# 为什么：子 shell 必须登记自己的那一份 —— 否则它退出时，
# 「父进程那份」属于父进程（不执行），「自己那份」又没登记
# ⇒ 子 shell 里拿到的锁不会被释放（实测：子 shell 退出后锁目录还在）。
# 父进程那份仍由父进程在退出时执行 ⇒ 互斥不受影响。
_sk_trap_has() {
  local __want=$1 __i=0 __lvl
  _sk_trap_claim
  __lvl=$_SK_TRAP_SELF_LVL
  while [ "$__i" -lt "$_SK_TRAP_N" ]; do
    if [ "${_SK_TRAP_LVL[$__i]:-0}" = "$__lvl" ] &&
      [ "${_SK_TRAP_CMDS[$__i]}" = "$__want" ]; then
      return 0
    fi
    __i=$((__i + 1))
  done
  return 1
}

# 读 trap 定义这件事的两条硬约束：
#
#   1) 必须在当前 shell 里执行 trap -p —— 不能用 $(trap -p ...)：命令替换在子
#      shell 里跑，而子 shell 会把已捕获的 trap 重置为默认，于是永远读到空。
#      所以只能重定向到文件再读回来。
#   2) 整个过程只能删一次文件 —— trap_install 要看 4 个信号（EXIT/INT/TERM/HUP），
#      以前每个信号读两遍（先判断「是不是我们自己装的处理器」，再取调用方原来的
#      handler），每读一遍新建+删除一个临时文件就是 8 次 rm。在 rm 走回收站包装器、
#      审计钩子或网络文件系统的机器上，一次 rm 要 1–9 秒 —— 光「装一次 trap」就
#      白扔几秒，而这是每个脚本启动都要付的钱（实测本机 10 秒）。
#
# 现在：trap -p 一次读完所有信号，临时文件只建一个、只删一次，读文件用 read 内建
# （不 fork cat）。信号名的写法在 bash 3.2 与 5.x 一致：EXIT 写 EXIT，其余写
# SIGINT / SIGTERM / SIGHUP。
_SK_TRAP_CUR=""
_SK_TRAP_FILE=""
_SK_TRAP_LINES=()

# _sk_trap_read_all —— 把当前 shell 里所有 trap 定义读进 _SK_TRAP_LINES
_sk_trap_read_all() {
  local __f __line
  _SK_TRAP_LINES=()
  if [ -z "$_SK_TRAP_FILE" ]; then
    __f=$(mktemp "${TMPDIR:-/tmp}/.shellkit-trap.XXXXXX") || return 1
    _SK_TRAP_FILE=$__f
  fi
  __f=$_SK_TRAP_FILE
  if ! trap -p >"$__f" 2>/dev/null; then
    return 1
  fi
  while IFS= read -r __line || [ -n "$__line" ]; do
    [ -n "$__line" ] || continue
    _SK_TRAP_LINES[${#_SK_TRAP_LINES[@]}]="$__line"
  done <"$__f"
  return 0
}

# _sk_trap_find SIG —— 找出该信号对应的 trap 行，放进 _SK_TRAP_CUR；没有就返回 1
_sk_trap_find() {
  local __sig=$1 __line
  _SK_TRAP_CUR=""
  for __line in ${_SK_TRAP_LINES[@]+"${_SK_TRAP_LINES[@]}"}; do
    case "$__line" in
      *" SIG$__sig" | *" $__sig")
        _SK_TRAP_CUR=$__line
        return 0
        ;;
    esac
  done
  return 1
}

# _sk_trap_read_done —— 读完了，把临时文件删掉（整个 trap_install 只删一次）
_sk_trap_read_done() {
  if [ -n "$_SK_TRAP_FILE" ]; then
    rm -f "$_SK_TRAP_FILE"
    _SK_TRAP_FILE=""
  fi
  return 0
}

# _sk_trap_slot SIG —— 该信号的保存位变量名
_sk_trap_slot() {
  case "${1:-}" in
    EXIT) printf '_SK_TRAP_SAVED_EXIT' ;;
    INT) printf '_SK_TRAP_SAVED_INT' ;;
    TERM) printf '_SK_TRAP_SAVED_TERM' ;;
    HUP) printf '_SK_TRAP_SAVED_HUP' ;;
    *) return 1 ;;
  esac
}

# _sk_trap_capture SIG —— 把调用方已有的同名 trap 存下来，稍后链式执行
_sk_trap_capture() {
  local __sig=$1 __slot __line __cmd
  __slot=$(_sk_trap_slot "$__sig") || return 0
  _sk_trap_find "$__sig" || return 0
  __line=$_SK_TRAP_CUR
  case "$__line" in
    "trap -- "*) ;;
    *) return 0 ;;
  esac
  __cmd=${__line#trap -- }
  # trap -p 的尾部是信号名：EXIT 写 EXIT，其余写 SIGINT / SIGTERM / SIGHUP
  case "$__cmd" in
    *" SIG$__sig") __cmd=${__cmd%" SIG$__sig"} ;;
    *" $__sig") __cmd=${__cmd%" $__sig"} ;;
    *) return 0 ;;
  esac
  case "$__cmd" in
    \'*\') ;;
    *) return 0 ;;
  esac
  __cmd=${__cmd#\'}
  __cmd=${__cmd%\'}
  if [ -z "$__cmd" ]; then
    return 0
  fi
  printf -v "$__slot" '%s' "$__cmd"
  if [ "$__sig" = "EXIT" ]; then
    _SK_TRAP_HAD_EXIT=1
    _SK_TRAP_SAVED_EXIT_LVL=$_SK_TRAP_SELF_LVL
  fi
  log_debug "chaining existing trap for $__sig"
  return 0
}

# _sk_trap_run_sig SIG —— 执行该信号保存的调用方 handler（跑过即清空，避免重复）
_sk_trap_run_sig() {
  local __slot __cmd
  __slot=$(_sk_trap_slot "${1:-}") || return 0
  eval "__cmd=\${$__slot:-}"
  if [ -z "$__cmd" ]; then
    return 0
  fi
  printf -v "$__slot" '%s' ""
  if ! eval "$__cmd"; then
    log_warn "$(_t 'cleanup step failed'): $__cmd"
  fi
  return 0
}

_sk_trap_on_exit() {
  local __st=$?
  trap - EXIT INT TERM HUP
  trap_cleanup
  exit "$__st"
}

_sk_trap_on_int() {
  trap - EXIT INT TERM HUP
  trap_cleanup
  _sk_trap_run_sig INT
  exit 130
}

_sk_trap_on_term() {
  trap - EXIT INT TERM HUP
  trap_cleanup
  _sk_trap_run_sig TERM
  exit 143
}

_sk_trap_on_hup() {
  trap - EXIT INT TERM HUP
  trap_cleanup
  _sk_trap_run_sig HUP
  exit 129
}

# _sk_trap_in_subshell —— 当前是不是在子 shell 里
#
# 为什么需要：子 shell 里 trap_install 若把**调用方**的 EXIT handler 链进来，
# 子 shell 退出时就会替调用方执行它 ⇒ 调用方的清理（删临时目录、释放锁）
# 在父进程还在跑的时候就先发生了一次。
#
# 现场：调用方 `trap 'rm -rf "$work"' EXIT`，随后在**命令替换**里调了任何会走到
# trap_install 的函数（lock_acquire / fs_tmp_init / proc_*）⇒ 子 shell 退出时把
# 调用方的 work 目录删了 ⇒ 父进程后续写文件直接 "No such file or directory"。
#
# 为什么 bash 自己没事、库里才有事：bash **不会**执行继承来的 EXIT trap
# （两个版本都是）—— 是库里把 handler 捕获下来再 eval，等于替 bash 执行了它。
# 而捕获能不能发生，取决于子 shell 里 `trap -p` 读到什么（两版 bash 实测）：
#   命令替换 $( )：3.2 与 5 都读到完整形态（"trap -- '...' EXIT"）⇒ 都会捕获
#   括号子 shell ( )：3.2 读到**空**（不捕获）、5 读到完整形态（捕获）
# ⇒ 命令替换这种最常见的写法，**两个版本都会中招**。
#
# 怎么判「在子 shell 里」：BASH_SUBSHELL（bash 3.2 就有：顶层 0，子 shell /
# 命令替换 ≥1）⇒ 跨版本可用；BASHPID 作兜底。
# ⚠⚠ 别只用 BASHPID：它**只有 bash 4+ 才有** ⇒ 在 bash 3.2 上 ${BASHPID:-}
# 是空 ⇒ 判定静默失效（判成「不在子 shell」）⇒ 守卫形同虚设
# ⇒ 表现是「本机（bash 5）绿、macOS CI（bash 3.2）红」。
# ⚠ 也别用 $$：它在子 shell 里**不变**（永远是顶层那个 shell 的 pid），判不出来。
_sk_trap_in_subshell() {
  case "${BASH_SUBSHELL:-0}" in
    0) ;;
    *) return 0 ;;
  esac
  case "${BASHPID:-}" in
    '' | "$$") return 1 ;;
  esac
  return 0
}

# trap_install —— 安装 EXIT / INT / TERM / HUP 处理器；可重复调用
#
# 幂等性不能用标志位：子 shell 会继承变量，却不会继承「会执行」的 trap，
# 于是「以为装过了、其实没装」，退出时清理不执行。
#
# 也不能只靠「当前 shell 里有没有这个 trap」判断 —— bash 5 起，子 shell 里
# `trap -p EXIT` 仍会显示父 shell 设的 trap（实测 5.3：看得见、但子 shell 退出时
# 不执行），而 bash 3.2 显示为空。只查 trap -p 会在 bash 5 的子 shell 里静默漏装，
# 表现为「( ... ) 里的 lock_acquire 拿到锁却没在退出时释放」。
# 所以：我们自己装的 trap（含子 shell 里的残影）一律重装一遍（重装同处理器无害），
# 并且绝不把它当成「调用方原有的 handler」捕获下来，否则清理时会自噬。
# @exitcode 0 装好了（链式保留调用方已有的 EXIT trap，幂等）
# @stability stable
trap_install() {
  local __sig
  # 认领层级：只能在正常执行路径上取（处理器里 bash 3.2 会复位 BASH_SUBSHELL）
  _sk_trap_claim
  # 子 shell 里**绝不**替父进程收尾。两层都要堵：
  #   1) 不**捕获**调用方的 EXIT handler（捕获了就等于替父进程执行它）；
  #   2) 清掉**继承来**的那一份（_SK_TRAP_SAVED_EXIT / _SK_TRAP_HAD_EXIT 都是
  #      普通变量 ⇒ 子 shell 会继承 ⇒ 只「不捕获」堵不住）：
  #      父进程自己装过一次 trap_install 时，子 shell 里 `trap -p` 读到的是
  #      **库自己的**处理器 ⇒ 走不到捕获分支 ⇒ 继承来的那份原样留着
  #      ⇒ 子 shell 退出时照样替父进程收尾（实测：只加守卫仍复现）。
  # 清掉的是子 shell 自己那份副本 ⇒ 父进程那份不受影响，父进程退出时照常执行。
  if _sk_trap_in_subshell; then
    _SK_TRAP_SAVED_EXIT=""
    _SK_TRAP_SAVED_EXIT_LVL=""
    _SK_TRAP_HAD_EXIT=0
    _SK_TRAP_SAVED_INT=""
    _SK_TRAP_SAVED_TERM=""
    _SK_TRAP_SAVED_HUP=""
  fi
  # 一次读完所有信号：以前是每个信号读两遍，8 轮 mktemp + rm。
  _sk_trap_read_all || return 0
  for __sig in EXIT INT TERM HUP; do
    _sk_trap_find "$__sig" || continue
    case "${_SK_TRAP_CUR:-}" in
      # 自己的处理器（含子 shell 残影）不算调用方的 handler，否则清理会自噬
      *_sk_trap_on_*) ;;
      *)
        # 子 shell 里不链调用方的 EXIT handler（理由见 _sk_trap_in_subshell）
        if [ "$__sig" = "EXIT" ] && _sk_trap_in_subshell; then
          continue
        fi
        _sk_trap_capture "$__sig"
        ;;
    esac
  done
  _sk_trap_read_done
  trap '_sk_trap_on_exit' EXIT
  trap '_sk_trap_on_int' INT
  trap '_sk_trap_on_term' TERM
  trap '_sk_trap_on_hup' HUP
  return 0
}
