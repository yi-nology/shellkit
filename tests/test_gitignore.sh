#!/usr/bin/env bash
#
# 仓库卫生：.gitignore 必须挡住凭据文件。
#
# 为什么要有这条用例：门禁 tools/check_security.sh 的 secret.tracked 查的是
# 「**已经入库**的秘密」—— 它拦不住「还没入库的」。真正决定 .env / 私钥会不会
# 被 `git add` 带进去的是忽略规则，而忽略规则本身没有判据：
# 有人把一行 .env 从 .gitignore 里删掉，全套门禁照样绿。
#
# 做法：把仓库的 .gitignore 拷进一个一次性 git 仓库再问 git 自己 ——
# 不自己解析模式语法（那是重新实现 git），也不要求被测树带 .git
# （覆盖率跑在无 .git 的副本里，见 tools/coverage.sh）。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

if ! command -v git >/dev/null 2>&1; then
  printf 'git is not installed; skipping .gitignore checks\n'
  exit 0
fi

work=$(tmpdir)

# check_ignored GITIGNORE_FIXTURE PATH —— 该路径在这个忽略规则下会被忽略吗
# 返回 0 = 被忽略，1 = 不被忽略。
check_ignored() {
  local __rules=$1 __path=$2 __repo
  __repo="$work/repo.$$.$RANDOM"
  mkdir -p "$__repo" || return 1
  cp "$__rules" "$__repo/.gitignore" || return 1
  (
    cd "$__repo" || exit 1
    git init -q . >/dev/null 2>&1 || exit 1
    git check-ignore -q -- "$__path"
  )
}

# CASE: 凭据文件名必须被忽略（正控）
#
# 每一条都对应一次真实的「差点入库」：.env 存令牌、*.pem 是证书私钥、
# *.key 是 Minisign 私钥、id_rsa 是 ssh 私钥。
for p in .env .env.production deploy.pem server.key id_rsa id_ed25519 dist/shellkit.tar.gz; do
  if ! check_ignored "$TEST_ROOT/.gitignore" "$p"; then
    _fail ".gitignore 必须忽略凭据/产物路径：$p"
  fi
done

# CASE: 负控 —— 不该被忽略的必须不被忽略
#
# .env.example 是模板（要入库）；README.md 是普通文件。
# 有这一条才能证明上面的断言不是「什么都忽略」的白送。
for p in .env.example README.md; do
  if check_ignored "$TEST_ROOT/.gitignore" "$p"; then
    _fail ".gitignore 不该忽略：$p"
  fi
done

# CASE: 判据自身可证伪 —— 删掉一行规则，同一个探针必须变红
#
# 这是「自检」：把缺陷造回去，判据必须失效。否则上面两条可能是恒真的。
mutant="$work/gitignore.mutant"
grep -v '^\.env$' "$TEST_ROOT/.gitignore" >"$mutant" || _fail "cannot build the mutant ignore file"
if check_ignored "$mutant" .env; then
  _fail "判据没有判据能力：把 .env 规则删掉之后 .env 仍被判为已忽略"
fi

exit 0
