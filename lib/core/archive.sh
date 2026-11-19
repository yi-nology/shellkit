#!/usr/bin/env bash
#
# 归档解包。tar / zip 的正确姿势固化在库里，不散落在各项目里。
#
# 为什么要有这一层（证据：真实运维工程里同一段代码手写了十几遍）：
#
#   1. **解压路径穿越**：tar 里的成员名可以是 `../../etc/passwd` 或 `/etc/passwd`。
#      直接 `tar -xzf` 会把文件写到目标目录之外 —— 而且**退出码是 0**，
#      日志里看不出来。这是真实存在的攻击面（解不可信归档）。
#   2. **软链逃逸**：归档里可以放一个指向目标目录之外的软链，再放一个经由它的
#      成员文件 ⇒ 同样写到目录外。
#   3. **管道半截**：`curl ... | tar -xz` 里 curl 中途失败时 tar 收到的是
#      **残缺的输入**，tar 可能报「unexpected EOF」，也可能**解压出一半**。
#      先落盘、校验通过再解，才是对的顺序。
#   4. **判据不一致**：一份工程解包后检查目标文件存在就当成功，另一份检查条数
#      —— 同一批包在不同工程里表现不一样。
#
# 这里的做法：先在**临时目录**里解，验完再搬到目标目录；
# 每个成员路径都过穿越与软链检查；不信任归档里的任何路径。

# _sk_archive_kind FILE —— 打印归档类型：tar | tgz | tbz2 | txz | zip
#
# 不靠扩展名判（扩展名是归档作者写的，不是事实）；按**魔数**判：
# gzip 是 `1f8b`、bzip2 是 `425a68`、xz 是 `fd377a5858`、zip 是 `504b0304`；
# tar 家族是第 257 字节起的 `ustar`。
_sk_archive_kind() {
  local __f=${1:-} __magic=""
  [ -f "$__f" ] || return 1
  __magic=$(od -An -tx1 -N6 "$__f" 2>/dev/null | tr -d ' \n')
  case "$__magic" in
    1f8b*) printf 'tgz'; return 0 ;;
    425a68*) printf 'tbz2'; return 0 ;;
    fd377a5858*) printf 'txz'; return 0 ;;
    504b0304*) printf 'zip'; return 0 ;;
  esac
  # tar：第 257 字节起是 "ustar"。用 dd 只读那一段，不整文件读进来。
  if [ "$(dd if="$__f" bs=1 skip=257 count=5 2>/dev/null)" = "ustar" ]; then
    printf 'tar'
    return 0
  fi
  return 1
}

# _sk_archive_members FILE KIND OUTFILE —— 把成员清单写进 OUTFILE
#
# 只用**列表**操作读成员名，不解压 —— 列表不写盘。
# zip 用 `unzip -Z1`，tar 家族用 `tar -tf`（tar 自己认压缩格式）。
#
# 清单落盘而不是走命令替换：命令替换会把尾随换行吃掉，也会让含空格的
# 文件名在后续分词里散架。落盘后逐行读，名字原样保留。
_sk_archive_members() {
  local __f=${1:-} __kind=${2:-} __out=${3:-}
  case "$__kind" in
    zip)
      command -v unzip >/dev/null 2>&1 || return 1
      unzip -Z1 "$__f" >"$__out" 2>/dev/null || return 1
      ;;
    *)
      command -v tar >/dev/null 2>&1 || return 1
      tar -tf "$__f" >"$__out" 2>/dev/null || return 1
      ;;
  esac
  [ -s "$__out" ] || return 1
  return 0
}

# _sk_archive_symlink_targets FILE KIND OUTFILE —— 列出归档里软链成员的目标
#
# 从 `tar -tvf` 的输出里取：软链行以 `l` 开头，目标在 ` -> ` 之后。
# 这个格式在 GNU tar 与 bsdtar 上都是稳定的（POSIX 之外的惯例，但两家一致）。
#
# 为什么要在**解之前**看软链：tar 自己对「经由软链写文件」的处置在实现之间
# 不一致 —— GNU tar 与 bsdtar 会拒绝（`Cannot extract through symlink`），
# 但那是它们的实现细节，不是契约。库里自己先看出来，才不依赖对方的行为。
# zip 存软链的方式各工具不一（多数当普通文件），这一层不覆盖；
# zip 由解完之后的实际文件系统扫描兜底。
_sk_archive_symlink_targets() {
  local __f=${1:-} __kind=${2:-} __out=${3:-}
  case "$__kind" in
    zip) return 1 ;;
    *)
      command -v tar >/dev/null 2>&1 || return 1
      tar -tvf "$__f" 2>/dev/null | sed -n 's/^l.* -> //p' >"$__out" || return 1
      ;;
  esac
  return 0
}

# _sk_archive_member_safe REL —— 成员相对路径是否安全（能解到目标目录之内）
#
# 拒绝：
#   - 绝对路径（`/etc/passwd`）
#   - 含 `..` 的路径（`../x`、`a/../../x`）
#   - 末尾就是 `..`（`a/..` 解出来是目标目录本身）
#   - 空路径
#
# 与 fs 模块的 `_sk_fs_rel_safe` 同口径，但这里额外拒掉末尾的 `..`：
# `a/..` 不含 `/../` 子串，可它解出来就是目标目录本身。
_sk_archive_member_safe() {
  local __rel=${1:-}
  case "$__rel" in
    '' | /*) return 1 ;;
    .. | */..) return 1 ;;
  esac
  case "/$__rel/" in
    */../*) return 1 ;;
  esac
  return 0
}

# _sk_archive_target_safe TARGET —— 软链目标是否安全（不指向归档之外）
#
# 保守判定：绝对目标一律拒绝；含 `..` 的相对目标一律拒绝。
# 理由：软链的指向要在**解出来的实际文件系统**上才能算准，而归档作者
# 完全可以造一个「相对但穿越」的目标（`../../etc`）。宁可多拒一个
# 合法包，也不放一个能写到外面的链接。
_sk_archive_target_safe() {
  local __t=${1:-}
  case "$__t" in
    '' | /*) return 1 ;;
    .. | */..) return 1 ;;
  esac
  case "/$__t/" in
    */../*) return 1 ;;
  esac
  return 0
}

# archive_list ARCHIVE —— 打印归档里的成员清单（相对路径，每行一个）
#
# 只读不解：不写盘、不建目录。用来「先看看包里有什么」再决定解不解。
# @exitcode 0 列出成功
# @exitcode 2 参数错
# @exitcode 3 归档不存在、格式认不出，或缺 tar/unzip
# @stability experimental
archive_list() {
  local __f=${1:-} __kind __tmp
  _sk_need_args "$#" 1 "archive_list ARCHIVE" || return $?
  if [ ! -f "$__f" ]; then
    log_error "$(_t 'archive not found'): $__f"
    return "$SK_PRECOND"
  fi
  __kind=$(_sk_archive_kind "$__f") || {
    log_error "$(_t 'cannot recognize the archive format'): $__f"
    return "$SK_PRECOND"
  }
  __tmp=$(mktemp "${TMPDIR:-/tmp}/shellkit-archive-list.XXXXXX") || {
    log_error "$(_t 'cannot create a temporary file')"
    return 1
  }
  if ! _sk_archive_members "$__f" "$__kind" "$__tmp"; then
    rm -f "$__tmp"
    log_error "$(_t 'cannot list the archive'): $__f"
    return "$SK_PRECOND"
  fi
  cat "$__tmp"
  rm -f "$__tmp"
  return 0
}

# archive_extract ARCHIVE DEST [EXPECTED_SHA256] —— 安全解包
#
# 解到 DEST（不存在就建）。流程：
#
#   1. 校验魔数，认出格式；
#   2. 可选：先核对 sha256（给了就必须对上，对不上一个字节都不解）；
#   3. 查成员名的路径穿越 —— 归档里带穿越路径时**连解都不解**；
#   4. 查归档里的软链目标 —— 指向外面的软链**连解都不解**；
#   5. 解到**临时目录**（不是直接解到 DEST）——
#      失败时 DEST 一个字节都不变，不会留半个包；
#   6. 扫解出来的文件系统，软链兜底再查一遍；
#   7. 全通过才搬进 DEST。
#
# 为什么先解到临时目录：tar 解到一半失败（磁盘满、成员损坏）时，
# 直接解到目标目录会留下**半份内容** —— 而调用方看到的是「目录存在了」。
# 半份内容比没有更危险：脚本会接着往下跑，读到截断的二进制。
#
# 为什么软链查两遍：第 4 遍查的是**清单里声明的**软链（解之前）；
# 第 6 遍查的是**实际落地的**软链（解之后，兜住清单说不清的情况）。
# 顺序必须是「解 → 查 → 搬」：先搬后查，穿越就已经发生了。
#
# 临时清单文件刻意放在临时目录**之外** —— 否则搬内容时会被一起搬进目标目录。
#
# @exitcode 0 解包成功
# @exitcode 2 参数错
# @exitcode 3 归档不存在、格式认不出，或缺 tar/unzip
# @exitcode 5 校验和不匹配，或归档里有不安全路径 / 软链，或解包失败
# @stability experimental
archive_extract() {
  local __f=${1:-} __dest=${2:-} __expect=${3:-} __kind __work __meta __rc=0
  local __list __targets __rel __bad="" __link __target __base
  _sk_need_args "$#" 2 "archive_extract ARCHIVE DEST [SHA256]" || return $?

  if [ ! -f "$__f" ]; then
    log_error "$(_t 'archive not found'): $__f"
    return "$SK_PRECOND"
  fi

  # 校验先于解包：对不上就一个字节都不解
  if [ -n "$__expect" ]; then
    if ! net_verify "$__f" "$__expect" >/dev/null 2>&1; then
      log_error "$(_t 'the checksum does not match'): $__f"
      return "$SK_VERIFY"
    fi
  fi

  __kind=$(_sk_archive_kind "$__f") || {
    log_error "$(_t 'cannot recognize the archive format'): $__f"
    return "$SK_PRECOND"
  }

  __work=$(mktemp -d "${TMPDIR:-/tmp}/shellkit-extract.XXXXXX") || {
    log_error "$(_t 'cannot create a temporary directory')"
    return 1
  }
  # 清单文件放在工作目录之外：搬内容时不能被一起搬走。
  __meta=$(mktemp -d "${TMPDIR:-/tmp}/shellkit-archive-meta.XXXXXX") || {
    rm -rf "$__work"
    log_error "$(_t 'cannot create a temporary directory')"
    return 1
  }
  __list="$__meta/members"
  __targets="$__meta/targets"

  # 第一遍：查成员名的路径穿越（在解之前 —— 有穿越就不解）
  if ! _sk_archive_members "$__f" "$__kind" "$__list"; then
    rm -rf "$__work" "$__meta"
    log_error "$(_t 'cannot list the archive'): $__f"
    return "$SK_PRECOND"
  fi
  while IFS= read -r __rel; do
    [ -n "$__rel" ] || continue
    # 目录成员通常以 / 结尾，去掉再判
    __rel=${__rel%/}
    [ -n "$__rel" ] || continue
    if ! _sk_archive_member_safe "$__rel"; then
      __bad="$__bad $__rel"
    fi
  done <"$__list"
  if [ -n "$__bad" ]; then
    rm -rf "$__work" "$__meta"
    log_error "$(_t 'the archive contains unsafe paths and was not extracted'): $__f"
    for __rel in $__bad; do
      log_error "  $__rel"
    done
    return "$SK_VERIFY"
  fi

  # 第二遍：查归档里声明的软链目标（仍在解之前）
  _sk_archive_symlink_targets "$__f" "$__kind" "$__targets" 2>/dev/null || true
  if [ -s "$__targets" ]; then
    while IFS= read -r __target; do
      [ -n "$__target" ] || continue
      if ! _sk_archive_target_safe "$__target"; then
        __bad="$__bad $__target"
      fi
    done <"$__targets"
    if [ -n "$__bad" ]; then
      rm -rf "$__work" "$__meta"
      log_error "$(_t 'the archive contains unsafe symlinks and was not extracted'): $__f"
      for __rel in $__bad; do
        log_error "  $__rel"
      done
      return "$SK_VERIFY"
    fi
  fi

  # 解到临时目录
  case "$__kind" in
    zip)
      command -v unzip >/dev/null 2>&1 || {
        rm -rf "$__work" "$__meta"
        log_error "$(_t 'unzip is required to extract zip archives')"
        return "$SK_PRECOND"
      }
      unzip -q "$__f" -d "$__work" >/dev/null 2>&1 || __rc=$?
      ;;
    tar)
      tar -xf "$__f" -C "$__work" >/dev/null 2>&1 || __rc=$?
      ;;
    tgz)
      tar -xzf "$__f" -C "$__work" >/dev/null 2>&1 || __rc=$?
      ;;
    tbz2)
      tar -xjf "$__f" -C "$__work" >/dev/null 2>&1 || __rc=$?
      ;;
    txz)
      tar -xJf "$__f" -C "$__work" >/dev/null 2>&1 || __rc=$?
      ;;
    *)
      rm -rf "$__work" "$__meta"
      log_error "$(_t 'cannot recognize the archive format'): $__f"
      return "$SK_PRECOND"
      ;;
  esac
  if [ "$__rc" -ne 0 ]; then
    # 解包失败归成 **5（校验失败）**而不是 4（网络失败）：
    # 失败原因是「这个包不可信或不可用」，重试同一个包永远不会成功，
    # 而 4 会让调用方以为「重试有用」。
    rm -rf "$__work" "$__meta"
    log_error "$(_t 'cannot extract the archive'): $__f"
    return "$SK_VERIFY"
  fi

  # 第三遍：扫解出来的文件系统，软链兜底再查一遍
  # （清单里说不清的情况：zip 里的软链、或实现自己改了名字的）
  while IFS= read -r __link; do
    [ -n "$__link" ] || continue
    __rel=${__link#"$__work"/}
    __target=$(readlink "$__link" 2>/dev/null) || continue
    case "$__target" in
      /*)
        # 绝对目标：必须落在临时目录之内
        case "$__target" in
          "$__work"/*) ;;
          *) __bad="$__bad $__rel" ;;
        esac
        ;;
      *)
        # 相对目标：相对链接所在目录解析
        __base=$(cd "$(dirname "$__link")" 2>/dev/null && pwd -P) || {
          __bad="$__bad $__rel"
          continue
        }
        case "$__base/$__target" in
          "$__work" | "$__work"/*) ;;
          *) __bad="$__bad $__rel" ;;
        esac
        ;;
    esac
  done <<EOF
$(find "$__work" -type l 2>/dev/null)
EOF
  if [ -n "$__bad" ]; then
    rm -rf "$__work" "$__meta"
    log_error "$(_t 'the archive contains unsafe symlinks and was not extracted'): $__f"
    for __rel in $__bad; do
      log_error "  $__rel"
    done
    return "$SK_VERIFY"
  fi

  # 搬进目标目录
  if ! fs_ensure_dir "$__dest" ""; then
    rm -rf "$__work" "$__meta"
    log_error "$(_t 'cannot create the destination directory'): $__dest"
    return 1
  fi
  # 目标已有同名内容时会被覆盖：解包的语义是「把包里的东西铺进去」。
  # 用 mv 而不是 cp：mv 跨设备时自己会走复制+删除，不需要我们逐字节搬；
  # 且 mv 保留符号链接本身（不解引用）⇒ 前面积查过的软链搬过去仍是软链，
  # 不会变成一份实体文件。
  # 逐个顶层项搬，不用 `cp -R dir/. dst/` —— 后者会把隐藏文件漏掉。
  __rc=0
  while IFS= read -r __rel; do
    [ -n "$__rel" ] || continue
    mv "$__rel" "$__dest/" 2>/dev/null || __rc=$?
  done <<EOF
$(find "$__work" -mindepth 1 -maxdepth 1 2>/dev/null)
EOF
  if [ "$__rc" -ne 0 ]; then
    rm -rf "$__work" "$__meta"
    log_error "$(_t 'cannot copy the extracted files into the destination'): $__dest"
    return 1
  fi
  rm -rf "$__work" "$__meta"
  return 0
}
