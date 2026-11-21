#!/usr/bin/env bash
# tools/release.sh 的预检不许把 git 的失败静默放过去。
#
# 三条判据（每条都带变异自证）：
#   1. HEAD 解析不出来 ⇒ 退 3（不是 git 的 128），并且带可操作提示；
#   2. git status 失败 ⇒ 退 3 且**不许改工作树**（原来被静默当成「干净」照发版）；
#   3. push 被拒 ⇒ 退 1（docs/RELEASING.md 的退出码表一直这么写，代码却退 git 的 128）。
#
# 为什么用假 git：真 git 没法稳定地「失败」。要复现「HEAD 短暂不可见」只能靠竞态，
# 判据就会变成偶发绿。用 PATH 上的假 git 顶掉真 git，失败是确定的，判据才有牙齿。
#
# 沙箱里放的是 release.sh 的副本：脚本会写 VERSION、CHANGELOG、pot 与文档产物，
# 绝不能让测试跑到真仓库上。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

# ---------------------------------------------------------------------------
# 沙箱
# ---------------------------------------------------------------------------

# _write_fake_git PATH —— 写一个可控的假 git
#
# 行为由环境变量决定：
#   SK_FAKE_BRANCH          当前分支，默认 main
#   SK_FAKE_HEAD_FAIL=1     HEAD 解析不出来（退 128 + git 的原话）
#   SK_FAKE_STATUS_FAIL=1   status 失败（退 128）
#   SK_FAKE_STATUS_DIRTY=1  工作树有改动
#   SK_FAKE_PUSH_FAIL=1     push 被拒（退 128 —— 凭据/网络类失败的真实退出码）
_write_fake_git() {
  cat >"$1" <<'GITEOF'
#!/usr/bin/env bash
set -u
__cmd=${1:-}
shift || true
case "$__cmd" in
rev-parse)
  case "$*" in
  "--show-toplevel")
    # 脚本自己 cd 到了仓库根 ⇒ 这里回 pwd 就是脚本算出来的那个 ROOT（字面一致）
    pwd
    exit 0
    ;;
  "--abbrev-ref HEAD")
    if [ "${SK_FAKE_HEAD_FAIL:-0}" = "1" ]; then
      printf "fatal: ambiguous argument 'HEAD': unknown revision or path not in the working tree.\n" >&2
      exit 128
    fi
    printf '%s\n' "${SK_FAKE_BRANCH:-main}"
    exit 0
    ;;
  "-q --verify"*)
    exit 1
    ;;
  esac
  ;;
status)
  if [ "${SK_FAKE_STATUS_FAIL:-0}" = "1" ]; then
    printf 'fatal: unable to read index\n' >&2
    exit 128
  fi
  if [ "${SK_FAKE_STATUS_DIRTY:-0}" = "1" ]; then
    printf ' M README.md\n'
  fi
  exit 0
  ;;
push)
  if [ "${SK_FAKE_PUSH_FAIL:-0}" = "1" ]; then
  printf "fatal: unable to access 'https://github.com/yi-nology/shellkit/': Could not resolve host\n" >&2
    exit 128
  fi
  exit 0
  ;;
log)
  printf '2026-11-21\n'
  exit 0
  ;;
esac
exit 0
GITEOF
  chmod +x "$1"
}

# _sandbox —— 造一个能跑完整个发版流程的假仓库；打印它的路径
_sandbox() {
  local __d
  __d=$(tmpdir) || return 1
  mkdir -p "$__d/tools" "$__d/po" "$__d/bin" "$__d/site/en/guide" "$__d/site/guide" "$__d/site/en"
  cp "$TEST_ROOT/tools/release.sh" "$__d/tools/release.sh"
  cp "$TEST_ROOT/tools/ver_semver.sh" "$__d/tools/ver_semver.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$__d/tools/check_versions.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$__d/tools/changelog_prev.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$__d/po/messages.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$__d/shellkit"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$__d/bin/make"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$__d/bin/xgettext"
  chmod +x "$__d/tools/check_versions.sh" "$__d/tools/changelog_prev.sh" "$__d/po/messages.sh" \
    "$__d/shellkit" "$__d/bin/make" "$__d/bin/xgettext"
  printf '1.5.0\n' >"$__d/VERSION"
  : >"$__d/README.md"
  : >"$__d/site/index.md"
  : >"$__d/site/en/index.md"
  : >"$__d/site/guide/installation.md"
  : >"$__d/site/en/guide/installation.md"
  _write_fake_git "$__d/bin/git"
  printf '%s\n' "$__d"
}

_RC=0
_OUT=""

# _run_release SANDBOX FLAGS [VAR=VAL ...] —— 跑沙箱里的发版脚本；结果在 _RC / _OUT
_run_release() {
  local __d=$1
  local __flags=$2
  shift 2
  _RC=0
  _OUT=$(cd "$__d" && env PATH="$__d/bin:$PATH" "$@" bash tools/release.sh 1.6.0 $__flags 2>&1) || _RC=$?
  return 0
}

# _mutate FILE OLD NEW —— 把文件里的 OLD 换成 NEW；锚点找不到就当场失败
_mutate() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path, encoding='utf-8').read()
if old not in s:
    sys.stderr.write('mutation anchor not found:\n' + old + '\n')
    sys.exit(1)
open(path, 'w', encoding='utf-8').write(s.replace(old, new, 1))
PY
}

# _version SANDBOX —— 沙箱里 VERSION 的内容（去掉空白）
_version() {
  tr -d '[:space:]' <"$1/VERSION"
}

# ---------------------------------------------------------------------------
# 判据 1：HEAD 解析不出来 ⇒ 退 3 + 可操作提示 + 不许动工作树
# ---------------------------------------------------------------------------
d=$(_sandbox)
_run_release "$d" --no-push SK_FAKE_HEAD_FAIL=1
assert_eq "3" "$_RC" "an unresolvable HEAD must exit 3, not git's 128"
assert_contains "$_OUT" "git rev-parse --abbrev-ref HEAD" "the failing git command must be named"
assert_contains "$_OUT" "not in a releasable state" "the operator must be told what to do"
assert_contains "$_OUT" "ambiguous argument" "git's own message must be kept"
assert_eq "1.5.0" "$(_version "$d")" "the tree must not be touched when the preflight fails"

# ---------------------------------------------------------------------------
# 判据 2：git status 失败 ⇒ 退 3（原来被静默当成「工作树干净」照发版）
# ---------------------------------------------------------------------------
d=$(_sandbox)
_run_release "$d" --no-push SK_FAKE_STATUS_FAIL=1
assert_eq "3" "$_RC" "a failing git status must stop the release"
assert_contains "$_OUT" "git status --porcelain" "the failing git command must be named"
assert_eq "1.5.0" "$(_version "$d")" "the tree must not be touched when the preflight fails"

# ---------------------------------------------------------------------------
# 判据 3：push 被拒 ⇒ 退 1（文档的退出码表一直这么写）
# ---------------------------------------------------------------------------
d=$(_sandbox)
_run_release "$d" '' SK_FAKE_PUSH_FAIL=1
assert_eq "1" "$_RC" "a rejected push must exit 1 (docs/RELEASING.md), not git's 128"
assert_contains "$_OUT" "git push origin" "the failing git command must be named"

# ---------------------------------------------------------------------------
# 对照：正常路径没被改坏
# ---------------------------------------------------------------------------
d=$(_sandbox)
_run_release "$d" ''
assert_eq "0" "$_RC" "a clean sandbox must release successfully"
assert_contains "$_OUT" "released 1.6.0" "the release must reach the end"
assert_eq "1.6.0" "$(_version "$d")" "VERSION must be bumped"

d=$(_sandbox)
_run_release "$d" --no-push SK_FAKE_STATUS_DIRTY=1
assert_eq "3" "$_RC" "a dirty tree must still stop the release"
assert_contains "$_OUT" "working tree is dirty" "the dirty tree must be named"

d=$(_sandbox)
_run_release "$d" --no-push SK_FAKE_BRANCH=feature/x
assert_eq "3" "$_RC" "the wrong branch must still stop the release"
assert_contains "$_OUT" "release runs on main" "the branch mismatch must be named"

# ---------------------------------------------------------------------------
# 变异自证：把三处修复分别改回去，判据必须变红（这里断言「旧行为确实不同」）
# ---------------------------------------------------------------------------
d=$(_sandbox)
_mutate "$d/tools/release.sh" \
  'if ! HEAD_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>"$_GIT_ERR"); then
  _git_fail "git rev-parse --abbrev-ref HEAD" 3
fi' \
  'HEAD_BRANCH="$(git rev-parse --abbrev-ref HEAD)"'
_run_release "$d" --no-push SK_FAKE_HEAD_FAIL=1
assert_eq "128" "$_RC" "the old behaviour leaked git's 128 (the check must have teeth)"

d=$(_sandbox)
_mutate "$d/tools/release.sh" \
  'if ! STATUS_OUT=$(git status --porcelain 2>"$_GIT_ERR"); then
  _git_fail "git status --porcelain" 3
fi
if [ -n "$STATUS_OUT" ]; then
  _die "working tree is dirty; commit or stash first (git status --short)" 3
fi' \
  'if [ -n "$(git status --porcelain)" ]; then
  _die "working tree is dirty; commit or stash first (git status --short)" 3
fi'
_run_release "$d" --no-push SK_FAKE_STATUS_FAIL=1
assert_ne "3" "$_RC" "the old behaviour silently treated a broken status as a clean tree"
assert_eq "1.6.0" "$(_version "$d")" "the old behaviour went on and bumped VERSION"

d=$(_sandbox)
_mutate "$d/tools/release.sh" \
  '  git push origin "HEAD:$BRANCH" 2>"$_GIT_ERR" || _git_fail "git push origin HEAD:$BRANCH" 1' \
  '  git push origin "HEAD:$BRANCH"'
_run_release "$d" '' SK_FAKE_PUSH_FAIL=1
assert_eq "128" "$_RC" "the old behaviour leaked git's 128 on push (the check must have teeth)"

exit 0
