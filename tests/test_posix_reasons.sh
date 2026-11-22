#!/usr/bin/env bash
# 能力清单的**理由口径**判据：新能力必须是 yes，旧的批量套话必须换掉。
# 为什么单独一条：清单是设备侧选型的依据 —— 理由写错（把 os_name 的缺席
# 归因于「包管理器」）会把人引向错误判断，而 posix-check 只查「有没有写理由」，
# 不查理由对不对。
. "$(cd "$(dirname "$0")" && pwd)/test_helper.sh"
ROOT="$TEST_ROOT"
CAP="$ROOT/lib/posix/capabilities.tsv"

# _field FILE FN COL —— 清单里 FN 的第 COL 列（2=有没有，3=理由/备注）
_field() {
  awk -F'\t' -v f="$2" -v c="$3" '$1==f{print $c}' "$1"
}

# _check_reasons FILE —— 全部理由断言；通过返回 0，违反返回 1。
# 独立成函数是为了变异自证：把源码的理由表改回套话、重新生成清单后，
# 同一批断言必须判红（否则断言是恒真的）。
_check_reasons() {
  local __cap=$1
  local __bad=0
  local __v
  local __fn
  # 1) 五个新能力必须是 yes
  for __fn in os_name os_arch os_is_root os_has_cmd require_cmd; do
    __v=$(_field "$__cap" "$__fn" 2)
    if [ "$__v" != "yes" ]; then
      printf 'FAIL: %s 应进 POSIX 子集，清单里是 <%s>\n' "$__fn" "$__v" >&2
      __bad=1
    fi
  done
  # 2) os_distro_id 的 no 理由不许再是「包管理器」套话（它是发行版探测）
  __v=$(_field "$__cap" os_distro_id 3)
  case "$__v" in
    '')
      printf 'FAIL: os_distro_id 没有理由\n' >&2
      __bad=1
      ;;
    *包管理器*)
      printf 'FAIL: os_distro_id 的理由仍是包管理器套话: %s\n' "$__v" >&2
      __bad=1
      ;;
  esac
  # 3) os_sha256 的理由必须指向 net_sha256（哈希已在子集里）
  __v=$(_field "$__cap" os_sha256 3)
  case "$__v" in
    *net_sha256*) ;;
    *)
      printf 'FAIL: os_sha256 的理由应指向 net_sha256: %s\n' "$__v" >&2
      __bad=1
      ;;
  esac
  # 4) os_pkg_install 保留真实理由（这条本来就对，钉住不许被顺手改坏）
  __v=$(_field "$__cap" os_pkg_install 3)
  case "$__v" in
    *系统包*) ;;
    *)
      printf 'FAIL: os_pkg_install 的理由应说明系统包: %s\n' "$__v" >&2
      __bad=1
      ;;
  esac
  return "$__bad"
}

# ---- 真清单必须过 ----
if ! _check_reasons "$CAP"; then
  _fail "能力清单的理由口径不达标（明细见上方 FAIL）"
fi

# ---- 变异自证：把 os.sh 模块默认理由改回套话 ⇒ 同一批断言必须判红 ----
d="$(tmpdir)"
mkdir -p "$d/tools" "$d/lib"
cp -R "$ROOT/lib/." "$d/lib/"
sed 's|POSIX 子集只给 os_name / os_arch / os_is_root / os_has_cmd（平台感知与命令前置检查）；系统包、桌面与发行版探测不进子集|设备侧没有包管理器，也不该动系统包|' "$ROOT/tools/check_posix.sh" >"$d/tools/check_posix.sh"
if cmp -s "$ROOT/tools/check_posix.sh" "$d/tools/check_posix.sh"; then
  _fail "变异没落到源码上（os.sh 模块默认理由没变）—— 判据自己坏了"
fi
if ! SHELLKIT_CHECK_ROOT="$d" bash "$d/tools/check_posix.sh" --write >/dev/null 2>&1; then
  _fail "变异清单生成失败（check_posix --write 在夹具上退了非 0）"
fi
if _check_reasons "$d/lib/posix/capabilities.tsv" >/dev/null 2>&1; then
  _fail "变异自证失败：理由表改回套话后判据没变红 —— 断言是恒真的"
fi

echo "OK: 能力清单理由口径正确，变异自证通过"
