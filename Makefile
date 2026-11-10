# shellkit 开发入口。CI 与本地跑的是同一组门。

SHELL := /bin/bash
SOURCES := shellkit install.sh lib/bootstrap.sh $(wildcard lib/core/*.sh) \
  $(wildcard tools/*.sh) tests/*.sh po/messages.sh
TEMPLATES := $(shell find templates -type f)
SHOTS := $(wildcard docs/shots/*.shot)

.PHONY: help test syntax lint lint-templates fmt messages messages-check docs docs-check versions-check check-docs cookbook-check shots examples check install release release-dry site-deps site-sync site site-serve local-names-check module-count-check pipe-safety-check dup-functions-check

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
	  'make release VERSION=x.y.z  发版：升版本→重生成产物→门禁→commit→tag→push' \
	  'make release-dry VERSION=x.y.z  同 release，但跑完还原工作树、不提交' \
	  'make site        构建文档站（先跑 tools/site_sync.sh 从 docs/ 同步）' \
	  'make site-serve  本地起文档站的开发服务器' \
	  'make site-deps   装文档站的 node 依赖'


test:
	@bash tests/run.sh

syntax:
	@fail=0; for f in $(SOURCES) $(TEMPLATES); do \
	  case "$$f" in *.sh|shellkit|*/__NAME__|*/__CMD__) bash -n "$$f" || fail=1 ;; esac; \
	  done; exit $$fail

lint:
	@if command -v shellcheck >/dev/null 2>&1; then \
	  shellcheck -S warning -x $(SOURCES); \
	  else echo "shellcheck not installed, skipping"; fi
	@$(MAKE) --no-print-directory lint-templates

# 模板里有 {{NAME}} 这类占位符，直接检查会被当成语法错误；先渲染再检查。
lint-templates:
	@bash tests/lint_templates.sh

fmt:
	@if command -v shfmt >/dev/null 2>&1; then \
	  shfmt -d -i 2 -ci $(SOURCES); \
	  else echo "shfmt not installed, skipping"; fi

messages:
	@bash po/messages.sh

# 缺 xgettext 的机器上 po/messages.sh --check 自己会跳过，不会误伤 macOS
messages-check:
	@bash po/messages.sh --check

docs:
	@./shellkit docs

docs-check:
	@./shellkit docs --check

# VERSION 是唯一真相源，pot 头与两处钉版本引用都是它的投影
versions-check:
	@bash tools/check_versions.sh

# 文档里的代码块必须能过 bash -n，函数名必须真实存在
check-docs:
	@bash tools/check_docs.sh

# 文档里手写的「N 个场景」必须与 Cookbook 里的实际场景数一致
cookbook-check:
	@bash tools/check_cookbook_count.sh

# 截图是真实输出渲染的，需要用 python3；没有就跳过而不是失败
shots:
	@if command -v python3 >/dev/null 2>&1; then \
	  python3 tools/term_shot.py $(SHOTS); \
	  else echo "python3 not installed, skipping screenshots"; fi

# ---------- 文档站 ----------
# 刻意不进 check：库的门禁不依赖 Node，没装 npm 的机器上也该能全绿。
# CI 里站点是独立 job（.github/workflows/ci.yml），发站是 .github/workflows/pages.yml。

site-deps:
	@cd site && npm install --no-audit --no-fund

# docs/ 是唯一真相源；site/ 里的 cookbook / 迁移 / 发版 / 参考页都是它的生成物
site-sync:
	@bash tools/site_sync.sh

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
	@bash tools/check_module_order.sh

# 公开函数必须写明返回码 —— 返回码是接口的一部分
check-exitcode-docs:
	@bash tools/check_exitcode_docs.sh

# 库内部局部变量必须 __ 前缀；公开出参函数必须拒绝保留名
local-names-check:
	@bash tools/check_local_names.sh

# 文档里手抄的模块数必须与 lib/modules.txt 一致
module-count-check:
	@bash tools/check_module_count.sh

# 同一个文件里不能有重复的函数定义（bash 后定义覆盖先定义，前面的悄悄失效）
dup-functions-check:
	@bash tools/check_dup_functions.sh

# 管道里不能有会提前退出的消费者：grep -q / head 会把上游 SIGPIPE 打死（141），
# 调用方开了 pipefail 时整条管道判失败 —— 而且是竞态，本机常绿、CI 必炸
pipe-safety-check:
	@bash tools/check_pipe_safety.sh

check: syntax test lint module-order-check check-exitcode-docs local-names-check module-count-check pipe-safety-check dup-functions-check docs-check versions-check check-docs cookbook-check messages-check examples fmt

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
