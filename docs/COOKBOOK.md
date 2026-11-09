# Cookbook：按任务查

每节都是「场景 → 可以抄的代码 → 为什么这么写」。代码块都是能跑的片段，不是伪代码。

需要某个函数的完整签名与退出码，查 [REFERENCE.md](REFERENCE.md)。

## 1. 读配置：优先级一次写对

**场景**：脚本要读 `HOST` / `PORT`，希望用户在命令行、环境变量、配置文件三种地方都能覆盖。

```bash
conf_init "${CONFIG_FILE:-./config}" || exit $?

host=$(conf_get_any HOST 127.0.0.1)
port=$(conf_get_any PORT 8080)

log_info "target $host:$port"
```

**为什么**：`conf_get_any` 的优先级是**显式参数 > 环境变量 > 配置文件 > 默认值**，
四层一次到位。自己写 `grep` 拼这套逻辑，十个脚本会有十种优先级顺序。

## 2. 改配置：原子、幂等、不动权限

**场景**：脚本要把某个值写进配置文件，可能重复运行，也可能配错要回退。

```bash
fs_backup /etc/myapp/conf 5 || die "backup failed"
conf_set PORT 9090 || exit $?

fs_ensure_line /etc/hosts "10.0.0.5 db" || exit $?
```

**为什么**：三个动作各自解决一个真问题 ——

- `fs_backup` 在改之前留一份，按时间戳命名、只保留最新 5 份，不会把磁盘堆满。
- `conf_set` 值是单行就校验、**值没变就不写盘**（所以重复运行不会改 mtime），
  写入走临时文件 + `mv -f`，权限固定 600。
- `fs_ensure_line` 是整行精确匹配，有则一字不动。

不要用 `echo "PORT=9090" >> conf`：重复运行会写出十行重复配置，而且会把 600 的文件
静默改成 644。

## 3. 下载并校验

**场景**：从上游拿一个压缩包，要能校验、要能走内网镜像。

```bash
sha=9f2c...e1
if ! net_download "https://example.com/app-1.2.3.tar.gz" "$workdir/app.tar.gz" "$sha"; then
  die "download failed"
fi

net_verify "$workdir/app.tar.gz" "$sha" || die "checksum mismatch"
```

**为什么**：`net_download` 自带三件事 —— sha256 校验（不匹配返回 5）、已存在且校验通过
就不重复下载、以及按 `SHELLKIT_MIRROR_FROM` / `SHELLKIT_MIRROR_TO` 做镜像前缀替换后重试。
内网环境只需要设两个环境变量，不用改脚本。

## 4. 等端口 / 等 HTTP

**场景**：`systemctl restart` 返回 0 不等于服务真的起来了。

```bash
run systemctl restart myapp

net_wait_port 127.0.0.1 8080 30 || die "port 8080 did not open in 30s"
net_wait_http http://127.0.0.1:8080/healthz 30 || die "health check failed"
log_ok "myapp is up"
```

**为什么**：`run` 负责「命令失败就带着原文和退出码死给你看」，`net_wait_*` 负责
「命令成功了但服务还没就绪」。这两个是不同的问题，混在一起写就会出现那种
「重启成功但用户访问 502」的部署。

## 5. 单实例并发

**场景**：定时任务重叠执行会把状态搞乱，要保证同时只有一个在跑。

```bash
lock_acquire deploy 30 || die "another deploy is running"

trap_push "lock_release deploy"
trap_install

run ./actually-do-the-work
```

**为什么**：锁是 `mkdir` 的原子性实现的（macOS 没有 `flock`，这样两台机器上行为一致）。
`lock_acquire` 拿到锁就自动入清理栈，所以**即使脚本被 kill -9 之外的方式中断**也会释放；
`trap_install` 让清理真的在 EXIT / INT / TERM / HUP 时跑。

`lock_acquire` 会自己装 trap，这里的 `trap_install` 是为了让 `lock_release` 这个动作也进栈 ——
两者都幂等，重复调用无害。

## 6. 失败即停 + 退出时收尾

**场景**：脚本要在退出时删临时目录、恢复现场，不管成功还是失败。

```bash
fs_tmp_init
workdir=$(fs_tmpdir)

trap_push "rm -rf \"$workdir\""
trap_install

run ./build-in "$workdir"
```

**为什么**：清理栈是 LIFO —— 后注册的先跑，正好对应「后申请的资源先释放」。
单个清理动作失败只报警告、不影响其余动作，也**不改脚本真实的退出码**。
这一条很关键：`trap_install` 的 EXIT 处理器会先存下 `$?`，跑完清理再原样 `exit`。

**要自己判成败就加 `--no-die`**：

```bash
# 探活失败不是错误，只是「没在跑」
if run --no-die systemctl is-active --quiet nginx; then
  log_info "nginx 在跑"
else
  log_warn "nginx 没在跑，准备启动"
  run systemctl start nginx
fi

run --no-die curl -fsS "$health_url" >/dev/null || log_warn "健康检查没过，继续"
```

默认的 `run` 失败时走 `die`，而 `die` 里的 `exit` **不受 `if` / `||` 约束** —— 也就是说
`if run cmd; then` 的 else 分支永远走不到，整个脚本直接退。这正是 `--no-die` 存在的理由：
它只返回命令的退出码，不退出 shell。

## 7. 重试

**场景**：拉取一个偶尔超时的接口。

```bash
SHELLKIT_RETRY_DELAY=2 SHELLKIT_RETRY_BACKOFF=2 retry 5 \
  curl -fsS "https://api.example.com/status" -o "$workdir/status.json" \
  || die "still failing after 5 attempts"
```

**为什么**：默认从 1 秒起、每次翻倍、上限 30 秒；**用法错（2）与校验失败（5）默认不重试** ——
参数写错了重试五次只是浪费日志。`SHELLKIT_RETRY_ON` 可以改这个集合。

**首次延迟同样受上限约束**：`SHELLKIT_RETRY_DELAY=100 SHELLKIT_RETRY_MAX_DELAY=5` 时第一次就等 5 秒
（不是 100 秒后才发现上限生效）。所以「初始给个大值、上限兜住」是安全的写法。

## 8. 装成 systemd 服务

**场景**：把产物装成一个开机自启的服务，脚本要能重复跑。

```bash
unit=/etc/systemd/system/myapp.service

fs_atomic_write "$unit" "[Unit]
Description=myapp
After=network.target

[Service]
ExecStart=/opt/myapp/bin/myapp
Restart=on-failure

[Install]
WantedBy=multi-user.target
" 644 || die "cannot write $unit"

run systemctl daemon-reload
run systemctl enable myapp
run systemctl restart myapp
net_wait_port 127.0.0.1 8080 30 || die "service did not come up"
```

**为什么**：`fs_atomic_write` 保证不会写出半个单元文件（写一半被中断时 systemd 会读到残片），
`644` 是单元文件该有的权限。装完必须 `daemon-reload`，这一步最容易漏。

## 9. 加一个子命令

**场景**：工具已经有 `start` / `stop`，现在要加 `deploy`，带一个 `--force`。

```bash
cli_group "运维"
cli_cmd deploy "部署服务" "deploy [--force] <target>"

cmd_deploy() {
  local force=""
  cli_opt_init force ""
  cli_opt force --force -f
  cli_opts "$@" || return $?

  local target=${SK_OPTS_LEFT[0]:-}
  [ -n "$target" ] || {
    log_error "missing target"
    return "$SK_USAGE"
  }

  log_info "deploying $target (force=$force)"
}

cli_run "$@"
```

**为什么**：注册 `cli_cmd` + 写 `cmd_deploy` 就够了，分发是 `declare -F` 动态查的，
没有需要同步的 switch。命令名带短横会自动派发到下划线函数名。
未知命令会按前缀给候选（`depl` 会提示 `Did you mean: deploy`）。

## 10. 非交互与超时

**场景**：脚本既要在终端里问人，也要能在 CI 里无人值守跑。

```bash
ask_choice mode "选择模式" "fast|safe" safe 10 || die "no answer"
if ask_yn proceed "继续?" y 10; then
  log_info "mode=$mode proceed=$proceed"
fi

confirm "重建索引?" n 10 || die "aborted"
```

**为什么**：三者都有超时和默认值，超时会回退到默认值而不是挂死；EOF（管道里没有输入）
与超时是分开处理的。设 `SHELLKIT_NONINTERACTIVE=1` 或传 `-y`，所有提问直接取默认值 ——
CI 里不用改脚本，加一个环境变量就够。

## 11. 日志纪律：stdout 只给数据

**场景**：脚本既输出结果，又要能让人看到过程。

```bash
port=$(conf_get_any PORT 8080)

printf '%s\n' "$port"
log_info "using port $port"
```

**为什么**：只要有一行日志混进 stdout，`port=$(你的脚本)` 拿到的就是脏值。
这条不是风格，是**接口**：库自身所有 `log_*` 都写 stderr，你的脚本也照做，
调用方才敢用命令替换。

## 12. 中英双语

**场景**：脚本要给两种语言的用户看。

```bash
path=/etc/myapp/conf
if [ ! -f "$path" ]; then
  log_error "$(_t 'config file not found'): $path"
  exit "$SK_PRECOND"
fi
```

**为什么**：msgid 一律写英文，译文放 `locale/<lang>/LC_MESSAGES/shellkit.po`。
没装 gettext 或没有对应语言时原样输出英文，**不会失败**。
新增 msgid 后跑 `bash po/messages.sh` 重抽并编译。

## 13. 写测试

**场景**：给上面的脚本加一个测试，还要能测「网络失败」这种分支。

```bash
. "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
. "$TEST_ROOT/lib/bootstrap.sh"

assert_eq "x" "$(str_trim '  x  ')" "trims surrounding spaces"

stub curl "exit 22"
assert_exit_code 4 net_download "https://example.com/x" "$TEST_TMP_ROOT/x"
assert_stub_called curl 1
```

**为什么**：`tests/run.sh` 逐个 `bash` 执行测试文件，不依赖 bats。
`stub` 把命令换成可断言的行为并记录调用次数 —— 没有它，下载失败、镜像回退、
校验不匹配这三条分支永远测不到，只能「看代码觉得对」。

## 14. 调 REST 接口：网络错和业务错分开看

**场景**：脚本要调一个后端接口，并且区分「请求根本没发出去」和「对方返回了 4xx / 5xx」。

```bash
token=$(conf_get_any API_TOKEN "")

net_request GET "https://api.example.com/v1/users/me" \
  --header "Authorization: Bearer $token" \
  --timeout 10 || die "request failed"

case "$SK_HTTP_CODE" in
  2*) log_ok "ok: $SK_HTTP_BODY" ;;
  4*) die "bad request: $SK_HTTP_BODY" ;;
  5*) die "server error: $SK_HTTP_CODE" ;;
  *) die "unexpected status: $SK_HTTP_CODE" ;;
esac
```

**为什么**：`net_request` 的退出码只管**网络层** —— 0 是「请求完成了」，4 是「连不上 / 超时 / DNS 失败」，
2 是用法错，3 是缺 curl。**HTTP 状态码不算错误**：500 也返回 0。业务错误得自己看 `SK_HTTP_CODE`，
所以上面那段把两层分开判：4xx 是「请求写错了」，5xx 是「服务端炸了」，处理方式完全不同。

出参是三个全局变量 —— `SK_HTTP_CODE`（状态码）、`SK_HTTP_BODY`（响应体）、`SK_HTTP_HEADERS`（响应头全文）——
所以 stdout 依旧是干净的，响应体再大也不会混进你的数据流。响应体很大时加 `--output FILE`，
body 直接落盘、`SK_HTTP_BODY` 就变空。`--json` 会自动补上 `Content-Type: application/json`；
`--connect-timeout` 管连上之前，`--timeout` 管整个请求。

## 15. 从 JSON 里取嵌套字段

**场景**：接口返回一大坨 JSON，只想拿其中一个字段（比如列表里第一项的名字）。

```bash
name=$(net_json GET "https://api.example.com/v1/users/me" --path "data.profile.name") ||
  die "cannot read profile"
log_info "name: $name"
```

要往回发 JSON，先把文本转义好：

```bash
note=$(net_escape_json "$user_note")
net_request POST "https://api.example.com/v1/notes" \
  --json "{\"text\":$note}" || die "post failed"
```

**为什么**：`--path` 走点号路径，数组下标也是一段（`data.items.0.name`）。取不到值返回 5 而不是 0，
所以「字段不存在」不会被当成「字段是空的」。解析器有 jq 用 jq、有 python3 用 python3，都没有返回 3 ——
库会先查解析器再发请求，没有解析器就不该把请求打出去。

拼请求体不要手写转义：`net_escape_json` 把任意文本变成**合法的 JSON 字符串字面量（含双引号）**，
所以 `"{\"text\":$note}"` 拼出来就是 `{"text":"..."}`，引号和反斜杠都替你处理了。

## 16. 读 dotenv：进配置层，还是 export 给子进程

**场景**：项目里有个 `.env`，要读它的值，但不想动调用方的环境变量。

```bash
conf_load_dotenv ./.env || die "no .env file"

host=$(conf_get_any API_HOST 127.0.0.1)
port=$(conf_get_any API_PORT 8080)
log_info "target $host:$port"
```

确实要让子进程继承的时候才 export：

```bash
conf_source ./.env || die "no .env file"

run ./bin/child --host "$API_HOST"
```

**为什么**：两个函数的区别只有一句话 —— `conf_load_dotenv` **只进配置层**，不 export：
环境变量优先级最高，往里塞东西会盖掉调用方自己设的值；`conf_source` 反过来，**明确要 export**，
只导环境变量、不进配置层。

所以「我读一下配置」用前者，「我要把这份配置交给子进程」用后者。两者都容忍脏数据：非法行跳过并告警，
不整体失败；文件不存在返回 3。解析格式有歧义时用 `conf_init ./config --format dotenv` 明确指定
（`env` / `dotenv` / `auto`）。

## 17. 日志送进采集系统

**场景**：本地看人类可读的日志，线上要把日志喂给采集器，还要按级别过滤。

```bash
export SHELLKIT_LOG_FORMAT=json
export SHELLKIT_LOG_LEVEL=warn
export SHELLKIT_LOG_FILE=/var/log/myapp.log

log_info "invisible at warn level"
log_warn "kept"
log_section "no section title in json mode"
```

一条日志长这样：

```text
{"ts":"2026-11-09T19:04:58+08:00","level":"WARN","msg":"kept"}
```

**为什么**：三个环境变量各管一件事 —— `SHELLKIT_LOG_LEVEL`（debug / info / warn / error，默认 info）
按级别过滤，`SHELLKIT_LOG_FORMAT=json` 换成一行一条紧凑 JSON，`SHELLKIT_LOG_FILE` 追加落盘。

json 模式下 `log_section` **不出声**：分段标题没有 level 语义，混进去就破坏了「一行一条记录」的约定，
采集器按行切会切出半截。日志仍然走 stderr（「stdout 只给数据」这条规矩不因为换格式就破），
文件写不进去只报错、不改退出码 —— 日志挂了不该让业务脚本跟着挂。

## 18. 同一条命令并发跑 N 份

**场景**：一批目标要跑同一个动作（给 20 台机器装同一个补丁），要并发不要排队。

```bash
ok=$(run_concurrent 8 --timeout 120 -- ./patch-one) || die "some instances failed"
log_info "succeeded: $ok / 8"
```

**为什么**：stdout 和 stderr 分开，这是它最要紧的地方 —— **stdout 只给一个整数：成功实例数**；
stderr 给每个实例的 stdout / stderr，逐行带 `[i/8]` 前缀。所以上面那行可以直接 `ok=$(...)` 取走，
而 8 份实例的输出仍然留在终端上，一眼看出是哪一份出的问题。

返回码是**第一个失败实例的退出码**（全过返回 0），所以 `|| die` 直接可用。它跟 `run` 的差别也在退出语义上：
`run` 失败即 `die`，而 `die` 里的 `exit` 在 `if` / `||` 里照样退整个 shell；
`run_concurrent` 只返回码，可以安全地放进条件里。

**注意它跑的是同一条命令 N 份，参数完全一样** —— 所以「每个实例一个不同目标」得让命令自己去领。
用 `mkdir` 领是最省事的一种（`mkdir` 是原子的，天然互斥）：

```bash
#!/usr/bin/env bash
# ./patch-one —— 每个实例自己领一个还没人领的目标
while read -r target; do
  if mkdir "$lockdir/claim.$target" 2>/dev/null; then
    ./apply-patch "$target"
    exit $?
  fi
done < "$targets_file"
```

`--timeout` 依赖系统的 `timeout`（macOS 上是 `gtimeout`）；两个都没有时只告警、不超时。

## 19. 生成工程时带上自己的变量和钩子

**场景**：用模板生成新工程，但工程名、命令名、说明文字要按项目来；生成前后还想跑自己的脚本。

```bash
shellkit new ./myapp --name myapp --cmd deploy --cmd status \
  --set DESCRIPTION="部署运维小工具" --yes
```

变量声明在模板目录的 `template.config`：

```text
# templates/template.config
DESCRIPTION=A command line tool
```

模板里用 `{{KEY}}` 引用；`--set` 覆盖默认值，`--yes` 跳过提问（没给值的变量留空）。

钩子放在模板目录的 `template.hooks.d/` 下：`pre` 在落盘前跑，`post` 在落盘后跑，各是一段可执行脚本。

```bash
#!/usr/bin/env bash
# templates/template.hooks.d/post
printf 'generated %s into %s\n' "$SHELLKIT_PROJECT_NAME" "$SHELLKIT_PROJECT_DIR"
```

**为什么**：`--set` 让「这个工程特有的东西」留在命令行上，不必改模板。钩子拿到的环境变量里有
`SHELLKIT_PROJECT_DIR` / `SHELLKIT_PROJECT_NAME` / `SHELLKIT_PROJECT_COMMANDS` /
`SHELLKIT_TEMPLATE_VERSION`，以及每个模板变量 —— 够写一个「生成完顺手装个 systemd 单元」之类的动作。

钩子没设执行位就跳过并告警，不会因为忘了 `chmod +x` 就让生成失败；钩子返回非 0 则生成失败，
这是故意的：钩子失败说明这个工程没成。

## 20. 让生成的工程跟上模板更新

**场景**：shellkit 出了新版本，之前生成的工程要跟上模板的改进。

```bash
shellkit upgrade ./myapp --check    # 只看会动哪些文件，不写盘
shellkit upgrade ./myapp             # 真改
```

**为什么**：生成时工程里落了一份 `.shellkit-manifest`，记着每个模板文件的 sha256。升级时逐个比对：
**指纹没变**（你没动过）就覆盖，**指纹变了**（你改过）就跳过并告警 `modified locally, left alone` ——
本地改动**永远不会被覆盖**。

`--check` 是空跑，只报「会更新哪个文件」，适合先看清楚再决定；确实想拿模板盖掉本地改动时用 `--force`。
你自己写的 `commands/` 和 `tests/test_smoke.sh` 不在模板自有清单里，升级根本不会碰。

## 21. 给自己写的 CLI 装上补全

**场景**：写了个自己的命令行工具，想让用户按 Tab 补出子命令。

```bash
shellkit completion bash >> "$HOME/.bash_completion"
source "$HOME/.bash_completion"

shellkit completion zsh > "$HOME/.zsh/completions/_shellkit"
```

工程里（自己的 CLI 框架）用库函数生成，程序名取 `SK_PROG`：

```bash
SK_PROG=myapp
cli_completion_script bash > myapp-completion.bash
```

**为什么**：补全脚本里的子命令列表是**从注册表生成的** —— 你 `cli_cmd` 注册了什么，补全里就有什么，
不用另维护一份命令清单（这是很多框架最烦的地方：加个子命令要改三个文件）。
`shellkit completion` 输出的是库自己那份（程序名 `shellkit`），`cli_completion_script` 输出的是给你自己的
CLI 用的，程序名取 `SK_PROG`。

## 22. 工程搬到别的机器上，也能自己升级

**场景**：工程里 vendor 了库，同事在另一台**没装 shellkit** 的机器上 clone 下来。

```bash
./vendor/shellkit/shellkit upgrade . --check   # 只看会动哪些文件
./vendor/shellkit/shellkit upgrade .             # 真改
```

**为什么**：`vendor` 出来的副本自带 CLI、模板与测试基建，所以「升级工程」不再依赖
PATH 上有没有 shellkit。副本里那份 CLI 用的就是同一份模板 —— 不会出现
「模板是新的、库是旧的」这种半吊子状态。

副本里也带 `--check`：`./vendor/shellkit/shellkit vendor . --check` 逐字节比对，
本地改过 vendor 就返回 5，正好放进 CI。

## 23. 拿不准的时候

| 你想做的事 | 先看哪里 |
|---|---|
| 有没有现成函数 | [REFERENCE.md](REFERENCE.md) 的模块小节 |
| 某个函数的退出码 | 同上，每个函数下的 `@exitcode` |
| 从旧脚本迁过来 | [MIGRATING.md](MIGRATING.md) 的五步渐进迁移 |
| 为什么要这条规矩 | README 的「五条硬约定」 |

交付前自检，三条同时成立才算过：**退出码 0**、**没有 FAIL 行**、**自己看过输出**。

```bash
bash -n ./my-script.sh
bash tests/run.sh
```


## 24. 把结果写进变量：出参的名字别撞上保留名

**场景**：脚本要把库函数的返回值写进自己的变量，比如把 `ask` 拿到的答案写进 `answer`。

```bash
answer=""
ask answer "服务名"           # 交互时读用户输入；非交互时回退默认值
log_info "服务名是 $answer"
```

**为什么**：出参函数（`ask` / `ask_yn` / `ask_choice` / `str_trim` / `cli_opt` …）靠
**变量名**把结果写回去。Bash 的 `printf -v` 写的是「最近一层声明了该名字的作用域」——
这个名字一旦和库内部某个局部变量同名，内容就写回库自己那层，你的变量还是旧值，
而且**不报错、不崩**，只是静默失效。

所以库把出参链路上出现过的局部变量名列成一份**保留名单**，用这些名字调用会当场返回 2
（用法错），而不是悄悄写丢：

```bash
ask __var "服务名"           # 退出码 2：__var 在保留名单里
ask __my_answer "服务名"     # 没问题：名单之外的名字（哪怕带 __ 前缀）照常能用
```

这份名单不是「`__` 前缀一律拒绝」——只有真正会撞车的名字在里面。
名单由 `tools/check_local_names.sh` 守着：库内部新增局部变量却忘了进名单，门禁就红。
