# shellkit 开发入口。CI 与本地跑的是同一组门。

SHELL := /bin/bash
# 测试与静态检查用哪个 bash。macOS 的基线是 3.2（/bin/bash），但 PATH 上可能有
# 别的版本 —— CI 里显式写 BASH=/bin/bash 才是真的在验 3.2。
BASH ?= bash
SOURCES := shellkit install.sh repair.sh demo.sh lib/bootstrap.sh $(wildcard lib/core/*.sh) \
  $(wildcard tools/*.sh) tests/*.sh po/messages.sh
TEMPLATES := $(shell find templates -type f)
SHOTS := $(wildcard docs/shots/*.shot)

.PHONY: help test syntax lint lint-templates fmt messages messages-check docs docs-check versions-check check-docs cookbook-check shots examples artifact-smoke check install release release-dry site-deps site-sync site site-serve local-names-check module-count-check pipe-safety-check dup-functions-check mutation security-check api-baseline-check api-freeze-check compatibility-check bench coverage coverage-branch upgrade-matrix ident-boundary-check

help:
	@printf '%s\n' \
	  'make test        跑全部测试（tests/run.sh）' \
	  'make syntax      bash -n 全部脚本' \
	  'make lint        shellcheck -S warning -x' \
	  'make module-order-check  模块加载顺序（调用了还没加载的函数就红）' \
	  'make check-exitcode-docs  公开函数的返回码必须写在注释里' \
	  'make local-names-check  库内部命名空间与出参保留名校验' \
	  'make module-count-check  文档里的模块数必须与 lib/modules.txt 一致' \
	  'make pipe-safety-check  管道里不能有会提前退出的消费者（SIGPIPE + pipefail 会误判失败）' \
	  'make fmt         shfmt -d -i 2 -ci（只检查）' \
	  'make messages    重新抽取 msgid 并编译 .mo' \
	  'make messages-check  只检查 pot 与源码是否一致（缺 xgettext 时跳过）' \
	  'make docs        重新生成 REFERENCE.md / AGENTS.md / SKILL.md' \
	  'make versions-check  VERSION / pot 头 / README / 站点里的版本号是否一致' \
  'make check-docs      markdown 的 bash 代码块必须 bash -n 通过；函数名必须真实存在' \
  'make cookbook-check  文档里说的场景数要与 Cookbook 实际场景数一致' \
	  'make shots       按 docs/shots/*.shot 真跑命令并渲染 SVG 截图' \
	  'make examples    跑 examples/ 下每个工程的测试' \
	  'make check       依次跑 syntax / test / lint / module-order-check / check-exitcode-docs / local-names-check / module-count-check / pipe-safety-check / docs-check / versions-check / check-docs / cookbook-check / messages-check / examples / fmt' \
	  'make bats-check  跑 bats 用例（tests/bats，每个 @test 一个独立进程）' \
	  'make coverage    公开函数级覆盖率（带白名单棘轮，不进 check）' \
	  'make coverage-branch  分支级覆盖率（if/case/|| 各臂棘轮 + P0 守卫分支，不进 check）' \
	  'make mutation    变异测试：升级路径守卫用例的判据能力（不进 check）' \
  'make security-check  安全边界的机器判据（路径/软链/权限/脱敏/锁/原子写）' \
  'make api-baseline-check  公开 API 行为基线（返回码或函数集变了就红）' \
  'make api-freeze-check  API 冻结清单与源码一致（stable 集合 / 返回码 / CLI 形状）' \
  'make compatibility-check  兼容承诺文档与源码一致（分级齐全、豁免名单为空、数量对账）' \
  'make bench        性能基准：记录与对比基线（不进 check，CI 里只出报告）' \
	  'make release VERSION=x.y.z  发版：升版本→重生成产物→门禁→commit→tag→push' \
	  'make release-dry VERSION=x.y.z  同 release，但跑完还原工作树、不提交' \
	  'make site        构建文档站（先跑 tools/site_sync.sh 从 docs/ 同步）' \
	  'make site-serve  本地起文档站的开发服务器' \
	  'make site-deps   装文档站的 node 依赖'


test:
	@$(BASH) tests/run.sh

syntax:
	@fail=0; for f in $(SOURCES) $(TEMPLATES); do \
	  case "$$f" in *.sh|shellkit|*/__NAME__|*/__CMD__) $(BASH) -n "$$f" || fail=1 ;; esac; \
	  done; exit $$fail

lint:
	@if command -v shellcheck >/dev/null 2>&1; then \
	  shellcheck -S warning -x $(SOURCES); \
	  else echo "shellcheck not installed, skipping"; fi
	@$(MAKE) --no-print-directory lint-templates

# 模板里有 {{NAME}} 这类占位符，直接检查会被当成语法错误；先渲染再检查。
lint-templates:
	@$(BASH) tests/lint_templates.sh

fmt:
	@if command -v shfmt >/dev/null 2>&1; then \
	  shfmt -d -i 2 -ci $(SOURCES); \
	  else echo "shfmt not installed, skipping"; fi

messages:
	@$(BASH) po/messages.sh

# 缺 xgettext 的机器上 po/messages.sh --check 自己会跳过，不会误伤 macOS
messages-check:
	@$(BASH) po/messages.sh --check

docs:
	@./shellkit docs

docs-check:
	@./shellkit docs --check

# VERSION 是唯一真相源，pot 头与两处钉版本引用都是它的投影
versions-check:
	@$(BASH) tools/check_versions.sh

# 文档里的代码块必须能过 bash -n，函数名必须真实存在
check-docs:
	@$(BASH) tools/check_docs.sh

# 文档里手写的「N 个场景」必须与 Cookbook 里的实际场景数一致
cookbook-check:
	@$(BASH) tools/check_cookbook_count.sh

# 截图是真实输出渲染的，需要用 python3；没有就跳过而不是失败
shots:
	@if command -v python3 >/dev/null 2>&1; then \
	  python3 tools/term_shot.py $(SHOTS); \
	  else echo "python3 not installed, skipping screenshots"; fi

# bats 用例：真正独立的测试用例（每个 @test 一个进程、互不干扰）。
# 不进 check —— bats 是外部依赖，没装的机器不该被卡住；
# CI 里有专门的 job 装好 bats 再跑它。
bats-check:
	@if command -v bats >/dev/null 2>&1; then \
	  bats tests/bats; \
	else \
	  echo "bats is not installed: brew install bats-core / npm i -g bats" >&2; \
	  exit 3; \
	fi

# 覆盖率：函数级（162 个公开函数谁没被测到），带白名单棘轮。
# 不进 check —— 它要把整套测试跑两遍，太慢；想收紧覆盖率就调 --min。
artifact-smoke:
	@bash tools/package_tarball.sh
	@bash tools/package_artifact_smoke.sh

upgrade-matrix:
	@bash tools/upgrade_matrix.sh

coverage:
	@bash tools/coverage.sh --min 40

# 分支级棘轮：四条关键路径与 release gate 的 if/case/|| 分支臂。
# 与函数级分开跑：两种插桩各跑一遍全套件，合成一条命令会让失败归因变糊。
coverage-branch:
	@bash tools/coverage.sh --branch

# 变异测试：把语义变异种进路径守卫区，验证守卫用例必须 100% 杀灭
# （位点区间锚在库里的 _sk_fs_rel_safe / _sk_fs_in_dir 上，升级路径调的就是这份）。
# 白名单只剩三条「当前真的没有判据」的位点，行号用**内容锚点**现算 ——
# 「锚点 + 偏移」会随函数内容漂移，把白名单悄悄挪到有判据的位点上。
# 报告与 stdout 会写清四层口径（枚举/窗口/计分/跳过），不把跳过藏起来。
# 不进 check —— 它要把守卫用例跑十几遍；回归在 tests/test_mutation.sh。
mutation:
	@first=$$(grep -n '^_sk_fs_rel_safe()' lib/core/fs.sh | cut -d: -f1); \
	last=$$(grep -n '^_sk_fs_no_symlink_below()' lib/core/fs.sh | cut -d: -f1); \
	[ -n "$$first" ] && [ -n "$$last" ] || { echo 'mutation: guard anchors are gone — update this target' >&2; exit 3; }; \
	root=$$(awk -v s="$$first" -v e="$$last" 'NR > s && NR < e && /\[ "\$$__parent" = "\$$__dir" \]/ { print NR; exit }' lib/core/fs.sh); \
	pwdline=$$(awk -v s="$$first" -v e="$$last" 'NR > s && NR < e && /pwd -P\)/ { print NR; exit }' lib/core/fs.sh); \
	[ -n "$$root" ] && [ -n "$$pwdline" ] || { echo 'mutation: whitelist anchors are gone — update this target' >&2; exit 3; }; \
	bash tools/mutation.sh --target lib/core/fs.sh \
	  --from-line "$$first" --to-line "$$last" --max-sites 13 \
	  --skip "$$root" --skip "$$((root + 1))" --skip "$$pwdline:return" \
	  --test "bash tests/test_upgrade_guard.sh" --min-score 100

# ---------- 文档站 ----------
# 刻意不进 check：库的门禁不依赖 Node，没装 npm 的机器上也该能全绿。
# CI 里站点是独立 job（.github/workflows/ci.yml），发站是 .github/workflows/pages.yml。

site-deps:
	@cd site && npm install --no-audit --no-fund

# docs/ 是唯一真相源；site/ 里的 cookbook / 迁移 / 发版 / 参考页都是它的生成物
site-sync:
	@$(BASH) tools/site_sync.sh

# prebuild 已经会先跑 site-sync，所以这一条就够；做完再查产物上的内部链接
site:
	@cd site && npm run build
	@bash tools/site_links.sh site/.vuepress/dist

site-serve:
	@cd site && npm run dev

examples:
	@for d in examples/*/; do \
	  [ -f "$$d/Makefile" ] || continue; \
	  echo "==> $$d"; \
	  $(MAKE) -C "$$d" test || exit 1; \
	  done

# 模块加载顺序：某个模块调用了还没加载的模块的函数，门禁要红
module-order-check:
	@$(BASH) tools/check_module_order.sh

# 公开函数必须写明返回码 —— 返回码是接口的一部分
check-exitcode-docs:
	@$(BASH) tools/check_exitcode_docs.sh

# 库内部局部变量必须 __ 前缀；公开出参函数必须拒绝保留名
local-names-check:
	@$(BASH) tools/check_local_names.sh

# 标识符边界：$ident 紧跟非 ASCII 会在 bash 3.2 + UTF-8 locale 下把首字节吃进
# 变量名（set -u 直接 unbound 退出 1）—— 只在 macOS CI 上爆，本机与 Linux 都看不见
ident-boundary-check:
	@$(BASH) tools/check_ident_boundary.sh

# 文档里手抄的模块数必须与 lib/modules.txt 一致
module-count-check:
	@$(BASH) tools/check_module_count.sh

# 同一个文件里不能有重复的函数定义（bash 后定义覆盖先定义，前面的悄悄失效）
dup-functions-check:
	@bash tools/check_dup_functions.sh

# 管道里不能有会提前退出的消费者：grep -q / head 会把上游 SIGPIPE 打死（141），
# 调用方开了 pipefail 时整条管道判失败 —— 而且是竞态，本机常绿、CI 必炸
pipe-safety-check:
	@$(BASH) tools/check_pipe_safety.sh

# 安全边界：路径守卫、软链、权限、密钥脱敏、单实例锁、原子写 —— 十条机器判据
# （规范见 docs/SECURITY.md）
security-check:
	@$(BASH) tools/check_security.sh

# 公开 API 行为基线：函数集、承诺返回码、探针实测返回码。
# 改了公开函数的返回码却没在 docs/MIGRATING.md 里声明 ⇒ 这里红。
compatibility-check:
	@$(BASH) tools/check_compatibility.sh

api-freeze-check:
	@$(BASH) tools/api_freeze.sh --check

api-baseline-check:
	@$(BASH) tools/api_baseline.sh

# 性能基准：跑一遍基准并与基线对比。刻意不进 check —— 基准是观察量不是判据，
# 机器快慢差几倍很正常，拿它当门禁只会变成随机红灯。
bench:
	@$(BASH) tools/bench.sh

check: syntax test lint module-order-check check-exitcode-docs local-names-check ident-boundary-check module-count-check pipe-safety-check dup-functions-check security-check api-baseline-check api-freeze-check compatibility-check docs-check versions-check check-docs cookbook-check messages-check examples fmt

install:
	./shellkit install-self --prefix $(PREFIX)/usr

# VERSION 由调用方传：make release VERSION=0.6.0
release:
	@if [ -z "$(VERSION)" ]; then \
	  echo "usage: make release VERSION=x.y.z" >&2; exit 2; \
	fi
	@bash tools/release.sh "$(VERSION)"

release-dry:
	@if [ -z "$(VERSION)" ]; then \
	  echo "usage: make release-dry VERSION=x.y.z" >&2; exit 2; \
	fi
	@bash tools/release.sh "$(VERSION)" --dry-run
