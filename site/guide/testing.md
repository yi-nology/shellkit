# 测试与门禁

这个仓库的测试有三层，都是为了同一件事：**证明它真的跑了**，而不是「应该能跑」。

| 层 | 在哪 | 测什么 |
| --- | --- | --- |
| 模块测试 | `tests/test_<module>.sh` | 每个模块的行为，含失败分支 |
| 脚手架测试 | `tests/test_scaffold.sh`、`tests/test_install.sh` | `shellkit new` 与安装出来的布局 |
| 示例工程测试 | `examples/*/tests/` | 完整工程，走真实二进制 |

## 跑

```bash
bash tests/run.sh
```

`tests/run.sh` 是逐文件执行器：通配 `tests/test_*.sh`，每个文件一个子进程，
stdin 接 `/dev/null`（测试不许等人按键，否则 CI 会挂死），有 `timeout` 时给单文件上限。

输出只有两种行：`ok` 或 `FAIL: <消息>`。**有 FAIL 行就是失败**，不看退出码也要看它。

## 机器可读的输出格式

CI 里真正要的是「哪个用例挂了」，不是「哪个文件挂了」。执行器有三种格式：

```bash
bash tests/run.sh                      # plain（默认，行为与旧版逐字一致）
bash tests/run.sh --format tap         # TAP 13，测试报告工具直接吃
bash tests/run.sh --format junit        # JUnit XML，GitHub Actions / Jenkins 收
```

其它选项：

```bash
bash tests/run.sh --jobs 4             # 并行跑（每个文件一个独立临时目录）
bash tests/run.sh --filter '*fs*'      # 只跑文件名匹配的文件
bash tests/run.sh --list               # 只列出将要跑的文件，不执行
```

`--filter` 收的是 shell 通配符（要自己带上 `*`）。一个文件都没匹配上时，退出码是 2
并把可用的测试文件列出来 —— 绝不会出现「All 0 test files passed.」这种假绿。

用例粒度靠测试文件里的 `# CASE: 标题` 注释切分。文件里没有 `CASE` 标记时退化成
「文件级一条用例」，失败原因取断言打印的 `FAIL:` 行。

**「有失败但报告说全过」不可能发生**：三种格式都会在有失败时返回非 0，
而且失败会以 `not ok` / `<failure>` / `FAILED:` 的形式出现在报告里。
这条不变量由 `tests/test_runner.sh` 守着 —— 它把真的执行器复制到一个假仓库里，
用受控的失败用例去验每种格式。

## 断言库

`tests/test_helper.sh` 是极简断言库，断言失败即 `exit 1`，由执行器标红。

| 断言 | 用法 |
| --- | --- |
| `assert_eq` | `assert_eq EXPECTED ACTUAL [MSG]` |
| `assert_ne` | `assert_ne UNEXPECTED ACTUAL [MSG]` |
| `assert_contains` | `assert_contains HAYSTACK NEEDLE [MSG]` |
| `assert_not_contains` | `assert_not_contains HAYSTACK NEEDLE [MSG]` |
| `assert_true` / `assert_false` | `assert_true CMD ARGS...` |
| `assert_exit_code` | `assert_exit_code WANT CMD ARGS...` |
| `assert_stdout_empty` | `assert_stdout_empty CMD ARGS...` |
| `assert_file_mode` | `assert_file_mode FILE 600` |
| `tmpdir` | 每个用例一个隔离目录，输出路径 |

## 一个测试文件

```bash
#!/usr/bin/env bash
. "$(dirname "$0")/test_helper.sh"

. "$TEST_ROOT/lib/bootstrap.sh"

assert_eq 2 "$SK_USAGE" "用法错的退出码是 2"
assert_exit_code 2 require_cmd
assert_stdout_empty log_info "日志不该出现在 stdout"
assert_contains "$(log_info hi 2>&1)" "hi" "stderr 里应当有这条消息"
```

注意最后两条是一对：`assert_stdout_empty` 证明 stdout 干净，`assert_contains` 证明消息确实
去了 stderr。只测前者的话，「什么都没打印」也会通过。

## stub：跑失败分支而不真的断网

`stub` 用同名 shell 函数顶替外部命令。函数对 `$(...)` 子 shell 天然可见，所以库内部调的
`curl` 会被拦住：

```bash
workdir=$(tmpdir)

# 让 curl 以 7 退出（连接失败），验证 net_download 把它翻成 SK_NET(4)
stub curl --exit 7
assert_exit_code 4 net_download "https://example.com/x" "$workdir/x"
assert_stub_called curl "curl 应当被调用过"
unstub curl
```

同一套办法也用于 `date`（钉死时间，测备份文件名）、`sleep`（不真睡，测重试延迟区间）。

## 门禁：`make check` 的十五步

| 步骤 | 拦什么 |
| --- | --- |
| `syntax` | `bash -n` 全部脚本与模板 |
| `test` | `tests/run.sh` |
| `lint` | `shellcheck -S warning -x`（模板先渲染再检查） |
| `module-order-check` | 某模块调用了还没加载的模块的函数 |
| `check-exitcode-docs` | 公开函数没写明返回码，或注释块与函数之间有空行 |
| `local-names-check` | 库内部局部变量没用 `__` 前缀；出参链路上的局部变量没进保留名单（用那个名字的调用方会静默拿到旧值） |
| `module-count-check` | 文档里手抄的「N 个模块」与 `lib/modules.txt` 对不上 |
| `pipe-safety-check` | 管道里有会提前退出的消费者（`grep -q` / `head`）：上游会被 SIGPIPE 打死，调用方开了 `pipefail` 时整条管道误判失败 |
| `docs-check` | 公开函数缺注释、生成物与源码不一致 |
| `versions-check` | `VERSION` 与五处投影是否一致 |
| `check-docs` | markdown 的 bash 代码块必须 `bash -n` 通过；函数名必须真实存在 |
| `cookbook-check` | 文档里手写的「N 个场景」与 Cookbook 实际场景数对不上 |
| `messages-check` | pot 与源码是否一致（缺 xgettext 时跳过） |
| `examples` | `examples/` 下每个工程自己的 test |
| `fmt` | `shfmt -d -i 2 -ci`（只检查，不自动改） |

`check-exitcode-docs` 守的是「返回码是接口的一部分」这句话：README 这么承诺，
就得有门禁兑现。早期写下的 16 个模块一个 `@exitcode` 都没有，接口是残的。

其中 `check-docs` 是最容易被忽略的一条：它让「文档写着、代码里没有」变成构建失败。
函数改名之后 README 里的例子会立刻红，而不是悄悄变成错的 —— AI 抓到错的例子会照抄，
而且抄得很有信心。

## 加一个测试

新建 `tests/test_<name>.sh` 就行：文件名被 `tests/test_*.sh` 通配到就自动执行，
不需要改执行器，也不需要登记。

写测试时的两条纪律：

1. **断言要落在产物上**，不要只断言退出码。退出码 0 但什么都没写，是最常见的假绿。
2. **反向验证一次**：先在旧代码上跑，确认它真的红，再在新代码上确认它绿。没红过的测试
   不能证明任何事。
