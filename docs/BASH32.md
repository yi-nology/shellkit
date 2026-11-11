# Bash 3.2 兼容

基线是 **Bash 3.2+**，不是 4.x 也不是 5.x。原因很具体：macOS 自带的 `/bin/bash` 就是 3.2.57，
而运维脚本经常在别人的 Mac 上、在没装 homebrew 的机器上、在 CI 的基础镜像里跑。

写之前先看这张表。左边这些**在 3.2 上直接崩**，不是风格问题。

| 别写 | 写这个 | 在 3.2 上会怎样 |
| --- | --- | --- |
| `declare -A m` | `case` 分派，或两个平行数组 | 报 `declare: -A: invalid option` |
| `${v^^}` / `${v,,}` | `printf '%s' "$v" \| tr a-z A-Z` | 报 `bad substitution` |
| `local -n ref=$1` | 出参：`printf -v "$outvar" '%s'` | 报无效选项 |
| `mapfile -t a < f` | `while IFS= read -r l; do ...; done < f` | 报 `command not found` |
| `[[ -v x ]]` | `[ -n "${x:-}" ]` | 条件表达式语法错 |
| `"${arr[@]}"`（数组可能为空） | `${arr[@]+"${arr[@]}"}` | `set -u` 下报 unbound variable |
| `arr+=(x)` | `arr[${#arr[@]}]=x` | 能跑，但别和空数组展开混用 |

## 为什么这些会崩，而不是降级

前面几条是**解析期**就失败：`${v^^}` 这种参数展开语法在 3.2 的解释器里根本不存在，
它会直接报 `bad substitution` 并退出，连「部分功能不可用」都做不到。所以不能靠运行时兜底，
必须在写的时候就不用。

最后一条（空数组展开）是**运行期**失败，而且只在特定组合下出现：

```bash
set -euo pipefail

# 3.2 上：unbound variable，整个脚本退出
for item in "${arr[@]}"; do
  printf '%s\n' "$item"
done

# 正确写法：没有元素时展开成空，而不是「一个未定义的变量」
for item in ${arr[@]+"${arr[@]}"}; do
  printf '%s\n' "$item"
done
```

`set -u` 之后 `"${arr[@]}"` 在空数组上会被当成展开了未定义变量。加上 `+` 判断，
数组为空时整个表达式消失，循环体一次都不进 —— 这才是想要的行为。

## 三个踩过的坑

### 1. bash 3.2 与 5 的 trap 语义不同

在**子 shell** 里 `trap -p EXIT`：3.2 读到空，5.x 仍打印父 shell 的 trap，但子 shell 退出时
不执行。所以「幂等」不能只查 `trap -p`：看到是自己的处理器就重装一遍（重装无害），
也绝不把自己的处理器当成调用方的捕获下来。

### 2. `$(trap -p ...)` 永远读不到东西

命令替换本身就是子 shell。要读 trap 状态，先重定向到文件再 `cat`，不要用 `$(...)`。

### 3. 无命令的 `exec` 会把重定向永久留在调用方

```bash
# 错误：不只是关了 fd 3，还让调用方 stderr 从此进 /dev/null
exec 3>&- 2>/dev/null

# 正确：重定向跟着这一条命令结束就消失
(: <"/dev/tcp/127.0.0.1/5432") 2>/dev/null
```

第 3 条在写「探测端口」时特别容易中：现象是「测试 RC=1，但一行 FAIL 都看不见」。

## 替代手法一览

| 想做的事 | 3.2 上的写法 |
| --- | --- |
| 子命令分发 | `declare -F cmd_<name>` 检查存在性 |
| 返回多个值 | 出参变量 + `printf -v` |
| 大小写转换 | `tr a-z A-Z` |
| 数组追加 | `arr[${#arr[@]}]=x` |
| 遍历可能为空的数组 | `${arr[@]+"${arr[@]}"}` |
| 字符串包含 | `case "$s" in *"$needle"*) ... ;; esac` |

## 怎么自检

```bash
bash -n my-script.sh
shellcheck -S warning -x my-script.sh
```

`bash -n` 能拦住解析期的那几条（`${v^^}`、`declare -A` 在 3.2 上是运行期才报，所以更可靠的做法
是真在 3.2 上跑一遍）。`shellcheck` 会提示部分不兼容写法，但它默认按当前 bash 版本理解。

真正可靠的一条：**在 macOS 自带的 `/bin/bash` 上跑一次**。`/bin/bash --version` 看到 3.2.57
就是它。
