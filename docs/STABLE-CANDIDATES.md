# Stable 候选清单（首批，待勾选）

状态：**待维护者勾选**。这是 issue #79 的后续动作 —— 分级机制（`@stability` 注解、
三规则门禁、豁免名单）已经合入，但 162 个公开函数目前**全部是 experimental**，
真正的稳定性承诺还没填。本文按约定的三条标准筛出首批候选，**逐条勾选后再合入注解**。

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

## 勾选方式

把「勾选」列的 `-` 改成 `x` 即为入选；或直接回复函数名/分组。
入选后执行：源码加 `@stability stable` → 从 `tools/stability_exempt.txt` 移出
→ `bash tools/api_baseline.sh --write-baseline` → 重生成文档投影。

「建议」列是我的推荐：**推荐** = 核心路径、被 scaffold/upgrade/install 反复依赖；
**可选** = 满足三条件但属于工具/周边能力，承诺成本低、也可先留 experimental。

## 候选清单（46 个，按模块分组）

### fs —— 文件安全原语（全部推荐）

| 函数 | 承诺返回码 | 探针断言 | 勾选 |
|---|---|---|---|
| `fs_atomic_copy` | 0,1,2 | 0 | - |
| `fs_backup` | 0,1,2 | 0 | - |
| `fs_ensure_block` | 0,1,2 | 0 | - |
| `fs_ensure_line` | 0,1,2 | 0 | - |

### config —— 配置层（全部推荐）

| 函数 | 承诺返回码 | 探针断言 | 勾选 |
|---|---|---|---|
| `conf_get` | 0,2 | 0 | - |
| `conf_set` | 0,1,2,3 | 0 | - |
| `conf_unset` | 0,1,2 | 0 | - |
| `conf_disable` | 0,1,2 | 0 | - |
| `conf_load_dotenv` | 0,2,3 | 0 | - |
| `conf_source` | 0,2,3 | 0 | - |

### run / retry / lock —— 执行与并发（全部推荐）

| 函数 | 承诺返回码 | 探针断言 | 勾选 |
|---|---|---|---|
| `run` | 0,2,其他 | 0 | - |
| `run_concurrent` | 0,2,其他 | 0 | - |
| `retry` | 0,2,其他 | 0 | - |
| `lock_acquire` | 0,2,3 | 0 | - |

### error / os / validate / ver —— 前置条件与校验（全部推荐）

| 函数 | 承诺返回码 | 探针断言 | 勾选 |
|---|---|---|---|
| `fail` | 0,2,其他 | 0,2,7 | - |
| `require_cmd` | 0,2,3 | 0,3 | - |
| `os_has_cmd` | 0,1,2 | 0,1 | - |
| `validate_ip` | 0,1 | 0,1 | - |
| `ver_cmp` | 0,2 | 0 | - |
| `ver_eq` | 0,1,2 | 0,1,2 | - |
| `ver_gt` | 0,1,2 | 0,1,2 | - |
| `ver_lt` | 0,1,2 | 0,1,2 | - |

### trap —— 清理栈（全部推荐）

| 函数 | 承诺返回码 | 探针断言 | 勾选 |
|---|---|---|---|
| `trap_install` | 0 | 0 | - |
| `trap_push` | 0,2 | 0 | - |

### registry —— 模块清单（全部推荐）

| 函数 | 承诺返回码 | 探针断言 | 勾选 |
|---|---|---|---|
| `registry_scan` | 0 | 0 | - |
| `registry_get` | 0 | 0 | - |
| `registry_add` | 0 | 0 | - |
| `registry_deps` | 0,1 | 0 | - |
| `registry_topo` | 0,1 | 0 | - |
| `registry_visible` | 0,1 | 0 | - |

### cli —— 命令行框架（全部推荐）

| 函数 | 承诺返回码 | 探针断言 | 勾选 |
|---|---|---|---|
| `cli_run` | 0,1,2,其他 | 0 | - |
| `cli_opt` | 0,2 | 0 | - |
| `cli_opts` | 0,2 | 0 | - |

### prompt —— 交互（全部推荐）

| 函数 | 承诺返回码 | 探针断言 | 勾选 |
|---|---|---|---|
| `ask` | 0,1,2,3 | 0,3 | - |
| `ask_yn` | 0,1,2,3 | 0,3 | - |
| `ask_choice` | 0,1,2,3 | 0,3 | - |
| `confirm` | 0,1,2,3 | 0,1 | - |

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

## 勾选之后（我来执行）

1. 入选函数的源码注释加 `@stability stable`（紧跟公开函数注释块）；
2. 从 `tools/stability_exempt.txt` 移出对应名字（门禁会拦「已声明却还在名单里」）；
3. `bash tools/api_baseline.sh --write-baseline` 重生成基线；
4. `./shellkit docs` 重生成 REFERENCE 投影；
5. 新增 `tests/test_api_stability.sh` 判据：Stable 函数必须出现在
   `docs/MIGRATING.md` 对应小节（把「Stable 才进迁移表」从约定变成门禁）；
6. 全量 `make check` + CI 绿后合入，随后发 v0.19.0。
