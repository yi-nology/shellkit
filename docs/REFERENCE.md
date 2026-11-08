# API 参考

> 由 tools/shdoc.sh 从源码注释生成，请勿手工编辑。改完注释跑 shellkit docs。
>
> 函数上方注释块的第一行即摘要；@brief / @param / @exitcode / @example / @see 可选，@internal 表示不导出。

## error

### `die`

die CODE MSG... —— CODE 必须是 0-255；不合法按用法错误退出 2，而不是让 exit 截成 255

### `fail`

fail CODE MSG...  —— 不退出，只返回码；CODE 校验同 die

### `require_cmd`

require_cmd CMD... —— 零参数返回 SK_USAGE（否则 `require_cmd "$EMPTY"` 会静默通过）

### `require_root`

require_root

### `require_file`

require_file PATH... —— 零参数返回 SK_USAGE

### `require_bash`

require_bash MAJOR [MINOR]

## log

### `log_info`

log_info MSG... —— 普通信息

### `log_ok`

log_ok MSG... —— 成功；单独用 " OK " 是为了和四字母级别对齐

### `log_warn`

log_warn MSG... —— 警告，不中断

### `log_error`

log_error MSG... —— 输出错误（stderr），并把最后一条错误记进 SK_ERRMSG

### `log_debug`

log_debug MSG... —— 仅在 SHELLKIT_DEBUG=1 时输出

### `log_section`

log_section TITLE —— 分段标题，带前导空行

## str

### `str_trim`

str_trim VAR

### `str_lower`

str_lower VAR

### `str_upper`

str_upper VAR

### `str_contains`

str_contains HAYSTACK NEEDLE —— 返回码；空 needle 恒返回 1

### `str_starts_with`

str_starts_with STR PREFIX

### `str_ends_with`

str_ends_with STR SUFFIX

### `str_repeat`

str_repeat VAR COUNT STRING

## validate

### `validate_not_empty`

validate_not_empty VALUE

### `validate_single_line`

validate_single_line VALUE —— 配置文件的值不允许换行

### `validate_key`

validate_key VALUE —— 合法配置键名

### `validate_port`

validate_port VALUE

### `validate_ip`

validate_ip VALUE —— 四段十进制，每段 0-255，且不接受前导零（010 会被当成八进制）

### `validate_version`

validate_version VALUE

### `validate_abs_path`

validate_abs_path VALUE

### `validate_url`

validate_url VALUE

### `validate_enum`

validate_enum VALUE "a|b|c"

## fs

### `fs_ensure_dir`

fs_ensure_dir DIR [MODE]

### `fs_atomic_write`

fs_atomic_write FILE CONTENT [MODE]

### `fs_backup`

fs_backup FILE [KEEP] —— 产出 FILE.bak.YYYYmmddHHMMSS，按名升序保留最新 KEEP 份

### `fs_ensure_line`

fs_ensure_line FILE LINE —— 整行精确匹配；不存在才追加。幂等。

### `fs_ensure_block`

fs_ensure_block FILE BEGIN END CONTENT —— 标记块内内容整体替换；没有就追加。幂等。

### `fs_ensure_symlink`

fs_ensure_symlink TARGET LINK —— 已是正确链接则不动；否者替换（绝不覆盖普通文件）

### `fs_tmpdir`

fs_tmpdir —— 确保临时目录存在并输出路径。 目录名按 UID+进程号确定，因此同一进程内的 $(...) 子 shell 拿到的是同一个目录； 它不注册 trap，外部有 EXIT 需求请用 fs_tmp_init。

### `fs_tmp_init`

fs_tmp_init —— 在当前 shell 初始化临时目录，并把清理动作推进清理栈。 与 0.1.0 的差别：以前「调用方已有 EXIT trap 就放弃清理」，现在改为入栈， 与调用方自己的 trap 共存（trap_install 会链式保留已有 EXIT trap）。

## os

### `os_name`

os_name —— linux | darwin | other

### `os_arch`

os_arch —— x86_64 | aarch64 | other

### `os_is_root`

os_is_root

### `os_has_cmd`

os_has_cmd CMD... —— 零参数返回 SK_USAGE（空真会让前置检查静默通过）

### `os_pkg_manager`

os_pkg_manager

### `os_pkg_update`

os_pkg_update

### `os_pkg_install`

os_pkg_install PKG...

### `os_sed_i`

os_sed_i ARGS... —— 就地编辑；Darwin 的 sed 必须给个备份后缀

### `os_md5`

os_md5 FILE

### `os_sha256`

os_sha256 FILE

## trap

### `trap_push`

trap_push CMD... —— 注册一个清理动作；后注册的先执行

### `trap_pop`

trap_pop —— 丢弃最近注册的一个动作（不执行）

### `trap_list`

trap_list —— 逐行输出已注册的动作（调试用）

### `trap_cleanup`

trap_cleanup —— 逆序执行全部清理动作；幂等；单个失败不中断其余

### `trap_install`

trap_install —— 安装 EXIT / INT / TERM / HUP 处理器；可重复调用 幂等性不能用标志位：子 shell 会继承变量，却不会继承「会执行」的 trap， 于是「以为装过了、其实没装」，退出时清理不执行。 也不能只靠「当前 shell 里有没有这个 trap」判断 —— bash 5 起，子 shell 里 `trap -p EXIT` 仍会显示父 shell 设的 trap（实测 5.3：看得见、但子 shell 退出时 不执行），而 bash 3.2 显示为空。只查 trap -p 会在 bash 5 的子 shell 里静默漏装， 表现为「( ... ) 里的 lock_acquire 拿到锁却没在退出时释放」。 所以：我们自己装的 trap（含子 shell 里的残影）一律重装一遍（重装同处理器无害）， 并且绝不把它当成「调用方原有的 handler」捕获下来，否则清理时会自噬。

## run

### `run`

run [--always] [--no-die] CMD... —— 执行命令，失败即 die；--no-die 只返回码

## retry

### `retry`

retry ATTEMPTS CMD...

## lock

### `lock_acquire`

lock_acquire NAME [WAIT_SEC] —— 0 成功；SK_PRECOND 被占用/超时；SK_USAGE 名字非法

### `lock_release`

lock_release NAME —— 只释放自己持有的锁

### `lock_held`

lock_held NAME —— 返回码判断是否被占；被占时 stdout 输出持有者 pid

## net

### `net_sha256`

net_sha256 FILE

### `net_verify`

net_verify FILE SHA256

### `net_download`

net_download URL DEST [SHA256]

### `net_wait_port`

net_wait_port HOST PORT [TIMEOUT]

### `net_wait_http`

net_wait_http URL [TIMEOUT]

## config

### `conf_init`

conf_init FILE

### `conf_file`

conf_file

### `conf_get`

conf_get KEY [DEFAULT] —— 只输出值；未初始化或无文件时返回默认值

### `conf_has`

conf_has KEY —— 返回码 0/1

### `conf_get_any`

conf_get_any KEY [DEFAULT] —— 环境变量 > 配置文件 > 默认值

### `conf_set`

conf_set KEY VALUE —— 校验 + 值未变则跳过 + 原子写 + 600

### `conf_unset`

conf_unset KEY

### `conf_disable`

conf_disable KEY —— 把 KEY=VALUE 改成注释行，保留原值

### `conf_keys`

conf_keys —— 逐行输出键名

## prompt

### `ask`

ask VAR PROMPT [DEFAULT] [TIMEOUT]

### `ask_yn`

ask_yn VAR PROMPT [DEFAULT=y] [TIMEOUT] —— 结果写入 y 或 n

### `ask_choice`

ask_choice VAR PROMPT "a|b|c" [DEFAULT] [TIMEOUT]

### `confirm`

confirm PROMPT [DEFAULT=n] [TIMEOUT] —— 只返回码

## cli

### `cli_group`

cli_group TITLE —— 后续注册的命令归入该分组

### `cli_cmd`

cli_cmd NAME DESC [USAGE]

### `cli_has`

cli_has NAME

### `cli_usage_cmd`

cli_usage_cmd NAME —— 打印单个子命令的用法行

### `cli_usage_global`

cli_usage_global —— 打印总用法：命令按分组，选项固定五条

### `cli_run`

cli_run ARGS...

### `cli_opt_init`

cli_opt_init —— 清空选项注册表。不接受参数；变量默认值请自己先赋好

### `cli_opt`

cli_opt VAR LONG [SHORT] [TAKES_ARG]

### `cli_opts`

cli_opts NAME ARGS... —— 按 cli_opt 注册的规则解析子命令选项

