# 给 AI 用

这套约束本来就是写给机器看的：禁用语法、任务落点、交付自检，全部是可判定的规则，
不是「建议保持整洁」这种。

## 三份同源产物

| 文件 | 给谁 |
| --- | --- |
| `AGENTS.md`（仓库根） | 在本仓库里写代码的 AI |
| `templates/AGENTS.md` | `shellkit new` 生成的工程自带一份 |
| `skills/shellkit/SKILL.md` | 作为 skill 安装到 AI 客户端 |

三份都由 `docs/ai/contract.md` 拼出来，**改一处三处同时更新**。三份手写必然漂移，
而漂移的后果是 AI 按过期规则生成代码。

## 为什么有效

AI 写 Bash 出错有两类高发原因：

1. **用了 5.x 才有的语法**（`declare -A`、`${v^^}`、`mapfile`），在 macOS 自带 bash 上直接崩。
2. **发明函数名**（`conf_require`、`log_success`），运行时才炸，错误信息还看不懂。

`AGENTS.md` 里那张「别写 / 写这个 / 在 3.2 上会怎样」的表治第一类；
`docs/REFERENCE.md`（从源码注释生成）治第二类 —— 它同时是 `check-docs` 的判据来源，
所以「文档里有但代码里没有」是不可能的。

## 直接可用的提示词

```text
用 shellkit 写 deploy.sh：
 - 日志用 log_info / log_ok / log_warn / log_error，全部走 stderr
 - 读配置用 conf_init + conf_get_any；改配置用 conf_set（幂等）
 - 失败用 die / require_cmd，退出码按 0/1/2/3/4/5 分，不要一律 exit 1
 - 下载校验用 net_download URL DEST sha256；等端口用 net_wait_port
 - 同时只跑一个实例用 lock_acquire
 - 跑命令失败即停用 run，要在 if 里判成败用 run --no-die
 - 禁用 declare -A / local -n / ${v^^} / mapfile / [[ -v ]]
 - 空数组遍历写成 ${arr[@]+"${arr[@]}"}
 - 交付前跑 bash -n 和 shellcheck -S warning -x，并贴出真实输出
```

最后一条是关键：让它**贴输出**，而不是说「应该能跑」。

## 交付前自检

```bash
bash -n 改过的脚本
shellcheck -S warning -x 改过的脚本
make test
```

三条判据要同时成立才算过：**退出码为 0**、**没有 FAIL 行**、**你自己看过输出**。
只看退出码会漏掉「命令根本没跑」，只看输出会漏掉静默失效。

## 别让 AI 做的事

- 不要让它「顺便重写」整个脚本 —— 目标是你指定的那一处改动。
- 不要接受「应该能跑」这种结论，要它给出真实命令与真实输出。
- 不要让它发明不存在的函数名：不确定就去 [API 参考](/reference/index.md) 查，
  查不到就是不存在。
