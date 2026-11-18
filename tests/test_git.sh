#!/usr/bin/env bash
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"

if ! command -v git >/dev/null 2>&1; then
  printf 'SKIP: git is not installed\n' >&2
  exit 0
fi

d=$(tmpdir)
origin="$d/origin.git"
work="$d/work"

# 本地裸仓当 origin：全程离线（file:// 与本地路径都不出网）
git init -q --bare "$origin" || _fail "cannot create the bare origin"
# 显式指定裸仓的 HEAD —— 不依赖本机的 init.defaultBranch（CI 与本机可能不同）
git --git-dir="$origin" symbolic-ref HEAD refs/heads/main || _fail "cannot set the origin HEAD"
git clone -q "$origin" "$work" 2>/dev/null || _fail "cannot clone the origin"
cd "$work" || _fail "cannot enter the work tree"
git config user.email "probe@example.com"
git config user.name "probe"
printf 'one\n' >a.txt
git add a.txt
git commit -qm "init" || _fail "cannot commit"
git push -q origin HEAD:refs/heads/main || _fail "cannot push"
git remote set-head origin main >/dev/null 2>&1 || true
git tag v1.0.0
git push -q --tags origin || _fail "cannot push the tags"
cd "$TEST_ROOT" || exit 1

# ---- 默认分支：origin/HEAD ----
assert_eq "main" "$(git_default_branch "$work")" "the default branch comes from origin/HEAD"

# ---- 默认分支：只有 origin/master 的老仓 ----
old="$d/old"
git clone -q "$origin" "$old" 2>/dev/null || _fail "cannot clone for the old-style case"
cd "$old" || exit 1
git fetch -q origin main || _fail "cannot fetch main"
git checkout -q -B master FETCH_HEAD || _fail "cannot create the master branch"
git push -q origin master:refs/heads/master || _fail "cannot push master"
# 远端跟踪引用也要有（否则本地根本看不到 origin/master 这个分支）
git fetch -q origin master:refs/remotes/origin/master || _fail "cannot fetch master"
git symbolic-ref -d refs/remotes/origin/HEAD || true
git update-ref -d refs/remotes/origin/main || true
cd "$TEST_ROOT" || exit 1
assert_eq "master" "$(git_default_branch "$old")" "a repo without origin/HEAD falls back to origin/master"

# ---- 默认分支：多个远端分支且认不出 ⇒ 报歧义，不猜 ----
amb="$d/amb"
git clone -q "$origin" "$amb" 2>/dev/null || _fail "cannot clone for the ambiguous case"
cd "$amb" || exit 1
git symbolic-ref -d refs/remotes/origin/HEAD || true
git update-ref -d refs/remotes/origin/main || true
git update-ref -d refs/remotes/origin/master || true
git update-ref refs/remotes/origin/feature-x HEAD
git update-ref refs/remotes/origin/feature-y HEAD
cd "$TEST_ROOT" || exit 1
out=$(git_default_branch "$amb" 2>&1) && rc=0 || rc=$?
assert_eq 3 "$rc" "an ambiguous default branch is an error, not a guess"
assert_contains "$out" "ambiguous" "the refusal says the branch is ambiguous"

# ---- 不是 git 仓 ⇒ 前置条件不满足 ----
notrepo="$d/notrepo"
mkdir -p "$notrepo"
assert_exit_code 3 git_default_branch "$notrepo"
assert_exit_code 3 git_is_dirty "$notrepo"
assert_exit_code 3 git_tag "$notrepo"
assert_exit_code 3 git_fetch "$notrepo" main
assert_exit_code 3 git_fast_forward "$notrepo" main
assert_exit_code 3 git_reset_hard "$notrepo" HEAD
assert_exit_code 3 git_worktree_add "$notrepo" "$d/wt" probe

# ---- 脏仓守卫：干净 0 / 有改动 1 / 未跟踪也算脏 ----
assert_exit_code 0 git_is_dirty "$work"
printf 'two\n' >>"$work/a.txt"
assert_exit_code 1 git_is_dirty "$work"
cd "$work" || exit 1
git checkout -q -- a.txt
cd "$TEST_ROOT" || exit 1
printf 'new\n' >"$work/untracked.txt"
assert_exit_code 1 git_is_dirty "$work"
rm -f "$work/untracked.txt"
assert_exit_code 0 git_is_dirty "$work"

# ---- 脏仓时拒绝取数与快进（不能无声冲掉别人的改动）----
printf 'dirty\n' >>"$work/a.txt"
assert_exit_code 3 git_fetch "$work" main
assert_exit_code 3 git_fast_forward "$work" main
cd "$work" || exit 1
git checkout -q -- a.txt
cd "$TEST_ROOT" || exit 1

# ---- 取数 ----
assert_exit_code 0 git_fetch "$work" main

# ---- 快进 ----
cd "$work" || exit 1
git checkout -q main
cd "$TEST_ROOT" || exit 1
assert_exit_code 0 git_fast_forward "$work" main

# ---- 不能快进时：明确报错，且**本地提交不丢**----
# 真正的分叉：本地有提交、远端也有别人的提交 —— 两边都动过，快进必然失败
cd "$work" || exit 1
git checkout -q -b diverge
printf 'local\n' >local.txt
git add local.txt
git commit -qm "local work"
git push -q origin diverge:refs/heads/diverge || _fail "cannot push the diverge branch"
cd "$TEST_ROOT" || exit 1
other="$d/other"
git clone -q "$origin" "$other" 2>/dev/null || _fail "cannot clone for the divergence"
cd "$other" || exit 1
git fetch -q origin diverge
# 从**基线**分叉（不是从 local work 之上）：两边各有一个提交才是真分叉
git checkout -q -B diverge origin/main
printf 'remote\n' >remote.txt
git add remote.txt
git commit -qm "remote work"
git push -q --force origin diverge:refs/heads/diverge || _fail "cannot push the remote work"
cd "$TEST_ROOT" || exit 1
cd "$work" || exit 1
git fetch -q origin
cd "$TEST_ROOT" || exit 1
out=$(git_fast_forward "$work" diverge 2>&1) && rc=0 || rc=$?
assert_eq 3 "$rc" "a diverged branch cannot fast-forward"
assert_contains "$out" "fast-forward" "the refusal says it is about fast-forwarding"
cd "$work" || exit 1
# 纯 bash 判断（不接管道：grep -q 命中即退会把上游 SIGPIPE 打死，坑 5）
case "$(git log --oneline diverge)" in
  *"local work"*) ;;
  *) _fail "the local commit survives a refused fast-forward" ;;
esac
cd "$TEST_ROOT" || exit 1

# ---- 显式的破坏性重置：丢本地提交（这是它该干的事）----
assert_exit_code 0 git_reset_hard "$work" main
cd "$work" || exit 1
case "$(git log --oneline diverge)" in
  *"local work"*) _fail "git_reset_hard discards the local commit" ;;
esac
cd "$TEST_ROOT" || exit 1

# ---- 取 tag ----
assert_eq "v1.0.0" "$(git_tag "$work")" "the tag of HEAD is reported"

# ---- 浅克隆：tag 跟不下来 ⇒ 补取后拿得到（版本不能退化成 (devel)）----
shallow="$d/shallow"
git clone -q --depth 1 "file://$origin" "$shallow" 2>/dev/null || _fail "cannot make a shallow clone"
got=$(git_tag "$shallow" 2>/dev/null || true)
if [ "$got" != "v1.0.0" ]; then
  _fail "a shallow clone still reports the tag (got: ${got:-none})"
fi

# ---- 浅克隆 + tag 指向**祖先**提交 ⇒ 只补 tag 不够，必须把祖先链接回来 ----
#
# 上一个场景的 tag 就在 HEAD 上 ⇒ clone 时 git 会自动把它带下来，
# 于是「补取」这条分支根本没被走到（判据没有承重）。
# 这里让 tag 落在祖先提交上：浅克隆拿不到 tag，补取后 describe 仍认不出
# （浅边界把祖先链截断了）—— 只有把边界推回去才拿得到。
#
# 场景仓：第一个提交打 tag，第二个提交是 HEAD（HEAD 自己没有 tag）
origin2="$d/origin2.git"
git init -q --bare "$origin2" || _fail "cannot create the second bare origin"
git --git-dir="$origin2" symbolic-ref HEAD refs/heads/main || _fail "cannot set the second origin HEAD"
src2="$d/src2"
git clone -q "$origin2" "$src2" 2>/dev/null || _fail "cannot clone the second origin"
cd "$src2" || _fail "cannot enter the second work tree"
git config user.email "probe@example.com"
git config user.name "probe"
printf 'one\n' >a.txt
git add a.txt
git commit -qm "tagged" || _fail "cannot commit the tagged commit"
git tag v2.0.0
printf 'two\n' >b.txt
git add b.txt
git commit -qm "untagged head" || _fail "cannot commit the head commit"
git push -q origin HEAD:refs/heads/main || _fail "cannot push the second origin"
git push -q --tags origin || _fail "cannot push the second tags"
cd "$TEST_ROOT" || exit 1

shallow2="$d/shallow2"
git clone -q --depth 1 "file://$origin2" "$shallow2" 2>/dev/null || _fail "cannot make the second shallow clone"
# 前提：这个浅克隆里确实没有 tag（否则这条用例测不到补取分支）
if [ -n "$(git -C "$shallow2" tag -l)" ]; then
  _fail "the shallow clone must not have the tag (otherwise the case proves nothing)"
fi
got=$(git_tag "$shallow2" 2>/dev/null || true)
if [ "$got" != "v2.0.0" ]; then
  _fail "a shallow clone with the tag on an ancestor still reports the tag (got: ${got:-none})"
fi

# ---- worktree 检出 ----
wt="$d/wt"
assert_exit_code 0 git_worktree_add "$work" "$wt" feature-x
if [ ! -f "$wt/a.txt" ]; then
  _fail "the worktree is checked out"
fi
cd "$TEST_ROOT" || exit 1

# ---- 参数校验 ----
assert_exit_code 2 git_fetch "$work"
assert_exit_code 2 git_fast_forward "$work"
assert_exit_code 2 git_reset_hard "$work"
assert_exit_code 2 git_worktree_add "$work" "$d/wt2"
