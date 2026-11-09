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

log_debug MSG... —— 仅在 SHELLKIT_DEBUG=1 或 SHELLKIT_LOG_LEVEL=debug 时输出

### `log_section`

log_section TITLE —— 分段标题，带前导空行 json 模式下什么都不输出：JSON 行是给采集器消费的，标题没有 level 语义， 混进去会破坏「一行一条记录」的约定。文本模式保持原样。

## error

### `die`

die CODE MSG... —— CODE 必须是 0-255；不合法按用法错误退出 2，而不是让 exit 截成 255

### `fail`

fail CODE MSG...  —— 不退出，只返回码；CODE 校验同 die

### `require_cmd`

require_cmd CMD... —— 零参数返回 SK_USAGE（否则 `require_cmd "$EMPTY"` 会静默通过）

### `require_root`

require_root —— 必须是 root 运行；否则返回 SK_PRECOND(3)

### `require_file`

require_file PATH... —— 零参数返回 SK_USAGE

### `require_bash`

require_bash MAJOR [MINOR] —— 当前 bash 版本是否达标；不达标返回 SK_PRECOND(3)

## str

### `str_trim`

str_trim VAR —— 去掉首尾空白，原地改写该变量

### `str_lower`

str_lower VAR —— 转小写，原地改写该变量（3.2 没有大写展开语法）

### `str_upper`

str_upper VAR —— 转大写，原地改写该变量（3.2 没有大写展开语法）

### `str_contains`

str_contains HAYSTACK NEEDLE —— 返回码；空 needle 恒返回 1

### `str_starts_with`

str_starts_with STR PREFIX —— 前缀匹配；用返回码而不是布尔值

### `str_ends_with`

str_ends_with STR SUFFIX —— 后缀匹配；用返回码而不是布尔值

### `str_repeat`

str_repeat VAR COUNT STRING —— 把字符串重复 N 次写进变量

## validate

### `validate_not_empty`

validate_not_empty VALUE —— 非空校验；失败原因写进 SK_VALIDATE_ERR

### `validate_single_line`

validate_single_line VALUE —— 单行文本；配置项的值不允许带换行 —— 配置文件的值不允许换行

### `validate_key`

validate_key VALUE —— 合法配置键名

### `validate_port`

validate_port VALUE —— 1-65535 的端口号

### `validate_ip`

validate_ip VALUE —— 四段十进制，每段 0-255，且不接受前导零（010 会被当成八进制）

### `validate_version`

validate_version VALUE —— x.y.z 或 v1.2.3 形式的版本号

### `validate_abs_path`

validate_abs_path VALUE —— 绝对路径

### `validate_url`

validate_url VALUE —— http/https URL

### `validate_enum`

validate_enum VALUE "a|b|c" —— 取值必须在给定集合内

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

## fs

### `fs_ensure_dir`

fs_ensure_dir DIR [MODE] —— 幂等建目录；给了 MODE 就 chmod

### `fs_atomic_write`

fs_atomic_write FILE CONTENT [MODE] —— 原子写文件；默认权限 600，父目录不存在会先建

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

os_is_root —— 当前是否以 root 身份运行

### `os_has_cmd`

os_has_cmd CMD... —— 零参数返回 SK_USAGE（空真会让前置检查静默通过）

### `os_pkg_manager`

os_pkg_manager —— 本机的包管理器名（apt-get/yum/dnf/zypper/apk）；没有则返回 1

### `os_pkg_update`

os_pkg_update —— 刷新包索引；没有受支持的包管理器返回 SK_PRECOND(3)

### `os_pkg_install`

os_pkg_install PKG... —— 用本机包管理器装包；没有受支持的包管理器返回 SK_PRECOND(3)

### `os_sed_i`

os_sed_i ARGS... —— 就地编辑；Darwin 的 sed 必须给个备份后缀

### `os_md5`

os_md5 FILE —— 文件的 md5；两种工具都没有时返回 1

### `os_sha256`

os_sha256 FILE —— 文件的 sha256；两种工具都没有时返回 1

## scaffold

### `scaffold_vars_set`

scaffold_vars_set KEY VALUE —— 设一个模板变量

### `scaffold_vars_get`

scaffold_vars_get KEY [DEFAULT] —— 读一个模板变量；未设置时给默认值

### `scaffold_vars_list`

scaffold_vars_list —— 逐行输出 KEY=VALUE

### `scaffold_config_load`

scaffold_config_load FILE —— 从 template.config 载入模板变量 格式与 conf 模块一致：KEY=VALUE，# 开头是注释。 值为空是合法的（表示「这个变量默认没有值，生成时问用户」）。

### `scaffold_render`

scaffold_render SRC DST —— 用当前模板变量渲染文件 未声明的 {{KEY}} 原样保留（这样模板里的示例占位符不会被误伤）。 返回非 0 表示没写出来，调用方必须判。

### `scaffold_manifest_write`

scaffold_manifest_write DIR NAME COMDS TEMPLATE_VERSION FILELIST 写 DIR/.shellkit-manifest。FILELIST 是换行分隔的相对路径（模板自有的文件）， 每个文件记一个 sha256 —— 升级时靠它判断「这个文件用户动过没有」。

### `scaffold_manifest_read`

scaffold_manifest_read DIR —— 读 DIR/.shellkit-manifest 标量进 SK_MANIFEST_* 公开变量，@var 条目进模板变量表。

### `scaffold_manifest_get`

scaffold_manifest_get KEY —— 读 manifest 里的一个标量

### `scaffold_manifest_list_files`

scaffold_manifest_list_files —— 逐行输出模板自有的文件（相对路径）

### `scaffold_manifest_file_sum`

scaffold_manifest_file_sum DIR RELPATH —— 读 manifest 里记的某个文件的 sha256

### `scaffold_run_hook`

scaffold_run_hook FILE PROJECT_DIR —— 跑一个模板钩子 钩子是模板目录里的可执行脚本（template.hooks.d/pre、template.hooks.d/post）。 环境变量里会带上：SHELLKIT_PROJECT_DIR / SHELLKIT_PROJECT_NAME / SHELLKIT_PROJECT_COMMANDS / SHELLKIT_TEMPLATE_VERSION，以及每个模板变量。 钩子不存在就跳过；不可执行就跳过并告警（不因为钩子没设执行位就让生成失败）。

## run

### `run`

run [--always] [--no-die] CMD... —— 执行命令，失败即 die；--no-die 只返回码

### `run_concurrent`

run_concurrent N [--timeout SEC] -- CMD... —— 把同一条命令并发跑 N 份 典型用法：对一批目标跑同一个动作（每个实例自己从环境变量读目标）。   run_concurrent 8 -- ./deploy.sh "$target" 输出约定（stdout 只给数据）：   stdout —— 成功实例的数量，一个整数，便于直接 $(...) 取走   stderr —— 每个实例的 stdout/stderr，逐行带 [i/N] 前缀；失败明细也在这里 返回码：全部成功返回 0；有实例失败则返回第一个失败实例的退出码。 注意：这里不用 die —— die 的 exit 在 if / || 里会退出整个 shell。

## retry

### `retry`

retry ATTEMPTS CMD... —— 失败退避重试；用法错与校验失败不重试

## lock

### `lock_acquire`

lock_acquire NAME [WAIT_SEC] —— 0 成功；SK_PRECOND 被占用/超时；SK_USAGE 名字非法

### `lock_release`

lock_release NAME —— 只释放自己持有的锁

### `lock_held`

lock_held NAME —— 返回码判断是否被占；被占时 stdout 输出持有者 pid

## net

### `net_sha256`

net_sha256 FILE —— 文件的 sha256；两种工具都没有时返回 1

### `net_verify`

net_verify FILE SHA256 —— 校验文件的 sha256；对不上返回 SK_VERIFY(5)

### `net_download`

net_download URL DEST [SHA256] —— 下载并可选校验 sha256；已有本地缓存且校验通过就不重下

### `net_wait_port`

net_wait_port HOST PORT [TIMEOUT] —— 等端口可连；超时返回 SK_NET(4)

### `net_wait_http`

net_wait_http URL [TIMEOUT] —— 等 HTTP 可用；超时返回 SK_NET(4)

## http

### `net_request`

METHOD 不区分大小写；请求完成返回 0，状态码不算错误。

**参数**

- METHOD HTTP 方法（GET/POST/...）
- URL 目标地址
- --header 'K: V' 请求头，可重复
- --data STR 请求体
- --json STR 请求体；自动补 Content-Type: application/json
- --timeout SEC 总超时，默认 30
- --connect-timeout SEC 连接超时，默认 10
- --output FILE 响应体写文件而不是放进 SK_HTTP_BODY

**退出码**

- 0 请求完成（状态码看 SK_HTTP_CODE）
- 2 参数错
- 3 没有 curl
- 4 网络层失败（连不上、超时、DNS 失败）

**参见**

- `net_json`

### `net_json`

有 jq 用 jq，有 python3 用 python3，都没有返回 SK_PRECOND(3)。

**参数**

- --path KEY 点号路径（data.items.0.name）；不给就输出整个 JSON 文本

**退出码**

- 0 取到了值
- 2 参数错
- 3 没有 jq 也没有 python3
- 4 网络层失败
- 5 响应不是合法 JSON，或路径取不到

**参见**

- `net_request`

### `net_escape_json`

优先 jq，其次 python3；都没有时走内置降级路径。

**参数**

- TEXT 原始文本

**退出码**

- 0 转义成功

**参见**

- `net_json`

## config

### `conf_init`

conf_init FILE [--format env|dotenv] —— 载入配置文件；文件不存在不报错（当成空配置） --format 决定文件怎么解析：auto（默认，老行为 + 容忍 dotenv 写法）、 env（严格 KEY=VALUE）、dotenv（完整 dotenv 语义）。 严格格式（env / dotenv）下不合规的行会在载入时报警并跳过。

### `conf_file`

conf_file —— 当前生效的配置文件路径；未初始化时为空

### `conf_format`

conf_format —— 当前生效的配置格式（auto|env|dotenv）

### `conf_get`

conf_get KEY [DEFAULT] —— 只输出值；未初始化或无文件时返回默认值 取值顺序：配置层 > 配置文件。键存在但值为空时返回空串，不回落默认值。

### `conf_has`

conf_has KEY —— 返回码 0/1

### `conf_get_any`

conf_get_any KEY [DEFAULT] —— 环境变量 > 配置层 > 配置文件 > 默认值

### `conf_load_dotenv`

conf_load_dotenv FILE —— 把 dotenv 文件的键值载入配置层 解析规则：空行与 '#' 开头的行忽略；允许行首 export 前缀；键必须是合法变量名； 成对的单/双引号剥掉（引号内内容原样保留，不解释转义）；未加引号的值去行尾空白、 保留中间空格；KEY= 是"键存在且值为空"；同一文件里后出现的键覆盖先出现的。 取舍：只进配置层，不 export 到调用方的环境变量 —— 环境变量优先级最高， 往里塞东西会盖掉调用方自己的设置。确实要导出时用 conf_source。 非法行跳过并告警，不整体失败。文件不存在返回 SK_PRECOND。

### `conf_source`

conf_source FILE —— 把 dotenv 文件的键导出为环境变量（供子进程继承） 与 conf_load_dotenv 的区别：这里明确要 export，所以只导环境变量，不进配置层。

### `conf_set`

conf_set KEY VALUE —— 校验 + 值未变则跳过 + 原子写 + 600

### `conf_unset`

conf_unset KEY —— 删掉一个键；幂等，键不存在也算成功

### `conf_disable`

conf_disable KEY —— 把 KEY=VALUE 改成注释行，保留原值

### `conf_keys`

conf_keys —— 逐行输出键名（配置层的键在前，文件里的键在后，不重复）

## prompt

### `ask`

ask VAR PROMPT [DEFAULT] [TIMEOUT] —— 问一个问题，把答案写进 VAR；超时或 EOF 回退默认值

### `ask_yn`

ask_yn VAR PROMPT [DEFAULT=y] [TIMEOUT] —— 结果写入 y 或 n

### `ask_choice`

ask_choice VAR PROMPT "a|b|c" [DEFAULT] [TIMEOUT] —— 多选一；超时或 EOF 回退默认值

### `confirm`

confirm PROMPT [DEFAULT=n] [TIMEOUT] —— 只返回码

## cli

### `cli_group`

cli_group TITLE —— 后续注册的命令归入该分组

### `cli_cmd`

cli_cmd NAME DESC [USAGE] —— 注册一个子命令；要写在命令文件末尾

### `cli_has`

cli_has NAME —— 该命令是否已注册

### `cli_usage_cmd`

cli_usage_cmd NAME —— 打印单个子命令的用法行

### `cli_usage_global`

cli_usage_global —— 打印总用法：命令按分组，选项固定五条

### `cli_completion_script`

cli_completion_script [bash|zsh] —— 生成补全脚本 子命令名取自注册表，所以新加一个 cli_cmd，补全里自动就有了 —— 不用像别的框架那样单独维护一份命令列表。 程序名取 SK_PROG（生成出来的工程可以在自己的入口里设成自己的名字）。

### `cli_run`

cli_run ARGS... —— 分发入口：吃全局选项后按名字找同名 cmd_ 前缀的函数

### `cli_opt_init`

cli_opt_init —— 清空选项注册表。不接受参数；变量默认值请自己先赋好

### `cli_opt`

cli_opt VAR LONG [SHORT] [TAKES_ARG] —— 注册一个选项；第四个参数为 1 表示这个选项要吃值

### `cli_opts`

cli_opts ARGS... —— 按 cli_opt 注册的规则解析子命令选项；剩余位置参数进 SK_OPTS_LEFT

