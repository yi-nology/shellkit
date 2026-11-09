# {{NAME}} 的构建入口。不依赖 make 也能跑：bash tests/run.sh

SHELL := /bin/bash

# 工程自带的 shellkit 副本。工程可能被 vendor 到别的机器上，
# 那时 PATH 上不一定有 shellkit —— 有自带副本就用它。
VENDOR_CLI := vendor/shellkit/shellkit

.PHONY: help test lint fmt upgrade completion version vendor

help:
	@printf '%s\n' \
	  'make test        跑全部测试' \
	  'make lint        shellcheck 静态检查' \
	  'make fmt         shfmt 格式检查（只检查不改）' \
	  'make upgrade     把工程升级到当前模板' \
	  'make completion  输出 bash 补全脚本' \
	  'make version     打印工程用的库版本' \
	  'make vendor      把库镜像进 vendor/shellkit'

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

# 升级与镜像的逻辑在 shellkit 这个命令里，不在库里，所以要一个能跑的 shellkit：
# 先用工程自带的副本，没有就退回 PATH 上的 shellkit，都没有就报前置条件错。
upgrade:
	@if [ -f "$(VENDOR_CLI)" ]; then \
	  bash "$(VENDOR_CLI)" upgrade "$(CURDIR)"; \
	elif command -v shellkit >/dev/null 2>&1; then \
	  shellkit upgrade "$(CURDIR)"; \
	else \
	  printf '%s\n' "找不到 shellkit：先装一个（shellkit install-self），或在工程里保留 vendor/shellkit/shellkit" >&2; \
	  exit 3; \
	fi

# 把库镜像进工程。镜像落在 vendor/shellkit/，就是工程自带副本的位置。
vendor:
	@if [ -f "$(VENDOR_CLI)" ]; then \
	  bash "$(VENDOR_CLI)" vendor "$(CURDIR)"; \
	elif command -v shellkit >/dev/null 2>&1; then \
	  shellkit vendor "$(CURDIR)"; \
	else \
	  printf '%s\n' "找不到 shellkit：先装一个（shellkit install-self），或在工程里保留 vendor/shellkit/shellkit" >&2; \
	  exit 3; \
	fi

# 补全脚本：优先用工程自己的入口生成 —— 程序名与子命令都取自本工程，
# 新增子命令后重跑一次即可。工程入口不在时再退回 shellkit 副本或 PATH 上的 shellkit。
completion:
	@if [ -f "bin/{{NAME}}" ]; then \
	  bash "bin/{{NAME}}" --completion bash; \
	elif [ -f "$(VENDOR_CLI)" ]; then \
	  bash "$(VENDOR_CLI)" completion bash; \
	elif command -v shellkit >/dev/null 2>&1; then \
	  shellkit completion bash; \
	else \
	  printf '%s\n' "生成不了补全脚本：bin/{{NAME}} 不在，也没有可用的 shellkit" >&2; \
	  exit 3; \
	fi
	@printf '%s\n' \
	  "装到 /etc/bash_completion.d/{{NAME}}（全机器）" \
	  "或 ~/.local/share/bash-completion/completions/{{NAME}}（只给自己）" >&2

# 工程用的库版本：库副本在 vendor/shellkit/ 里，版本号写在 VERSION 文件里。
version:
	@if [ ! -r vendor/shellkit/VERSION ]; then \
	  printf '%s\n' "工程里没有库副本：先跑 make vendor" >&2; \
	  exit 3; \
	fi; \
	printf 'library %s\n' "$$(tr -d '[:space:]' <vendor/shellkit/VERSION)"; \
	__tpl=$$(sed -n 's/^template_version=//p' .shellkit-manifest 2>/dev/null | tr -d '[:space:]'); \
	if [ -n "$$__tpl" ]; then printf 'template %s\n' "$$__tpl"; fi
