#!/usr/bin/env bash
#
# archive 模块的用例。
#
# 覆盖：
#   1) 魔数识别：tar / tar.gz / zip 认得出；老式 v7 tar（没有 ustar 魔数）
#      也认得出；非归档认不出
#   2) archive_list：列出成员，不写盘
#   3) archive_extract：正常解包；sha256 对不上时一个字节都不解
#   4) 路径穿越：成员名带 ../ 或绝对路径 ⇒ 拒绝解包，目标目录不变
#   5) 软链：绝对目标 ⇒ 拒绝；相对目标解析后逃出归档 ⇒ 拒绝；
#      良性相对软链（哪怕带 ../，只要仍在归档内）⇒ 必须成功
#   6) 失败不留半份：解到一半失败时，目标目录一个字节都不变
#   7) 覆盖安装：目标已有同名非空目录 ⇒ 必须成功，不能停在新旧混合
#   8) 演练不落盘：SHELLKIT_DRY_RUN_FILES=1 时一个字节都不写
#
# 断言纪律：断完整文案不断单词；临时目录名只用编号；SHELLKIT_LANG=en 由
# test_helper.sh 统一设置。
#
# 为什么自己写 tar 头（不用 tar，也不用 python3）：
#   - tar 自己会把 ../ 开头的成员名「清洗」掉（GNU tar 报 Removing leading
#     ../），造不出带穿越路径的包；
#   - python3 不是每台机器都有 ⇒ 用它造包，判据会在没有 python3 的机器上
#     **静默跳过**（假绿）。
# 直接拼 512 字节的 tar 头，名字与软链目标都能任意指定，也不依赖外部工具。

set -u

TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"
# shellcheck source=tests/test_helper.sh
. "$TEST_ROOT/tests/test_helper.sh"

. "$TEST_ROOT/lib/bootstrap.sh"

WORK=""
_cleanup() {
  [ -n "$WORK" ] && rm -rf "$WORK"
}
trap '_cleanup' EXIT

WORK=$(mktemp -d "${TMPDIR:-/tmp}/shellkit-arch-test.XXXXXX") || exit 1
cd "$WORK" || exit 1

# -------------------------------------------------------------------------
# 造归档的底层工具：直接写 tar 头
# -------------------------------------------------------------------------

# _pad FILE N —— 在 FILE 末尾补 N 个 NUL 字节
_pad() {
  local __f=$1 __n=$2
  [ "$__n" -gt 0 ] || return 0
  dd if=/dev/zero bs="$__n" count=1 2>/dev/null >>"$__f"
}

# mk_tar_member OUT NAME [LINKNAME] [CONTENT] —— 造一个只含一个成员的 tar
#
# NAME 是成员名（可以带 ../ 或以 / 开头）；给了 LINKNAME 就是软链成员；
# CONTENT 是普通文件成员的内容。
#
# tar 头布局（ustar，偏移从 0 起）：
#   0-99 名字 / 100-107 模式 / 108-115 uid / 116-123 gid / 124-135 大小
#   136-147 mtime / 148-155 校验和 / 156 类型 / 157-256 软链目标
#   257-262 magic "ustar\0" / 263-264 版本 / 265-296 uname / 297-328 gname
#   329-336 devmajor / 337-344 devminor / 345-499 prefix / 500-511 填充
mk_tar_member() {
  local __out=$1 __name=$2 __link=${3:-} __content=${4:-} __fmt=${5:-ustar}
  local __hdr __size=0 __chk __n
  [ -n "$__content" ] && __size=${#__content}
  __hdr=$(mktemp "${TMPDIR:-/tmp}/shellkit-tarhdr.XXXXXX") || return 1
  : >"$__hdr"

  printf '%s' "$__name" >>"$__hdr"
  _pad "$__hdr" $((100 - ${#__name}))
  printf '0000644\000' >>"$__hdr"
  printf '0000000\000' >>"$__hdr"
  printf '0000000\000' >>"$__hdr"
  printf '%011o\000' "$__size" >>"$__hdr"
  printf '%011o\000' 0 >>"$__hdr"
  # 校验和先占 8 个空格（算的时候按空格算），算完再填回去
  printf '        ' >>"$__hdr"
  if [ -n "$__link" ]; then
    printf '2' >>"$__hdr"
  else
    printf '0' >>"$__hdr"
  fi
  if [ -n "$__link" ]; then
    printf '%s' "$__link" >>"$__hdr"
    _pad "$__hdr" $((100 - ${#__link}))
  else
    _pad "$__hdr" 100
  fi
  if [ "$__fmt" = "v7" ]; then
    # v7 头没有 magic/version —— 257-264 全是零
    _pad "$__hdr" 8
  else
    printf 'ustar\00000' >>"$__hdr"
  fi
  _pad "$__hdr" 32
  _pad "$__hdr" 32
  _pad "$__hdr" 8
  _pad "$__hdr" 8
  _pad "$__hdr" 155
  _pad "$__hdr" 12

  # od 会分多行输出 ⇒ 累加要跨行（每行各算各的会算出好几个和）
  __n=$(od -An -tu1 -N512 "$__hdr" | awk '{for (i = 1; i <= NF; i++) s += $i} END {print s + 0}')
  printf '%06o\000 ' "$__n" | dd of="$__hdr" bs=1 seek=148 count=8 conv=notrunc 2>/dev/null

  cat "$__hdr" >>"$__out"
  if [ "$__size" -gt 0 ]; then
    printf '%s' "$__content" >>"$__out"
  fi
  # 零长度成员后面**不能**补 512 字节：那正好是 tar 的结束标记，
  # tar 会当成「归档到此为止」⇒ 后面的成员全部看不见（假绿，不是覆盖）。
  __n=$(((512 - __size % 512) % 512))
  _pad "$__out" "$__n"
  rm -f "$__hdr"
  return 0
}

# tar_end OUT —— 补上 tar 的结束标记（两个 512 字节的零块）
#
# 单独拎出来，是因为多成员的包必须**先写完所有成员再补一次**结束标记：
# 中间夹了结束标记的话，tar 读到第一个就停了，后面的成员根本看不见。
tar_end() {
  local __out=$1
  _pad "$__out" 1024
  return 0
}

# -------------------------------------------------------------------------
# CASE 1：魔数识别
# -------------------------------------------------------------------------
mkdir -p src1/sub
printf 'hello' >src1/a.txt
printf 'world' >src1/sub/b.txt
tar -cf plain.tar -C src1 . 2>/dev/null || _fail "cannot create the tar archive"
tar -czf packed.tgz -C src1 . 2>/dev/null || _fail "cannot create the tgz archive"

kind=$(_sk_archive_kind plain.tar)
assert_eq "tar" "$kind" "a plain tar archive must be recognized as tar"

kind=$(_sk_archive_kind packed.tgz)
assert_eq "tgz" "$kind" "a gzipped tar archive must be recognized as tgz"

printf 'not an archive at all' >plain.txt
if _sk_archive_kind plain.txt >/dev/null 2>&1; then
  _fail "a plain text file must not be recognized as an archive"
fi

# 老式 v7 tar 没有 ustar 魔数（偏移 257 处是零），但它仍是合法的 tar。
# 只认魔数会把这类包判成「认不出格式」—— 明明能解开却说不能。
mk_tar_member v7.tar "payload" "" "v7 content" v7
tar_end v7.tar
kind=$(_sk_archive_kind v7.tar)
assert_eq "tar" "$kind" "an old-style tar without the ustar magic must still be recognized as tar"
dest_v7="$WORK/destv7"
rc=0
archive_extract v7.tar "$dest_v7" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "an old-style tar must be extractable"
assert_eq "v7 content" "$(cat "$dest_v7/payload" 2>/dev/null)" "the old-style tar must extract its content"

# -------------------------------------------------------------------------
# CASE 2：archive_list 列出成员，不写盘
# -------------------------------------------------------------------------
out=$(archive_list plain.tar)
assert_contains "$out" "a.txt" "the listing must contain the file name"
assert_contains "$out" "sub/b.txt" "the listing must contain the nested file name"

before=$(ls -A | wc -l | tr -d ' ')
archive_list plain.tar >/dev/null
after=$(ls -A | wc -l | tr -d ' ')
assert_eq "$before" "$after" "listing an archive must not create any file"

rc=0
archive_list /nonexistent/archive.tar >/dev/null 2>&1 || rc=$?
assert_eq "3" "$rc" "listing a missing archive must report a precondition failure"

# -------------------------------------------------------------------------
# CASE 3：archive_extract 正常解包
# -------------------------------------------------------------------------
dest1="$WORK/dest1"
rc=0
archive_extract plain.tar "$dest1" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "extracting a plain tar archive must succeed"
assert_eq "hello" "$(cat "$dest1/a.txt" 2>/dev/null)" "the extracted file must have the original content"
assert_eq "world" "$(cat "$dest1/sub/b.txt" 2>/dev/null)" "the nested file must be extracted too"

# sha256 对不上 ⇒ 一个字节都不解（目标目录必须还是空的）
sum=$(os_sha256 plain.tar)
dest2="$WORK/dest2"
mkdir -p "$dest2"
rc=0
archive_extract plain.tar "$dest2" "0000000000000000000000000000000000000000000000000000000000000000" \
  >"$WORK/out.txt" 2>"$WORK/err.txt" || rc=$?
assert_eq "5" "$rc" "a checksum mismatch must be reported as a verification failure"
assert_eq "" "$(ls -A "$dest2" 2>/dev/null)" "a failed verification must not extract anything"

# sha256 对得上 ⇒ 正常解包
dest3="$WORK/dest3"
rc=0
archive_extract plain.tar "$dest3" "$sum" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "extracting with a matching checksum must succeed"
assert_eq "hello" "$(cat "$dest3/a.txt" 2>/dev/null)" "the checksummed extraction must produce the file"

# -------------------------------------------------------------------------
# CASE 4：路径穿越必须被拒绝
#
# 成员名带 ../ 时，归档里没有那个成员之前，tar 自己会把名字清洗掉；
# 所以这里直接写 tar 头，成员名原样保留。
# -------------------------------------------------------------------------
mk_tar_member traversal.tar "../escaped.txt" "" "escaped"
tar_end traversal.tar
dest4="$WORK/dest4"
mkdir -p "$dest4"
rc=0
archive_extract traversal.tar "$dest4" >"$WORK/out.txt" 2>"$WORK/err.txt" || rc=$?
assert_eq "5" "$rc" "an archive with a traversing path must be refused"
err=$(cat "$WORK/err.txt")
assert_contains "$err" "unsafe paths" "the refusal must say the archive contains unsafe paths"
# 明细必须打出来：清单在临时目录里，先删了就永远打不出来（还会漏一条裸 bash 错误）
assert_contains "$err" "../escaped.txt" "the refusal must name the offending member"
assert_eq "" "$(ls -A "$dest4" 2>/dev/null)" "a refused archive must not extract anything"
# 结构事实：穿越出去的落点必须没有被创建
if [ -e "$WORK/escaped.txt" ]; then
  _fail "the traversal target must not be created"
fi

# 绝对路径成员 ⇒ 同样拒绝
abs_target="$WORK/abs-escaped.txt"
mk_tar_member absolute.tar "$abs_target" "" "escaped"
tar_end absolute.tar
dest4b="$WORK/dest4b"
mkdir -p "$dest4b"
rc=0
archive_extract absolute.tar "$dest4b" >"$WORK/out.txt" 2>"$WORK/err.txt" || rc=$?
assert_eq "5" "$rc" "an archive with an absolute member path must be refused"
assert_eq "" "$(ls -A "$dest4b" 2>/dev/null)" "a refused archive must not extract anything"
if [ -e "$abs_target" ]; then
  _fail "the absolute path target must not be created"
fi

# -------------------------------------------------------------------------
# CASE 5：软链的三种走向
#
#   5a 绝对目标 ⇒ 拒绝（归档里的绝对软链不可能落在归档之内）
#   5b 相对目标解析后逃出归档 ⇒ 拒绝
#   5c 良性相对软链（带 ../ 但仍在归档内）⇒ 必须成功
# -------------------------------------------------------------------------
mk_tar_member symlink_abs.tar "link" "/etc"
tar_end symlink_abs.tar
dest5="$WORK/dest5"
mkdir -p "$dest5"
rc=0
archive_extract symlink_abs.tar "$dest5" >"$WORK/out.txt" 2>"$WORK/err.txt" || rc=$?
assert_eq "5" "$rc" "an archive with an absolute symlink target must be refused"
err=$(cat "$WORK/err.txt")
assert_contains "$err" "unsafe symlinks" "the refusal must say the archive contains unsafe symlinks"
# 结构事实：目标目录里不能有那个软链
if [ -e "$dest5/link" ] || [ -L "$dest5/link" ]; then
  _fail "the refused symlink must not land in the destination"
fi

# 相对目标逃出归档：link -> ../../outside
mk_tar_member symlink_rel.tar "link" "../../outside"
tar_end symlink_rel.tar
dest5b="$WORK/dest5b"
mkdir -p "$dest5b"
rc=0
archive_extract symlink_rel.tar "$dest5b" >"$WORK/out.txt" 2>"$WORK/err.txt" || rc=$?
assert_eq "5" "$rc" "an archive with an escaping relative symlink must be refused"
err=$(cat "$WORK/err.txt")
assert_contains "$err" "unsafe symlinks" "the refusal must say the archive contains unsafe symlinks"
if [ -e "$dest5b/link" ] || [ -L "$dest5b/link" ]; then
  _fail "the refused relative symlink must not land in the destination"
fi

# 多层软链：a -> b，b -> ../../outside（每一跳都要查，逃逸的那一跳必须被拒）
#
# 两个成员**必须在同一个包里**：拆成两个包时，第二包里的逃逸那一跳单独就能
# 被拒，测不出「链上每一跳都要查」。
mk_tar_member symlink_chain.tar "a" "b"
mk_tar_member symlink_chain.tar "b" "../../outside"
tar_end symlink_chain.tar
dest5c="$WORK/dest5c"
mkdir -p "$dest5c"
rc=0
archive_extract symlink_chain.tar "$dest5c" >"$WORK/out.txt" 2>"$WORK/err.txt" || rc=$?
assert_eq "5" "$rc" "a symlink chain whose second hop escapes must be refused"
err=$(cat "$WORK/err.txt")
assert_contains "$err" "unsafe symlinks" "the refusal must say the archive contains unsafe symlinks"
if [ -e "$dest5c/a" ] || [ -L "$dest5c/a" ]; then
  _fail "the refused symlink chain must not land in the destination"
fi

# 良性的一跳软链：a -> b（b 是同包里的普通文件）⇒ 必须成功
mk_tar_member symlink_ok.tar "a" "b"
mk_tar_member symlink_ok.tar "b" ""
tar_end symlink_ok.tar
dest5c2="$WORK/dest5c2"
rc=0
archive_extract symlink_ok.tar "$dest5c2" >"$WORK/out.txt" 2>"$WORK/err.txt" || rc=$?
assert_eq "0" "$rc" "a symlink chain that stays inside the archive must be accepted"
assert_eq "b" "$(readlink "$dest5c2/a" 2>/dev/null)" "the relative symlink must land in the destination"

# 良性相对软链：link -> sibling（同目录），必须成功
mkdir -p benign
printf 'sibling payload' >benign/sibling
tar -cf benign_base.tar -C benign sibling 2>/dev/null || _fail "cannot create the benign base archive"
mk_tar_member symlink_benign.tar "link" "sibling"
tar_end symlink_benign.tar
dest5d="$WORK/dest5d"
rc=0
archive_extract benign_base.tar "$dest5d" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "the benign base archive must be extracted"
rc=0
archive_extract symlink_benign.tar "$dest5d" >"$WORK/out.txt" 2>"$WORK/err.txt" || rc=$?
assert_eq "0" "$rc" "a benign relative symlink must be accepted"
assert_eq "sibling" "$(readlink "$dest5d/link" 2>/dev/null)" "the benign symlink must be kept as a symlink"
assert_eq "sibling payload" "$(cat "$dest5d/sibling" 2>/dev/null)" "the symlink target must be extracted too"

# 良性但带 ../ 的相对软链：a/link -> ../b（仍在归档内）⇒ 必须成功
mkdir -p inner
printf 'inner payload' >inner/b
tar -cf inner_base.tar -C inner b 2>/dev/null || _fail "cannot create the inner base archive"
mk_tar_member symlink_inner.tar "a/link" "../b"
tar_end symlink_inner.tar
dest5e="$WORK/dest5e"
rc=0
archive_extract inner_base.tar "$dest5e" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "the inner base archive must be extracted"
rc=0
archive_extract symlink_inner.tar "$dest5e" >"$WORK/out.txt" 2>"$WORK/err.txt" || rc=$?
assert_eq "0" "$rc" "a relative symlink that stays inside the archive must be accepted"
assert_eq "../b" "$(readlink "$dest5e/a/link" 2>/dev/null)" "the inner relative symlink must be kept as a symlink"

# -------------------------------------------------------------------------
# CASE 6：解到一半失败 ⇒ 目标目录不变
#
# 头 700 字节：ustar 魔数还在（偏移 257），所以格式认得出；
# 但内容块被截断了 ⇒ tar 读到一半失败。
# -------------------------------------------------------------------------
head -c 700 plain.tar >truncated.tar 2>/dev/null || _fail "cannot create the truncated archive"
dest6="$WORK/dest6"
mkdir -p "$dest6"
rc=0
archive_extract truncated.tar "$dest6" >"$WORK/out.txt" 2>"$WORK/err.txt" || rc=$?
assert_eq "5" "$rc" "a truncated archive must be reported as a verification failure"
assert_eq "" "$(ls -A "$dest6" 2>/dev/null)" "a failed extraction must leave the destination empty"

# -------------------------------------------------------------------------
# CASE 6c：缺 tar 结尾标记的包 ⇒ 5（判据必须与 tar 的实现无关）
#
# GNU tar 读到 EOF 就**当归档到此为止**，照样退出 0 ⇒ 被截断的包会被当成
# 「只有前几个成员的包」静默解开 ⇒ 半份内容被装上，而调用方拿到的是成功。
# bsdtar 恰好更严（同一个包在 macOS 上会红），但「同一份代码在不同 tar 实现
# 上给出不同结论」本身就是缺陷 —— 判据必须与实现无关。
#
# 这个包的成员是**完整**的（header + data 都在），只缺末尾那两块 512 字节的零
# ⇒ bsdtar 与 GNU tar 都会**接受**它 ⇒ 只有「结尾标记齐全吗」这条自检能拒它
# ⇒ 这条用例在本机也有判据能力（把自检去掉，用例立刻变红）。
# ---------------------------------------------------------------------------
mk_tar_member noend.tar "a.txt" "" "hello"
dest6d="$WORK/dest6d"
mkdir -p "$dest6d"
rc=0
archive_extract noend.tar "$dest6d" >"$WORK/out.txt" 2>"$WORK/err.txt" || rc=$?
assert_eq "5" "$rc" "an archive without the end-of-archive marker must be refused"
err=$(cat "$WORK/err.txt")
assert_contains "$err" "the archive is truncated" "the refusal must say the archive is truncated"
assert_eq "" "$(ls -A "$dest6d" 2>/dev/null)" "a refused archive must leave the destination empty"

# archive_list 同样要拒：列出来的清单必须是**完整**的清单
rc=0
archive_list noend.tar >"$WORK/out.txt" 2>"$WORK/err.txt" || rc=$?
assert_eq "5" "$rc" "listing an archive without the end-of-archive marker must fail too"

# ---------------------------------------------------------------------------
# CASE 6b：列得出、解不开 ⇒ 5（解包失败那条路的判据）
#
# 造一个「文件 a」与「a/b」同包的归档：成员列表列得出来（tar -tf 正常），
# 但解的时候 a/b 建不出来（a 已经是文件）⇒ tar 报错退出。
# 只断「列不出」的话，「解包失败 ⇒ 5」那条路会一直没有判据 ——
# 造回缺陷（把解包失败也返回 0）用例也不会红。
# -------------------------------------------------------------------------
mk_tar_member conflict.tar "a" "" "file-a"
mk_tar_member conflict.tar "a/b" "" "file-ab"
tar_end conflict.tar
dest6c="$WORK/dest6c"
mkdir -p "$dest6c"
rc=0
archive_extract conflict.tar "$dest6c" >"$WORK/out.txt" 2>"$WORK/err.txt" || rc=$?
assert_eq "5" "$rc" "an archive that cannot be extracted must be reported as a verification failure"
assert_eq "" "$(ls -A "$dest6c" 2>/dev/null)" "a failed extraction must leave the destination empty"

# 格式都认不出的 ⇒ 3（前置条件不满足）
printf 'this is not an archive' >garbage.bin
dest6b="$WORK/dest6b"
mkdir -p "$dest6b"
rc=0
archive_extract garbage.bin "$dest6b" >/dev/null 2>&1 || rc=$?
assert_eq "3" "$rc" "an unrecognized archive must report a precondition failure"
assert_eq "" "$(ls -A "$dest6b" 2>/dev/null)" "an unrecognized archive must leave the destination empty"

# -------------------------------------------------------------------------
# CASE 7：隐藏文件与嵌套目录必须一起搬过去
# -------------------------------------------------------------------------
mkdir -p hidden/.config
printf 'secret' >hidden/.env
printf 'cfg' >hidden/.config/app.conf
tar -cf hidden.tar -C hidden . 2>/dev/null || _fail "cannot create the hidden archive"

dest7="$WORK/dest7"
rc=0
archive_extract hidden.tar "$dest7" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "extracting an archive with hidden files must succeed"
assert_eq "secret" "$(cat "$dest7/.env" 2>/dev/null)" "the hidden file must be extracted"
assert_eq "cfg" "$(cat "$dest7/.config/app.conf" 2>/dev/null)" "the hidden nested file must be extracted"

# -------------------------------------------------------------------------
# CASE 8：覆盖安装 —— 目标已有同名非空目录
#
# 这是最常见的场景：把新包解到已有的安装目录。
# 逐项 mv 在这里会撞上 "Directory not empty" 而失败，
# 于是目标目录停在新旧混合的状态 —— 这条用例就是判它不再发生。
# -------------------------------------------------------------------------
mkdir -p oldpkg/sub
printf 'v1' >oldpkg/a.txt
printf 'old-only' >oldpkg/sub/keep.txt
tar -cf oldpkg.tar -C oldpkg . 2>/dev/null || _fail "cannot create the old package archive"

mkdir -p newpkg/sub
printf 'v2' >newpkg/a.txt
printf 'new-only' >newpkg/sub/new.txt
tar -cf newpkg.tar -C newpkg . 2>/dev/null || _fail "cannot create the new package archive"

dest8="$WORK/dest8"
rc=0
archive_extract oldpkg.tar "$dest8" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "the first extraction must succeed"
assert_eq "v1" "$(cat "$dest8/a.txt" 2>/dev/null)" "the first package must be in place"

rc=0
archive_extract newpkg.tar "$dest8" >"$WORK/out.txt" 2>"$WORK/err.txt" || rc=$?
assert_eq "0" "$rc" "extracting over an existing directory must succeed, not fail with a mixed state"
assert_eq "v2" "$(cat "$dest8/a.txt" 2>/dev/null)" "the new package must win over the old file"
assert_eq "new-only" "$(cat "$dest8/sub/new.txt" 2>/dev/null)" "the new nested file must be in place"
assert_eq "old-only" "$(cat "$dest8/sub/keep.txt" 2>/dev/null)" "a file the new package does not provide must be kept"

# -------------------------------------------------------------------------
# CASE 8b：目标目录是只读（555）⇒ 也要能解
#
# 暂存目录若**先**继承目标目录的权限，它也是只读的 ⇒ tar 写不进去 ⇒
# 好包被误判成坏包（退 5）。所以权限必须在解完之后才套。
# -------------------------------------------------------------------------
mkdir -p "$WORK/ro-dest"
chmod 555 "$WORK/ro-dest"
rc=0
archive_extract plain.tar "$WORK/ro-dest" >"$WORK/out.txt" 2>"$WORK/err.txt" || rc=$?
assert_eq "0" "$rc" "extracting into a read-only destination must still work"
assert_eq "hello" "$(cat "$WORK/ro-dest/a.txt" 2>/dev/null)" "the read-only destination must receive the content"
chmod 755 "$WORK/ro-dest"

# -------------------------------------------------------------------------
# CASE 8c：目标目录里**既有**的软链 ⇒ 原样保留（已知边界）
#
# archive_extract 保证的是「**包里的东西**逃不出去」，不保证「目标目录
# 本来就干净」：调用方自己放的软链是它自己的数据，覆盖安装后会原样搬回来。
# 锁住这条行为 —— 将来若有人顺手改成「清理掉」，用户的数据就没了。
# -------------------------------------------------------------------------
mkdir -p "$WORK/hostile-dest" "$WORK/outside"
ln -s "$WORK/outside" "$WORK/hostile-dest/link"
rc=0
archive_extract plain.tar "$WORK/hostile-dest" >"$WORK/out.txt" 2>"$WORK/err.txt" || rc=$?
assert_eq "0" "$rc" "extracting over a destination with a pre-existing symlink must succeed"
assert_eq "hello" "$(cat "$WORK/hostile-dest/a.txt" 2>/dev/null)" "the new content must be in place"
assert_eq "$WORK/outside" "$(readlink "$WORK/hostile-dest/link" 2>/dev/null)" "the pre-existing symlink must be preserved as-is"
# 结构事实：不能有任何文件经它写到外面去
assert_eq "" "$(ls -A "$WORK/outside" 2>/dev/null)" "nothing may be written through the pre-existing symlink"

# -------------------------------------------------------------------------
# CASE 9：演练不落盘
# -------------------------------------------------------------------------
dest9="$WORK/dest9"
out=$(SHELLKIT_DRY_RUN_FILES=1 archive_extract plain.tar "$dest9" 2>&1)
assert_contains "$out" "[dry-run] extract" "the dry-run plan must name the extraction"
rc=0
SHELLKIT_DRY_RUN_FILES=1 archive_extract plain.tar "$dest9" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "a dry-run extraction must not fail"
if [ -e "$dest9" ]; then
  _fail "the dry-run extraction must not create the destination"
fi

# -------------------------------------------------------------------------
# CASE 10：目标目录是软链 ⇒ 拒绝（不顺着软链写）
# -------------------------------------------------------------------------
mkdir -p realdest
ln -s realdest linkdest 2>/dev/null || _fail "cannot create the symlinked destination"
rc=0
archive_extract plain.tar "$WORK/linkdest" >"$WORK/out.txt" 2>"$WORK/err.txt" || rc=$?
assert_eq "3" "$rc" "a symlinked destination must be refused"
err=$(cat "$WORK/err.txt")
assert_contains "$err" "the destination is a symlink" "the refusal must say the destination is a symlink"

# -------------------------------------------------------------------------
# CASE 12：压缩格式的解包分支
#
# tgz / tbz2 / txz / zip 四条分支曾经一条判据都没有 ——
# 把分支写错（比如 tbz2 也走 tar -xzf）照样全绿。
# 缺压缩器的机器上打印一行说明（不是静默跳过）。
# -------------------------------------------------------------------------
mkdir -p fmt
printf 'fmt payload' >fmt/file.txt

tar -czf fmt.tgz -C fmt file.txt 2>/dev/null || _fail "cannot create the tgz archive"
# 魔数识别是**平台无关**的判据：解包走哪条分支由它决定，
# 所以每种格式都要先钉住「认成什么」。
assert_eq "tgz" "$(_sk_archive_kind fmt.tgz)" "a gzipped tar archive must be recognized as tgz"
rc=0
archive_extract fmt.tgz "$WORK/dest_tgz" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "extracting a tgz archive must succeed"
assert_eq "fmt payload" "$(cat "$WORK/dest_tgz/file.txt" 2>/dev/null)" "the tgz archive must extract its content"

if tar -cjf fmt.tbz2 -C fmt file.txt 2>/dev/null; then
  assert_eq "tbz2" "$(_sk_archive_kind fmt.tbz2)" "a bzip2 tar archive must be recognized as tbz2"
  rc=0
  archive_extract fmt.tbz2 "$WORK/dest_tbz2" >/dev/null 2>&1 || rc=$?
  assert_eq "0" "$rc" "extracting a tbz2 archive must succeed"
  assert_eq "fmt payload" "$(cat "$WORK/dest_tbz2/file.txt" 2>/dev/null)" "the tbz2 archive must extract its content"
else
  printf 'note: bzip2 is unavailable here, the tbz2 branch is not exercised\n' >&2
fi

if tar -cJf fmt.txz -C fmt file.txt 2>/dev/null; then
  assert_eq "txz" "$(_sk_archive_kind fmt.txz)" "an xz tar archive must be recognized as txz"
  rc=0
  archive_extract fmt.txz "$WORK/dest_txz" >/dev/null 2>&1 || rc=$?
  assert_eq "0" "$rc" "extracting a txz archive must succeed"
  assert_eq "fmt payload" "$(cat "$WORK/dest_txz/file.txt" 2>/dev/null)" "the txz archive must extract its content"
else
  printf 'note: xz is unavailable here, the txz branch is not exercised\n' >&2
fi

if command -v zip >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1; then
  (cd fmt && zip -q "$WORK/fmt.zip" file.txt) 2>/dev/null || _fail "cannot create the zip archive"
  assert_eq "zip" "$(_sk_archive_kind "$WORK/fmt.zip")" "a zip archive must be recognized as zip"
  rc=0
  archive_extract "$WORK/fmt.zip" "$WORK/dest_zip" >/dev/null 2>&1 || rc=$?
  assert_eq "0" "$rc" "extracting a zip archive must succeed"
  assert_eq "fmt payload" "$(cat "$WORK/dest_zip/file.txt" 2>/dev/null)" "the zip archive must extract its content"
else
  printf 'note: zip or unzip is unavailable here, the zip branch is not exercised\n' >&2
fi

# -------------------------------------------------------------------------
# CASE 13：缺参数 ⇒ 用法错（2）
# -------------------------------------------------------------------------
rc=0
archive_extract >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "archive_extract without arguments must report a usage error"

rc=0
archive_list >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "archive_list without arguments must report a usage error"

exit 0
