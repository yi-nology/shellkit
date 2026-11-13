# 五条硬约定

这五条不是风格偏好，每一条都有具体后果。违反任意一条，脚本会在某个不起眼的地方错，
而且错得不像脚本的问题（比如「取到的配置值多了个 `[INFO]`」）。

<ShotFigure src="/diagrams/conventions.svg" caption="数据通道、出参链、原子写、退出码：四条最常被违反的约定；第 3 条（取值优先级）见正文" />

## 1. stdout 只给数据，日志一律 stderr

```bash
# 对的：函数输出可以被捕获，日志去 stderr 不干扰
port=$(conf_get_any PORT 8080)
log_info "using port $port"
```

如果 `log_info` 也写 stdout，`$(...)` 会把 `[INFO] using port 8080` 一起捕获，
于是 `$port` 变成 `[INFO] using port 8080`，后面拿它拼端口号就整段失败 ——
而错误信息会出现在完全无关的地方。

这条在库里的落点：`log_*` 全部 `>&2`。`shellkit update --check` 也因此可以只输出一行版本号。

## 2. 出参用 `printf -v`，函数不直接改调用方变量

Bash 3.2 没有 nameref（`local -n` 是 4.3 才有的），所以「返回多个值」只有两个可靠办法：
打印到 stdout 让调用方捕获，或者让调用方指定变量名。库统一用后者：

```bash
# 调用方决定结果落到哪个变量
split_host_port() {
  local __target=$1 __outvar=$2 __host __port
  __host=${__target%%:*}
  __port=${__target##*:}
  printf -v "$__outvar" '%s %s' "$__host" "$__port"
}

split_host_port db.example.com:5432 parsed
log_info "parsed: $parsed"
```

为什么不用「全局变量约定」：两个并发调用的函数会互相覆盖；而 `printf -v` 里的变量名
由调用方给，作用域天然正确。

有一个坑要避开：`printf -v` 写的是「最近一层声明了该名字的作用域」。出参名一旦和库内部
某个局部变量同名，内容就写回库自己那层，你的变量还是旧值 —— **不报错、不崩**，只是静默失效。
所以库把出参链路上出现过的局部变量名列成一份**保留名单**，用这些名字调用会当场返回 2；
名单之外的名字（哪怕带 `__` 前缀）照常能用。

## 3. 取值优先级：显式参数 > 环境变量 > 配置文件 > 默认值

```bash
conf_init ./config || exit $?

# PORT 环境变量 > config 文件里的 PORT > 8080
port=$(conf_get_any PORT 8080)
```

这条只实现一次，在 `conf_get_any` 里。每个脚本各写一遍的后果是：某个脚本忘了看环境变量，
于是「用 `PORT=9090 ./deploy.sh` 临时改端口」在它身上不生效 —— 而这种不一致很难被测出来。

`conf_get` 只看配置文件，`conf_get_any` 才带环境变量。要「不管配置文件怎么写都用这个值」，
用 `conf_get` 加你自己的默认值。

## 4. 写文件必原子

```bash
# 中断不会留下半个文件：临时文件 + mv -f
fs_atomic_write /etc/app/conf "$content" 600

# 备份按名升序保留最新 5 份；同秒两次也不会互相覆盖
fs_backup /etc/app/conf 5
```

直接 `>` 重定向写到一半被打断，留下的是**语法不完整**的配置；下次启动读它，报的错误
通常指向配置内容而不是「上次写坏了」。临时文件 + `mv -f` 是同一文件系统内的原子替换。

`fs_ensure_*` 系列也都走原子写，并且用 `cp -p` 保住原文件权限 —— 直接 `echo >>` 遇到
权限 600 的文件会把它变成 644，这是最常见的「改个配置把密钥文件权限改了」事故。

## 5. 库不改调用方的 shell 选项，也不改 cwd

`set -euo pipefail` 由**你的入口脚本**开，库不开。原因：库被 `source` 进来之后，
一旦它自己 `set -e`，调用方那些「故意允许失败」的写法（`grep -q x || true`）就会变味。

同理，库不 `cd`。需要临时换目录的函数都在子 shell 里做：

```bash
# 库内部的写法：括号 = 子 shell，cwd 变化不外泄
( cd "$dir" && tar -czf "$out" . )
```

你可以在入口脚本里放心开 `set -euo pipefail`，库不会把它关掉，也不会加别的全局副作用。

但有一条要跟 `pipefail` 一起想清楚：**它会改变管道的语义**。`grep -q` 命中就退出，管道上游
还在往里写，于是上游被 SIGPIPE 打死（退出码 141）。平时看不出来 —— 141 只出现在
`PIPESTATUS` 里；可 `pipefail` 让整条管道按 141 判失败，于是「查到了」变成「没查到」。
库内部因此不写「上游可能多行输出、消费者提前退出」的管道：

```bash
# 危险：grep -q 命中即退，上游可能被 SIGPIPE 打死（141）
man_modules | grep -qx "$name"

# 稳妥：让消费者读完整个输入
man_modules | grep -x "$name" >/dev/null
```

你自己脚本里开 `pipefail` 之前也过一遍这条：`cmd | grep -q` 里的 `cmd` 如果可能输出多行，
就改成 `grep -q 模式 文件`，或者让 `grep` 读完整个输入。

## 相关的两条实践

- **失败要带既定退出码**，不要一律 `exit 1`。见 [故障排查](./troubleshooting.md) 的退出码表。
- **删东西要留退路**。`shellkit uninstall-self` 依赖 MANIFEST，`fs_ensure_symlink` 绝不覆盖普通文件，
  都是同一个思路：不确定的时候不猜。
