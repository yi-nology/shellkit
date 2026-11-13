# Stable 候选清单（首批，已定稿）

状态：**已定稿（2026-11-13）**。这是 issue #79 的后续动作 —— 分级机制（`@stability` 注解、
三规则门禁、豁免名单）已经合入。本文按约定的三条标准筛出首批候选，
**「推荐」列的 37 个已全部合入 `@stability stable`**；「可选」列的 9 个按原判断
留 experimental（工具/周边能力，承诺成本低但没必要第一天就背上）。

## 入选标准（三条件同时满足）

1. **探针覆盖**：`tools/api_baseline.txt` 里该函数是 `probe`（沙箱里真调过，
   不是 `skip`）；
2. **MIGRATING 有记录**：`docs/MIGRATING.md` 里出现过它的行为变化 ——
   说明这个函数的结果曾经变过、且变更被认真对待过；
3. **返回码齐全**：源码注释里 `@exitcode` 齐全，且探针实测断言的返回码
   全部落在承诺集合内（逐条核对过，零不一致）。

口径：162 个公开函数 → 134 个有探针 → 80 个在 MIGRATING 出现过 → **46 个交集**。
未入选的 116 个：88 个「有探针但 MIGRATING 没记录」、34 个「MIGRATING 有记录但
没探针」、另有少量两者皆无 —— 都不是不合格，是**证据还不够**，可后续补。

## 勾选结果

「推荐」列 37 个全部入选（勾选列 `x`），「可选」列 9 个留 experimental（`-`）。
已执行：源码加 `@stability stable` → 从 `tools/stability_exempt.txt` 移出
→ `bash tools/api_baseline.sh --write-baseline` → `./shellkit docs` 重生成文档投影。
基线分级列现为 37 stable / 125 experimental，REFERENCE 恰好 37 处「稳定性：stable」。

「建议」列是我的推荐：**推荐** = 核心路径、被 scaffold/upgrade/install 反复依赖；
**可选** = 满足三条件但属于工具/周边能力，承诺成本低、也可先留 experimental。

## 候选清单（46 个，按模块分组）

### fs —— 文件安全原语（全部推荐）

| 函数 | 承诺返回码 | 探针断言 | 勾选 |
|---|---|---|---|
| `fs_atomic_copy` | 0,1,2 | 0 | x |
| `fs_backup` | 0,1,2 | 0 | x |
| `fs_ensure_block` | 0,1,2 | 0 | x |
| `fs_ensure_line` | 0,1,2 | 0 | x |

### config —— 配置层（全部推荐）

| 函数 | 承诺返回码 | 探针断言 | 勾选 |
|---|---|---|---|
| `conf_get` | 0,2 | 0 | x |
| `conf_set` | 0,1,2,3 | 0 | x |
| `conf_unset` | 0,1,2 | 0 | x |
| `conf_disable` | 0,1,2 | 0 | x |
| `conf_load_dotenv` | 0,2,3 | 0 | x |
| `conf_source` | 0,2,3 | 0 | x |

### run / retry / lock —— 执行与并发（全部推荐）

| 函数 | 承诺返回码 | 探针断言 | 勾选 |
|---|---|---|---|
| `run` | 0,2,其他 | 0 | x |
| `run_concurrent` | 0,2,其他 | 0 | x |
| `retry` | 0,2,其他 | 0 | x |
| `lock_acquire` | 0,2,3 | 0 | x |

### error / os / validate / ver —— 前置条件与校验（全部推荐）

| 函数 | 承诺返回码 | 探针断言 | 勾选 |
|---|---|---|---|
| `fail` | 0,2,其他 | 0,2,7 | x |
| `require_cmd` | 0,2,3 | 0,3 | x |
| `os_has_cmd` | 0,1,2 | 0,1 | x |
| `validate_ip` | 0,1 | 0,1 | x |
| `ver_cmp` | 0,2 | 0 | x |
| `ver_eq` | 0,1,2 | 0,1,2 | x |
| `ver_gt` | 0,1,2 | 0,1,2 | x |
| `ver_lt` | 0,1,2 | 0,1,2 | x |

### trap —— 清理栈（全部推荐）

| 函数 | 承诺返回码 | 探针断言 | 勾选 |
|---|---|---|---|
| `trap_install` | 0 | 0 | x |
| `trap_push` | 0,2 | 0 | x |

### registry —— 模块清单（全部推荐）

| 函数 | 承诺返回码 | 探针断言 | 勾选 |
|---|---|---|---|
| `registry_scan` | 0 | 0 | x |
| `registry_get` | 0 | 0 | x |
| `registry_add` | 0 | 0 | x |
| `registry_deps` | 0,1 | 0 | x |
| `registry_topo` | 0,1 | 0 | x |
| `registry_visible` | 0,1 | 0 | x |

### cli —— 命令行框架（全部推荐）

| 函数 | 承诺返回码 | 探针断言 | 勾选 |
|---|---|---|---|
| `cli_run` | 0,1,2,其他 | 0 | x |
| `cli_opt` | 0,2 | 0 | x |
| `cli_opts` | 0,2 | 0 | x |

### prompt —— 交互（全部推荐）

| 函数 | 承诺返回码 | 探针断言 | 勾选 |
|---|---|---|---|
| `ask` | 0,1,2,3 | 0,3 | x |
| `ask_yn` | 0,1,2,3 | 0,3 | x |
| `ask_choice` | 0,1,2,3 | 0,3 | x |
| `confirm` | 0,1,2,3 | 0,1 | x |

### log —— 日志（可选）

| 函数 | 承诺返回码 | 探针断言 | 勾选 |
|---|---|---|---|
| `log_info` | 0 | 0 | - |
| `log_error` | 0 | 0 | - |
| `log_debug` | 0 | 0 | - |

### man —— 手册页生成（可选）

| 函数 | 承诺返回码 | 探针断言 | 勾选 |
|---|---|---|---|
| `man_page` | 0 | 0 | - |
| `man_modules` | 0 | 0 | - |
| `man_module_page` | 0,2 | 0 | - |
| `man_count_functions` | 0 | 0 | - |

### 其余（可选）

| 函数 | 承诺返回码 | 探针断言 | 勾选 |
|---|---|---|---|
| `scaffold_vars_set` | 0,2 | 0 | - |
| `net_escape_json` | 0 | 0 | - |

## 落地清单（已执行）

1. ✅ 37 个入选函数的源码注释加 `@stability stable`（紧邻函数定义行上方 —— 扫描器只认紧邻注释块）；
2. ✅ 从 `tools/stability_exempt.txt` 移出这 37 个（剩 125 条，注解/名单双向核对零违例）；
3. ✅ `bash tools/api_baseline.sh --write-baseline` 重生成基线（37 stable / 125 experimental）；
4. ✅ `./shellkit docs` 重生成 REFERENCE 投影（恰好 37 处「稳定性：stable」）；
5. ✅ `tests/test_api_stability.sh` 新增判据：Stable 函数的行为变更必须出现在
   `docs/MIGRATING.md`「会改变结果的行为变化」小节（把「Stable 才进迁移表」从约定变成门禁）；
6. 全量 `make check` + CI 绿后合入，随后发 v0.19.0。
