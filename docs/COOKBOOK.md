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

## 14. 拿不准的时候

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
