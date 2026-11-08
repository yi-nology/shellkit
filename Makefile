# shellkit 开发入口。CI 与本地跑的是同一组门。

SHELL := /bin/bash
SOURCES := shellkit install.sh lib/bootstrap.sh $(wildcard lib/core/*.sh) \
  $(wildcard tools/*.sh) tests/*.sh po/messages.sh
TEMPLATES := $(shell find templates -type f)
SHOTS := $(wildcard docs/shots/*.shot)

.PHONY: help test syntax lint lint-templates fmt messages messages-check docs docs-check versions-check check-docs shots examples check install release release-dry

help:
	@printf '%s\n' \
	  'make test        跑全部测试（tests/run.sh）' \
	  'make syntax      bash -n 全部脚本' \
	  'make lint        shellcheck -S warning -x' \
	  'make fmt         shfmt -d -i 2 -ci（只检查）' \
	  'make messages    重新抽取 msgid 并编译 .mo' \
	  'make messages-check  只检查 pot 与源码是否一致（缺 xgettext 时跳过）' \
	  'make docs        重新生成 REFERENCE.md / AGENTS.md / SKILL.md' \
	  'make versions-check  VERSION / pot 头 / README / 站点里的版本号是否一致' \
	  'make shots       按 docs/shots/*.shot 真跑命令并渲染 SVG 截图' \
	  'make examples    跑 examples/ 下每个工程的测试' \
	  'make check       依次跑 syntax / test / lint / docs-check / versions-check / check-docs / messages-check / examples / fmt' \
	  'make release VERSION=x.y.z  发版：升版本→重生成产物→门禁→commit→tag→push' \
	  'make release-dry VERSION=x.y.z  同 release，但跑完还原工作树、不提交'

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

# 截图是真实输出渲染的，需要用 python3；没有就跳过而不是失败
shots:
	@if command -v python3 >/dev/null 2>&1; then \
	  python3 tools/term_shot.py $(SHOTS); \
	  else echo "python3 not installed, skipping screenshots"; fi

examples:
	@for d in examples/*/; do \
	  [ -f "$$d/Makefile" ] || continue; \
	  echo "==> $$d"; \
	  $(MAKE) -C "$$d" test || exit 1; \
	  done

check: syntax test lint docs-check versions-check check-docs messages-check examples fmt

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
