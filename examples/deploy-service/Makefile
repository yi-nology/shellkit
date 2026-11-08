# 示例工程的构建入口。仓库根跑 make examples 会把这里的 test 全跑一遍。
SHELL := /bin/bash

.PHONY: help test

help:
	@printf '%s\n' \
	  'make test   跑这个示例的测试' \
	  'make help   看这个帮助'

test:
	@bash tests/test_deploy.sh </dev/null
