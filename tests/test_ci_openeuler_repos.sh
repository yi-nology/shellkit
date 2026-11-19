#!/usr/bin/env bash
#
# 结构判据：CI 的 compat job 装包时，openEuler 必须**只留必要源**。
#
# 为什么（2026-11-19 v1.3.0 发版现场）：
# openEuler 的镜像默认开 8 个源（OS/everything/EPOL/EPOL-update/update/
# update-source/source/debuginfo），dnf 为了解析依赖会把**每个**启用源的
# repodata 都拉下来。逐源实测的 metadata 体积：update 184 MB、everything
# 41 MB、EPOL 11 MB、debuginfo 10 MB ⇒ 合计约 268 MB。共享 runner 在美国、
# 镜像站在国内 ⇒ 实测装包 27~45 分钟，撞 2700 秒内层超时 ⇒ 偶发判失败
# （发版现场连撞 3 次，最后一次重跑才绿）。
#
# 实测：只留 OS/everything/EPOL/EPOL-update 四个源就够（bash/gettext/make/
# python3/git/msgfmt/tar/xz/sha256sum 全部到位），metadata 降到 60 MB（-78%）。
#
# 判据形状（四条，缺一不可）：
#   1. update / update-source / source / debuginfo 四个重源必须被禁；
#   2. 禁用必须**由同一条 openEuler 判定护住** —— Rocky 的源 ID 完全不同，
#      拿 openEuler 的经验去改它等于把一个发行版的假设套到另一个身上；
#   3. weak deps / nodocs 两个选项必须在（装包不该顺手装成一台开发机）。
#
# 判据只认真代码行：注释里提到 openEuler 或某个源名不算数 ——
# 否则「把判定删掉、注释留着」就能骗过它（判据自己得先防住这一手）。
#
# 全文纯 bash 扫描，不写 `grep | head`（pipe-safety 门禁会判 SIGPIPE 风险）。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

CI_YML="$TEST_ROOT/.github/workflows/ci.yml"

# _repo_trim_violations FILE —— 打印不合规之处（空输出 = 合格）
_repo_trim_violations() {
  local __f=$1 __line __t __trim __bs='\'
  local __u=0 __us=0 __s=0 __dbg=0 __weak=0 __nodocs=0 __guard=0
  local __in_install=0

  while IFS= read -r __line || [ -n "$__line" ]; do
    case $__line in
      *'- name: install tooling'*)
        __in_install=1
        continue
        ;;
    esac
    [ "$__in_install" = 1 ] || continue
    # 下一个 step ⇒ 已经出了 install tooling 这一段
    case $__line in
      *'- name:'*)
        __in_install=0
        continue
        ;;
    esac
    # 注释行不算数（判据只认真代码行）
    __trim=$__line
    while [ "${__trim# }" != "$__trim" ]; do __trim=${__trim# }; done
    case $__trim in
      '#'*) continue ;;
    esac
    # 去掉续行反斜杠及其后内容，再去尾随空格 ⇒ 得到一个干净的「参数」
    __t=$__trim
    case $__t in
      *"${__bs}"*) __t=${__t%"${__bs}"*} ;;
    esac
    while [ "${__t% }" != "$__t" ]; do __t=${__t% }; done

    # openEuler 判定：同一条**代码**行里既有 /etc/os-release 又有 openEuler
    case $__t in
      *'/etc/os-release'*'openEuler'*) __guard=1 ;;
    esac
    # 四个重源（模式锚在行尾 ⇒ --disablerepo=update 不会误匹配 update-source）
    case $__t in
      *'--disablerepo=update') __u=1 ;;
    esac
    case $__t in
      *'--disablerepo=update-source') __us=1 ;;
    esac
    case $__t in
      *'--disablerepo=source') __s=1 ;;
    esac
    case $__t in
      *'--disablerepo=debuginfo') __dbg=1 ;;
    esac
    case $__t in
      *'--setopt=install_weak_deps=False'*) __weak=1 ;;
    esac
    case $__t in
      *'--setopt=tsflags=nodocs'*) __nodocs=1 ;;
    esac
  done <"$__f"

  [ "$__u" = 1 ] || printf '%s: the openEuler install does not disable the update repo (184 MB of metadata alone)\n' "$__f"
  [ "$__us" = 1 ] || printf '%s: the openEuler install does not disable the update-source repo\n' "$__f"
  [ "$__s" = 1 ] || printf '%s: the openEuler install does not disable the source repo\n' "$__f"
  [ "$__dbg" = 1 ] || printf '%s: the openEuler install does not disable the debuginfo repo\n' "$__f"
  [ "$__weak" = 1 ] || printf '%s: the dnf install does not turn off weak dependencies\n' "$__f"
  [ "$__nodocs" = 1 ] || printf '%s: the dnf install does not turn off docs\n' "$__f"
  if [ "$__guard" = 0 ]; then
    printf '%s: the repo trimming is not guarded by an openEuler check — it would change Rocky too\n' "$__f"
  fi
  return 0
}

if [ ! -f "$CI_YML" ]; then
  printf 'NA: .github/workflows/ci.yml is not in this tree — the openEuler repo check is skipped\n'
  exit 0
fi

out=$(_repo_trim_violations "$CI_YML")
assert_eq "" "$out" "the compat install must trim the openEuler repos and must not touch other distros"

d=$(tmpdir)

# 自证一：少禁一个重源 ⇒ 判据必须报出来
sed 's|--disablerepo=update \\|--disablerepo=xx \\|' "$CI_YML" >"$d/ci-one-repo.yml"
assert_contains "$(_repo_trim_violations "$d/ci-one-repo.yml")" "does not disable the update repo" \
  "dropping one heavy repo must break the check"

# 自证二：把 openEuler 判定改成别的发行版 ⇒ 禁用不再只对 openEuler 生效
sed 's|openEuler|Rocky|' "$CI_YML" >"$d/ci-wrong-distro.yml"
assert_contains "$(_repo_trim_violations "$d/ci-wrong-distro.yml")" "not guarded by an openEuler check" \
  "a trimming that is not guarded by openEuler must break the check"

# 自证三：去掉 openEuler 判定本身（禁用行会跑到所有 dnf 发行版头上）
sed 's|/etc/os-release|/etc/hostname|' "$CI_YML" >"$d/ci-no-guard.yml"
assert_contains "$(_repo_trim_violations "$d/ci-no-guard.yml")" "not guarded by an openEuler check" \
  "removing the distro check must break the check"

# 自证四：真代码判定被删、只留注释 ⇒ 判据仍必须报出来
sed 's|grep -q .\^ID=.*openEuler. /etc/os-release|true|' "$CI_YML" >"$d/ci-guard-gone.yml"
assert_contains "$(_repo_trim_violations "$d/ci-guard-gone.yml")" "not guarded by an openEuler check" \
  "a guard that only survives in comments must break the check"

# 自证五：弱依赖没关 ⇒ 判据必须报出来
sed 's|--setopt=install_weak_deps=False||' "$CI_YML" >"$d/ci-weak.yml"
assert_contains "$(_repo_trim_violations "$d/ci-weak.yml")" "does not turn off weak dependencies" \
  "leaving weak dependencies on must break the check"

# 自证六：文档没关 ⇒ 判据必须报出来
sed 's|--setopt=tsflags=nodocs||' "$CI_YML" >"$d/ci-docs.yml"
assert_contains "$(_repo_trim_violations "$d/ci-docs.yml")" "does not turn off docs" \
  "leaving docs on must break the check"

exit 0
