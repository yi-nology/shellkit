#!/usr/bin/env bash
# 发布资产不可变上传（tools/release_assets.sh，issue #87）的回归。
#
# --clobber 会静默覆盖同 tag 已发布的资产 —— 同一版本的下载内容可被替换，
# sha256 与 minisign 防的是下载链路，防不了发布账号被攻破后的整体替换。
# 修复后的纪律：同摘要跳过、异摘要拒绝并指路人工处理、不存在才上传。
# gh 用桩替身：镜像目录就是「远端 release 上已发布的资产」；
# 桩的 upload 分支拒绝重名 —— 工具若传 --clobber 或对已有资产重传，必红。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

TOOL="$TEST_ROOT/tools/release_assets.sh"

# mk_gh MIRROR —— 造一个把资产落到镜像目录的 gh 桩
mk_gh() {
  local mirror=$1 bin
  bin=$(mktemp -d "$TEST_TMP_ROOT/ghbin.XXXXXX") || _fail "mktemp failed"
  cat >"$bin/gh" <<EOF
#!/usr/bin/env bash
mirror="$mirror"
cmd=\$1
# 工具走的是 gh 的完整子命令（gh release view / download / upload）：
# 第一个词是 release，真正的小命令在第二个词。
if [ "\$cmd" = "release" ]; then shift; fi
cmd=\$1; shift
case "\$cmd" in
  view)
    if [ ! -d "\$mirror" ]; then exit 1; fi
    json=0
    for a in "\$@"; do
      case "\$a" in --json) json=1 ;; esac
    done
    if [ "\$json" = 1 ]; then ls -1 "\$mirror"; fi
    exit 0
    ;;
  download)
    dir=""
    pat=""
    while [ "\$#" -gt 0 ]; do
      case "\$1" in
        --dir) dir=\$2; shift ;;
        --pattern) pat=\$2; shift ;;
      esac
      shift
    done
    [ -n "\$dir" ] && [ -n "\$pat" ] || exit 1
    if [ -f "\$mirror/\$pat" ]; then
      cp "\$mirror/\$pat" "\$dir/\$pat" || exit 1
    fi
    exit 0
    ;;
  upload)
    shift
    for a in "\$@"; do
      case "\$a" in
        --clobber)
          printf 'the tool must not pass --clobber\n' >&2
          exit 1
          ;;
      esac
    done
    for f in "\$@"; do
      if [ -e "\$mirror/\${f##*/}" ]; then
        printf 'asset %s already exists (re-upload refused by the stub)\n' "\${f##*/}" >&2
        exit 1
      fi
      cp "\$f" "\$mirror/\${f##*/}" || exit 1
    done
    exit 0
    ;;
  *) exit 1 ;;
esac
EOF
  chmod 755 "$bin/gh"
  printf '%s' "$bin"
}

work=$(tmpdir)
printf 'payload v1\n' >"$work/payload.txt"
printf 'sums\n' >"$work/SHA256SUMS"

# CASE: release 不存在 ⇒ 前置条件错（创建是 release.yml 的活）
mirror="$work/no-such-release"
bin=$(mk_gh "$mirror")
out=$(env PATH="$bin:$PATH" bash "$TOOL" v0.1.0 "$work/payload.txt" 2>&1) && rc=0 || rc=$?
assert_eq "3" "$rc" "uploading to a missing release must be a precondition error"
assert_contains "$out" "does not exist" "the error must say the release is missing"

# CASE: release 在、资产还没发过 ⇒ 上传，且不带 --clobber
mirror="$work/rel-empty"
mkdir -p "$mirror"
bin=$(mk_gh "$mirror")
out=$(env PATH="$bin:$PATH" bash "$TOOL" v0.1.0 "$work/payload.txt" "$work/SHA256SUMS" 2>&1) && rc=0 || rc=$?
assert_eq "0" "$rc" "fresh assets must upload cleanly"
assert_contains "$out" "uploaded: payload.txt" "the tool must report what it uploaded"
assert_true test -f "$mirror/payload.txt"
assert_true test -f "$mirror/SHA256SUMS"

# CASE: 同摘要重跑 ⇒ 跳过上传（桩对重传必红，rc=0 即证明没重传）
out=$(env PATH="$bin:$PATH" bash "$TOOL" v0.1.0 "$work/payload.txt" 2>&1) && rc=0 || rc=$?
assert_eq "0" "$rc" "a same-digest re-run must skip the upload"
assert_contains "$out" "skip (same digest already published)" "the skip must be explicit"

# CASE: 同名不同摘要 ⇒ 拒绝覆盖，退出 1，远端资产原样保留
printf 'payload v1 TAMPERED\n' >"$work/payload.txt"
out=$(env PATH="$bin:$PATH" bash "$TOOL" v0.1.0 "$work/payload.txt" 2>&1) && rc=0 || rc=$?
assert_eq "1" "$rc" "a different digest must refuse the overwrite"
assert_contains "$out" "refusing to overwrite" "the refusal must be explicit"
assert_contains "$out" "different digest" "the refusal must say why"
assert_contains "$out" "by hand" "the refusal must point at the manual path"
assert_eq "payload v1" "$(cat "$mirror/payload.txt")" "the published asset must stay untouched"

# CASE: 混合 —— 一个同摘要跳过、一个没发过上传 ⇒ 只有新的被传
printf 'payload v1\n' >"$work/payload.txt"
printf 'brand new\n' >"$work/extra.txt"
out=$(env PATH="$bin:$PATH" bash "$TOOL" v0.1.0 "$work/payload.txt" "$work/extra.txt" 2>&1) && rc=0 || rc=$?
assert_eq "0" "$rc" "a mixed batch must upload only what is missing"
assert_contains "$out" "skip (same digest already published): payload.txt"
assert_contains "$out" "uploaded: extra.txt"
assert_true test -f "$mirror/extra.txt"

# CASE: 用法错 —— 缺资产参数
out=$(env PATH="$bin:$PATH" bash "$TOOL" v0.1.0 2>&1) && rc=0 || rc=$?
assert_eq "2" "$rc" "at least one asset is required"

exit 0
