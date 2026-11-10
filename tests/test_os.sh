#!/usr/bin/env bash
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"

case "$(os_name)" in
  linux | darwin | other) ;;
  *) _fail "unexpected os_name: $(os_name)" ;;
esac

case "$(os_arch)" in
  x86_64 | aarch64 | other) ;;
  *) _fail "unexpected os_arch: $(os_arch)" ;;
esac

assert_true os_has_cmd bash
assert_false os_has_cmd definitely-not-a-command-shellkit
assert_true os_has_cmd bash sh

d=$(tmpdir)

f="$d/sed.txt"
printf 'a=1\n' >"$f"
os_sed_i 's/a=1/a=2/' "$f"
assert_eq "a=2" "$(cat "$f")" "os_sed_i"

f="$d/abc.txt"
printf 'abc' >"$f"
assert_eq "900150983cd24fb0d6963f7d28e17f72" "$(os_md5 "$f")" "os_md5"
assert_eq "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" "$(os_sha256 "$f")" "os_sha256"

mgr=$(os_pkg_manager 2>/dev/null || true)
if [ -n "$mgr" ]; then
  case "$mgr" in
    dnf | yum | apt-get | zypper | apk) ;;
    *) _fail "unexpected package manager: $mgr" ;;
  esac
fi

# --- 发行版与桌面环境检测 --------------------------------------------------

d=$(tmpdir)

# 样本：麒麟服务器版（RHEL 系）
cat >"$d/kylin-server" <<'EOF'
NAME="Kylin Linux Advanced Server"
VERSION="10 (Sword)"
ID="kylin"
ID_LIKE="rhel centos fedora"
PRETTY_NAME="Kylin Linux Advanced Server release 10 (Sword)"
EOF

# 样本：麒麟桌面版（Ubuntu 系）
cat >"$d/kylin-desktop" <<'EOF'
NAME="Kylin Linux Advanced Server"
ID="kylin"
ID_LIKE="ubuntu"
PRETTY_NAME="Kylin Linux Advanced Server release 10 (Sword)"
EOF

# os_release_field：读字段
assert_eq "kylin" "$(os_release_field ID "$d/kylin-server")" "os_release_field ID"
assert_eq "rhel centos fedora" "$(os_release_field ID_LIKE "$d/kylin-server")" "os_release_field ID_LIKE"
assert_eq "Kylin Linux Advanced Server release 10 (Sword)" \
  "$(os_release_field PRETTY_NAME "$d/kylin-server")" "os_release_field PRETTY_NAME"

# os_release_field：成对的双引号 / 单引号都要剥掉
printf 'ID=ubuntu\nVERSION_ID="22.04"\n' >"$d/quoted"
assert_eq "ubuntu" "$(os_release_field ID "$d/quoted")" "os_release_field 无引号"
assert_eq "22.04" "$(os_release_field VERSION_ID "$d/quoted")" "os_release_field 剥双引号"
printf "ID='debian'\n" >"$d/squoted"
assert_eq "debian" "$(os_release_field ID "$d/squoted")" "os_release_field 剥单引号"

# os_release_field：剥引号的口径与 unix_script 的 _osr_field 逐字一致 ——
# 前导一个、末尾一个各自独立；剩下中间若还带引号 => 整体不匹配（读成空）
printf 'ID="ubuntu\n' >"$d/lead-only"
assert_eq "ubuntu" "$(os_release_field ID "$d/lead-only")" "os_release_field 只剥前导引号"
printf 'ID=ubuntu"\n' >"$d/trail-only"
assert_eq "ubuntu" "$(os_release_field ID "$d/trail-only")" "os_release_field 只剥末尾引号"
printf 'ID=a"b\n' >"$d/inner-quote"
assert_eq "" "$(os_release_field ID "$d/inner-quote")" "os_release_field 中间有引号读成空"

# os_release_field：找不到的键 -> stdout 空、退出码 0
assert_eq "" "$(os_release_field NO_SUCH_KEY "$d/quoted")" "os_release_field 找不到的键"
assert_exit_code 0 os_release_field NO_SUCH_KEY "$d/quoted"

# os_release_field：文件不存在 -> stdout 空、退出码 0
assert_eq "" "$(os_release_field ID "$d/no-such-file")" "os_release_field 文件不存在"
assert_exit_code 0 os_release_field ID "$d/no-such-file"

# os_release_field：文件在但不可读 -> stdout 空、退出码 0（root 读什么都行，跳过）
if [ "$(id -u)" != "0" ]; then
  printf 'ID=secret\n' >"$d/unreadable"
  chmod 000 "$d/unreadable"
  assert_eq "" "$(os_release_field ID "$d/unreadable")" "os_release_field 文件不可读"
  assert_exit_code 0 os_release_field ID "$d/unreadable"
  chmod 644 "$d/unreadable"
fi

# os_release_field：不传 FILE 时依次试 /etc/os-release、/usr/lib/os-release
assert_exit_code 0 os_release_field ID

# os_release_field：KEY 为空是用法错
assert_exit_code 2 os_release_field
assert_exit_code 2 os_release_field ""

# os_distro_id：转小写
assert_eq "kylin" "$(os_distro_id "$d/kylin-server")" "os_distro_id"
printf 'ID=Ubuntu\n' >"$d/upper-id"
assert_eq "ubuntu" "$(os_distro_id "$d/upper-id")" "os_distro_id 转小写"

# os_distro_name：PRETTY_NAME，空则回退 NAME
assert_eq "Kylin Linux Advanced Server release 10 (Sword)" \
  "$(os_distro_name "$d/kylin-server")" "os_distro_name"
printf 'NAME="Fallback Name"\nID=foo\n' >"$d/no-pretty"
assert_eq "Fallback Name" "$(os_distro_name "$d/no-pretty")" "os_distro_name 回退 NAME"

# os_distro_family：麒麟靠 ID_LIKE 判定 —— 服务器版 RHEL 系、桌面版 Ubuntu 系
assert_eq "rhel" "$(os_distro_family "$d/kylin-server")" "os_distro_family 麒麟服务器版"
assert_eq "debian" "$(os_distro_family "$d/kylin-desktop")" "os_distro_family 麒麟桌面版"

# os_distro_family：kylin 不在 ID 硬表里 —— 没有 ID_LIKE 时只能判 unknown
printf 'ID="kylin"\n' >"$d/kylin-bare"
assert_eq "unknown" "$(os_distro_family "$d/kylin-bare")" "os_distro_family kylin 不进 ID 硬表"

# os_distro_family：ID 词表
printf 'ID=ubuntu\n' >"$d/id-ubuntu"
assert_eq "debian" "$(os_distro_family "$d/id-ubuntu")" "os_distro_family ubuntu"
printf 'ID=centos\n' >"$d/id-centos"
assert_eq "rhel" "$(os_distro_family "$d/id-centos")" "os_distro_family centos"
printf 'ID=opensuse-leap\n' >"$d/id-opensuse"
assert_eq "suse" "$(os_distro_family "$d/id-opensuse")" "os_distro_family opensuse"
printf 'ID=arch\n' >"$d/id-arch"
assert_eq "arch" "$(os_distro_family "$d/id-arch")" "os_distro_family arch"
printf 'ID=manjaro\n' >"$d/id-manjaro"
assert_eq "arch" "$(os_distro_family "$d/id-manjaro")" "os_distro_family manjaro"
printf 'ID=alpine\n' >"$d/id-alpine"
assert_eq "alpine" "$(os_distro_family "$d/id-alpine")" "os_distro_family alpine"
printf 'ID=nonsense\n' >"$d/id-nonsense"
assert_eq "unknown" "$(os_distro_family "$d/id-nonsense")" "os_distro_family 认不出"

# os_distro_family：给了文件就只看这个文件，不许混入本机包管理器
stub apt-get
assert_eq "arch" "$(os_distro_family "$d/id-arch")" "os_distro_family 文件模式不混入本机包管理器"
unstub apt-get

# os_distro_family：主机模式的结果只能是已知族之一
case "$(os_distro_family)" in
  debian | rhel | suse | arch | alpine | unknown) ;;
  *) _fail "unexpected os_distro_family: $(os_distro_family)" ;;
esac

# os_desktop_env：先探一次本机有没有会话二进制（下面的断言要区分「没有线索」和「机器上本来就有」）
__sk_test_bin=0
for __sk_test_b in ukui-session kwin_x11 startdde dde-desktop gnome-session \
  gnome-shell plasmashell startplasma-x11 xfce4-session mate-session \
  cinnamon-session lxsession; do
  if command -v "$__sk_test_b" >/dev/null 2>&1; then
    __sk_test_bin=1
    break
  fi
done

# os_desktop_env：三个环境变量
unset XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP DESKTOP_SESSION
export XDG_CURRENT_DESKTOP="ubuntu:GNOME"
assert_eq "gnome" "$(os_desktop_env)" "os_desktop_env 冒号列表"

# os_desktop_env：多个线索同时命中时按「桌面类型优先级」判定（gnome 优先于 mate）
# 这条口径与 unix_script 的 detect_desktop 逐字一致 —— 门面转发必须等价
export XDG_CURRENT_DESKTOP="mate:gnome"
assert_eq "gnome" "$(os_desktop_env)" "os_desktop_env 冒号列表按类型优先级"

export XDG_CURRENT_DESKTOP="X-Cinnamon"
assert_eq "cinnamon" "$(os_desktop_env)" "os_desktop_env cinnamon"

export XDG_CURRENT_DESKTOP="KDE"
assert_eq "kde" "$(os_desktop_env)" "os_desktop_env kde"

export XDG_CURRENT_DESKTOP="plasma"
assert_eq "kde" "$(os_desktop_env)" "os_desktop_env plasma 归 kde"

export XDG_CURRENT_DESKTOP="ukui"
assert_eq "ukui" "$(os_desktop_env)" "os_desktop_env ukui"

export XDG_CURRENT_DESKTOP="deepin"
assert_eq "dde" "$(os_desktop_env)" "os_desktop_env deepin 归 dde"

export XDG_CURRENT_DESKTOP="LXQt"
assert_eq "lxqt" "$(os_desktop_env)" "os_desktop_env lxqt"

export XDG_CURRENT_DESKTOP="budgie"
assert_eq "budgie" "$(os_desktop_env)" "os_desktop_env budgie"

export XDG_CURRENT_DESKTOP="xfce"
assert_eq "xfce" "$(os_desktop_env)" "os_desktop_env xfce"

unset XDG_CURRENT_DESKTOP
export XDG_SESSION_DESKTOP="mate"
assert_eq "mate" "$(os_desktop_env)" "os_desktop_env XDG_SESSION_DESKTOP"

unset XDG_SESSION_DESKTOP
export DESKTOP_SESSION="startdde"
assert_eq "dde" "$(os_desktop_env)" "os_desktop_env DESKTOP_SESSION"

# os_desktop_env：装了会话二进制也算线索
unset XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP DESKTOP_SESSION
stub gnome-session
assert_eq "gnome" "$(os_desktop_env)" "os_desktop_env 二进制线索"

# os_desktop_env：线索来源不同也按类型优先级 —— 环境变量说 xfce、二进制说 gnome => gnome
export XDG_CURRENT_DESKTOP="xfce"
assert_eq "gnome" "$(os_desktop_env)" "os_desktop_env 跨来源按类型优先级"
unset XDG_CURRENT_DESKTOP
unstub gnome-session

# os_desktop_env：kwin_x11 的名字里既没有 plasma 也没有 kde，单独不构成线索
# （与 unix_script 的 detect_desktop 同口径；真实 KDE 会话必然带 plasmashell / startplasma-x11）
stub kwin_x11
if [ "$__sk_test_bin" = "0" ]; then
  assert_eq "none" "$(os_desktop_env)" "os_desktop_env kwin_x11 单独不算线索"
fi
unstub kwin_x11

# os_desktop_env：什么线索都没有才是 none
if [ "$__sk_test_bin" = "0" ]; then
  assert_eq "none" "$(os_desktop_env)" "os_desktop_env none"
  assert_exit_code 1 os_is_desktop
fi

# os_is_desktop：在桌面环境返回 0
export XDG_CURRENT_DESKTOP="GNOME"
assert_exit_code 0 os_is_desktop
unset XDG_CURRENT_DESKTOP

# --- 提权包管理与 sudo 就绪 -------------------------------------------------
# 这里用真的可执行桩（不是 shell 函数）：实际执行路径是
# `sudo env DEBIAN_FRONTEND=noninteractive apt-get ...`，env 是真二进制，
# 只能找到 PATH 上的真文件 —— shell 函数桩它看不见。
__sk_pb="$d/pkgbin"
mkdir -p "$__sk_pb"
__sk_plog="$d/pkg-argv.log"
export SK_PKG_ARGV_LOG="$__sk_plog"

cat >"$__sk_pb/id" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "-u" ]; then
  printf '%s' "${SK_TEST_UID:-0}"
  exit 0
fi
exec /usr/bin/id "$@"
EOF
cat >"$__sk_pb/sudo" <<'EOF'
#!/bin/sh
printf 'sudo %s\n' "$*" >> "$SK_PKG_ARGV_LOG"
if [ "${SK_SUDO_FAIL:-0}" = "1" ]; then
  exit 1
fi
# 跳过 sudo 自己的选项（-n / -v 等），剩下的才是要执行的命令
while [ $# -gt 0 ]; do
  case "$1" in
    -*) shift ;;
    *) break ;;
  esac
done
exec "$@"
EOF
cat >"$__sk_pb/apt-get" <<'EOF'
#!/bin/sh
printf 'apt-get %s\n' "$*" >> "$SK_PKG_ARGV_LOG"
exit 0
EOF
cat >"$__sk_pb/brew" <<'EOF'
#!/bin/sh
printf 'brew %s\n' "$*" >> "$SK_PKG_ARGV_LOG"
exit 0
EOF
cat >"$__sk_pb/dpkg" <<'EOF'
#!/bin/sh
printf 'dpkg %s\n' "$*" >> "$SK_PKG_ARGV_LOG"
exit 0
EOF
chmod +x "$__sk_pb"/*

__sk_oldpath="$PATH"
# 故意把桩目录放到 PATH 最前：实际执行路径是
# `sudo env DEBIAN_FRONTEND=noninteractive apt-get ...`，env 是真二进制，
# 只认 PATH 上的真文件。
# shellcheck disable=SC2123
PATH="$__sk_pb:$PATH"
hash -r

# os_pkg_manager_full：认得出包管理器（apt-get 桩在 PATH 里）
assert_eq "apt-get" "$(os_pkg_manager_full)" "os_pkg_manager_full 认得 apt-get"

# 提权安装：root 直跑，不带 sudo
export SK_TEST_UID=0
: >"$__sk_plog"
os_pkg_install_root curl
assert_eq "apt-get install -y curl" "$(cat "$__sk_plog")" "os_pkg_install_root root 直跑"

# 提权安装：非 root 走 sudo env DEBIAN_FRONTEND=noninteractive
export SK_TEST_UID=1000
: >"$__sk_plog"
os_pkg_install_root curl
assert_eq "sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y curl
apt-get install -y curl" "$(cat "$__sk_plog")" "os_pkg_install_root 非 root 走 sudo"

# 提权卸载
: >"$__sk_plog"
os_pkg_remove_root curl
assert_eq "sudo env DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y curl
apt-get remove --purge -y curl" "$(cat "$__sk_plog")" "os_pkg_remove_root"

# 刷新索引：apt-get update -y（不带 env 前缀 —— 与 unix_script 的 pkg_update 逐字一致）
: >"$__sk_plog"
os_pkg_update_root
assert_eq "sudo apt-get update -y
apt-get update -y" "$(cat "$__sk_plog")" "os_pkg_update_root"

# brew 不提权
export SK_PKG_MGR_FULL=brew
: >"$__sk_plog"
os_pkg_install_root wget
assert_eq "brew install wget" "$(cat "$__sk_plog")" "brew 不提权"
: >"$__sk_plog"
os_pkg_remove_root wget
assert_eq "brew uninstall wget" "$(cat "$__sk_plog")" "brew 卸载不提权"
unset SK_PKG_MGR_FULL

# dry-run：只打印不执行，包管理器一个都不许被调用
export SHELLKIT_DRY_RUN=1
: >"$__sk_plog"
assert_exit_code 0 os_pkg_install_root curl
assert_eq "" "$(cat "$__sk_plog")" "dry-run 不执行包管理器"
unset SHELLKIT_DRY_RUN

# 参数校验：不给包名是用法错
assert_exit_code 2 os_pkg_install_root
assert_exit_code 2 os_pkg_remove_root
assert_exit_code 2 os_pkg_installed

# os_pkg_installed：走 dpkg -s（不需要提权）
: >"$__sk_plog"
assert_exit_code 0 os_pkg_installed curl
assert_eq "dpkg -s curl" "$(cat "$__sk_plog")" "os_pkg_installed 走 dpkg -s"

# os_sudo_ready：root 直接放行
export SK_TEST_UID=0
assert_exit_code 0 os_sudo_ready

# os_sudo_ready：非 root 但 sudo 免密可用
export SK_TEST_UID=1000
assert_exit_code 0 os_sudo_ready

# os_sudo_ready：sudo 一直失败 => 拿不到权限（3）
export SK_SUDO_FAIL=1
assert_exit_code 3 os_sudo_ready
unset SK_SUDO_FAIL

# shellcheck disable=SC2123
PATH="$__sk_oldpath"
hash -r
