---
title: "机器可读输出"
---


人读的是散行，脚本读的是字段。shellkit 的机器可读输出集中写在这一页 ——
**字段名是契约**：加字段可以，改字段的含义要升 schema 版本。

## 1. `shellkit doctor --json`

诊断报告。stdout 只有一份 JSON 文档（没有别的东西混进来），退出码与文本形态完全一致。

```bash
shellkit doctor --json > report.json
jq '.result.exit_code' report.json
```

### 顶层字段

| 字段 | 类型 | 含义 |
| --- | --- | --- |
| `schema` | string | 结构标识，固定 `shellkit.doctor.v1` |
| `shellkit` | object | `version`：shellkit 版本 |
| `platform` | object | `os` / `arch`（库口径）、`sysname` / `release` / `machine`（`uname` 口径） |
| `bash` | object | `version`：`BASH_VERSION`；`satisfied`：是否满足 3.2 基线 |
| `modules` | object | 模块清单，见下 |
| `dependencies` | array | 关键依赖，见下 |
| `vendor` | object | `state`：`none` / `ok` / `drift` / `notdir` / `unknown`；`detail`：补充说明 |
| `checks` | array | 逐行检查结果，见下 |
| `result` | object | 汇总判定，见下 |
| `last_error` | string | 最近一次失败的上下文（没有则空串） |

### `modules`

| 字段 | 类型 | 含义 |
| --- | --- | --- |
| `count` | number | `lib/modules.txt` 里登记的模块数 |
| `loadable` | number | 其中文件在、非空、语法也对 —— **真能加载**的模块数 |
| `listed` | array | 登记的模块名 |
| `missing` | array | 登记了但文件不在 |
| `empty` | array | 文件在但是空的 |
| `broken` | array | 文件在但语法坏了 |

`loadable` 与 `missing` / `empty` / `broken` 分开，是为了回答两个不同的问题：
「清单上写了几个」和「现在真能加载几个」。只报前者，用户看到 23 个模块却起不来，
还得自己猜是哪一个坏了。

### `dependencies` 与 `checks`

`dependencies` 是关键依赖，每项四个字段：

| 字段 | 类型 | 含义 |
| --- | --- | --- |
| `name` | string | 依赖名（`bash` / `sha256` / `download` / `gettext` / `po tools` / `shellcheck` / `shfmt`） |
| `status` | string | `OK` / `WARN` / `FAIL` |
| `required` | boolean | 缺了是不是就废了 |
| `detail` | string | 补充说明（路径或原因） |

`required` 为 `false` 的依赖缺了只是**降级**（核心功能还在），为 `true` 的缺了得**重装**。
两种混在一起报，用户就不知道还能不能用 —— 这也是「按需加载的模块缺依赖」
与「真的缺」必须分开的理由。

`checks` 是逐行检查结果：`section`（`environment` / `library` / `vendor`）、
`status`、`name`、`detail`。文本形态里的一行，在 JSON 里就是这里的一项。

### `result`

| 字段 | 类型 | 含义 |
| --- | --- | --- |
| `missing_required` | number | 缺了几个必需依赖 |
| `missing_optional` | number | 缺了几个可选依赖 |
| `verify_failed` | boolean | 库完整性 / vendor 漂移检查有没有失败 |
| `exit_code` | number | 与命令行退出码一致 |

### 退出码

| 码 | 含义 |
| --- | --- |
| 0 | 全过 |
| 3 | 缺必需工具（`SK_PRECOND`） |
| 5 | 库完整性或 vendor 漂移检查失败（`SK_VERIFY`） |

### 脱敏

`detail` 里形如 `键名=值` 的赋值，键名命中敏感字段（口令 / 令牌 / 私钥这类）时，
值一律替换成 `***`。判定复用 `run` 的同一套键名规则 —— 报告要能直接贴进 issue，
贴出去之前不能带着凭据。

### 降级形态

库自己都加载不起来时（`lib/bootstrap.sh` 语法坏了之类），`doctor --json` 仍然给出
一份 JSON：`modules` 只报清单与缺失，`dependencies` 与 `checks` 为空，
`result.verify_failed` 为 `true`，`result.exit_code` 为 5。

这条路径不能依赖库 —— 恰恰是库坏了的时候，用户最需要一份能贴进 issue 的报告。

### 文本形态不变

`doctor` 不带 `--json` 时，输出与从前**逐字一致**（包括空行位置）。
有人拿它做 diff，有人在 CI 里比对输出文本 —— 加一个开关不能顺手改掉老输出。

## 2. `SHELLKIT_LOG_FORMAT=json`

日志的 JSON 形态：**一条日志一行**（不是数组），便于 `grep` / `jq -c` 直接消费。

```bash
export SHELLKIT_LOG_FORMAT=json
log_info "deploy started"
```

输出：

```text
{"ts":"2026-11-12T10:20:30+0800","level":"INFO","msg":"deploy started"}
```

| 字段 | 含义 |
| --- | --- |
| `ts` | 时间戳，本地时区，带时区偏移 |
| `level` | `ERROR` / `WARN` / `INFO` / `OK` / `DEBUG` |
| `msg` | 日志正文（换行已转义，不会把这一行打断） |

与 `doctor --json` 的区别：日志是**流**（一行一条，边跑边出），报告是**快照**
（跑完给一份完整文档）。要贴进 issue 用报告，要接采集系统用日志。
