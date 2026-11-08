# shellkit 开发入口。CI 与本地跑的是同一组门。

SHELL := /bin/bash
SOURCES := shellkit lib/bootstrap.sh $(wildcard lib/core/*.sh) tests/*.sh po/messages.sh
TEMPLATES := $(shell find templates -type f)

.PHONY: help test syntax lint lint-templates fmt messages check install

help:
	@printf '%s\n' \
	  'make test      跑全部测试（tests/run.sh）' \
	  'make syntax    bash -n 全部脚本' \
	  'make lint      shellcheck -S warning -x' \
	  'make fmt       shfmt -d -i 2 -ci（只检查）' \
	  'make messages  重新抽取 msgid 并编译 .mo' \
	  'make check     依次跑 syntax / test / lint / fmt'

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

check: syntax test lint fmt

install:
	./shellkit install-self --prefix $(PREFIX)/usr
