# {{NAME}} 的构建入口。不依赖 make 也能跑：bash tests/run.sh

SHELL := /bin/bash

.PHONY: help test lint fmt

help:
	@printf '%s\n' \
	  'make test   跑全部测试' \
	  'make lint   shellcheck 静态检查' \
	  'make fmt    shfmt 格式检查（只检查不改）'

test:
	@bash tests/run.sh

lint:
	@if command -v shellcheck >/dev/null 2>&1; then \
	  shellcheck -S warning -x bin/*{{NAME}} lib/*.sh commands/*.sh tests/*.sh; \
	  else echo "shellcheck not installed, skipping"; fi

fmt:
	@if command -v shfmt >/dev/null 2>&1; then \
	  shfmt -d -i 2 -ci bin/*{{NAME}} lib/*.sh commands/*.sh tests/*.sh; \
	  else echo "shfmt not installed, skipping"; fi
