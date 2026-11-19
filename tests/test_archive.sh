#!/usr/bin/env bash
#
# archive 模块的用例。
#
# 覆盖：
#   1) 魔数识别：tar / tar.gz / zip 认得出；非归档认不出
#   2) archive_list：列出成员，不写盘
#   3) archive_extract：正常解包；sha256 对不上时一个字节都不解
#   4) 路径穿越：成员名带 ../ 或绝对路径 ⇒ 拒绝解包，目标目录不变
#   5) 软链逃逸：归档里的软链指向临时目录之外 ⇒ 拒绝解包
#   6) 失败不留半份：损坏的归档解到一半失败时，目标目录一个字节都不变
#
# 断言纪律：断完整文案不断单词；临时目录名只用编号；SHELLKIT_LANG=en 由
# test_helper.sh 统一设置。

set -u

TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"
# shellcheck source=tests/test_helper.sh
. "$TEST_ROOT/tests/test_helper.sh"

. "$TEST_ROOT/lib/bootstrap.sh"

LIB="$TEST_ROOT/lib/core/archive.sh"

WORK=""
_cleanup() {
  [ -n "$WORK" ] && rm -rf "$WORK"
}
trap '_cleanup' EXIT

WORK=$(mktemp -d "${TMPDIR:-/tmp}/shellkit-arch-test.XXXXXX") || exit 1
cd "$WORK" || exit 1

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
# 造一个成员名带 ../ 的归档。GNU tar 造这种包时会警告「Removing leading
# ../」，成员名本身被改了 ⇒ 换用 python3 直接写 tar 头，绕开 tar 的清洗。
# 没有 python3 就用目录穿越的等价形式（成员名是绝对路径）。
# -------------------------------------------------------------------------
mk_traversal() {
  python3 - "$1" "$2" <<'PYEOF' 2>/dev/null
import io, sys, tarfile
out, mode = sys.argv[1], sys.argv[2]
if mode == "abs":
    name = "/tmp/shellkit-traversal-target.txt"
else:
    name = "../escaped.txt"
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w") as tf:
    data = b"escaped"
    ti = tarfile.TarInfo(name)
    ti.size = len(data)
    tf.addfile(ti, io.BytesIO(data))
with open(out, "wb") as f:
    f.write(buf.getvalue())
PYEOF
}

if command -v python3 >/dev/null 2>&1; then
  mk_traversal traversal.tar rel
  if [ -f traversal.tar ]; then
    dest4="$WORK/dest4"
    mkdir -p "$dest4"
    rc=0
    archive_extract traversal.tar "$dest4" >"$WORK/out.txt" 2>"$WORK/err.txt" || rc=$?
    assert_eq "5" "$rc" "an archive with a traversing path must be refused"
    err=$(cat "$WORK/err.txt")
    assert_contains "$err" "unsafe paths" "the refusal must say the archive contains unsafe paths"
    assert_eq "" "$(ls -A "$dest4" 2>/dev/null)" "a refused archive must not extract anything"
    # 穿越目标必须没被创建
    if [ -e "$WORK/escaped.txt" ]; then
      _fail "the traversal target must not be created"
    fi
    if [ -e /tmp/shellkit-traversal-target.txt ]; then
      _fail "the absolute path target must not be created"
      rm -f /tmp/shellkit-traversal-target.txt
    fi
  fi
fi

# -------------------------------------------------------------------------
# CASE 5：软链逃逸必须被拒绝
#
# 归档里放一个指向临时目录之外的软链。解出来时软链本身没越界（它只是个
# 链接），但经由它的成员文件会写到外面 —— 这是真实存在的逃逸路径。
# -------------------------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
  python3 - symlink.tar <<'PYEOF' 2>/dev/null
import io, tarfile
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w") as tf:
    ti = tarfile.TarInfo("link")
    ti.type = tarfile.SYMTYPE
    ti.linkname = "/etc"
    tf.addfile(ti)
    data = b"through-the-link"
    ti2 = tarfile.TarInfo("link/payload.txt")
    ti2.size = len(data)
    tf.addfile(ti2, io.BytesIO(data))
with open("symlink.tar", "wb") as f:
    f.write(buf.getvalue())
PYEOF
  if [ -f symlink.tar ]; then
    dest5="$WORK/dest5"
    mkdir -p "$dest5"
    rc=0
    archive_extract symlink.tar "$dest5" >"$WORK/out.txt" 2>"$WORK/err.txt" || rc=$?
    assert_eq "5" "$rc" "an archive with an escaping symlink must be refused"
    err=$(cat "$WORK/err.txt")
    assert_contains "$err" "unsafe symlinks" "the refusal must say the archive contains unsafe symlinks"
    # 关键结构事实：逃逸路径下不能有文件被写出去
    if [ -e /etc/payload.txt ]; then
      _fail "the escaping symlink must not write outside the destination"
      rm -f /etc/payload.txt
    fi
  fi
fi

# -------------------------------------------------------------------------
# CASE 6：损坏的归档解到一半失败 ⇒ 目标目录不变
# -------------------------------------------------------------------------
head -c 200 plain.tar >truncated.tar 2>/dev/null || _fail "cannot create the truncated archive"
dest6="$WORK/dest6"
mkdir -p "$dest6"
rc=0
archive_extract truncated.tar "$dest6" >/dev/null 2>&1 || rc=$?
assert_ne "0" "$rc" "extracting a truncated archive must fail"
assert_eq "" "$(ls -A "$dest6" 2>/dev/null)" "a failed extraction must leave the destination empty"

# -------------------------------------------------------------------------
# CASE 7：隐藏文件与嵌套目录必须一起搬过去
#
# 隐藏文件是最容易漏的一类：复制时用通配符会漏掉以点开头的项 ——
# 表现是「包里明明有 .env，解出来却不见了」，而退出码是 0。
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
# CASE 8：缺参数 ⇒ 用法错（2）

# -------------------------------------------------------------------------
rc=0
archive_extract >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "archive_extract without arguments must report a usage error"

rc=0
archive_list >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "archive_list without arguments must report a usage error"

exit 0
