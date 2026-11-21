# 能力索引：库里有什么

> 生成物：由 `tools/shdoc.sh --index` 从源码注释生成（改完注释跑 `make docs`）。
> 每一行 = 一个公开函数 + 一句话。
> **这是「还有哪些能力」的答案** —— 落点表（SKILL.md）覆盖常用路径，
> 这里覆盖的是**全部**；要看签名与退出码再去 references/reference.md。

## log

- `log_info` MSG... —— 普通信息
- `log_ok` MSG... —— 成功；单独用 " OK " 是为了和四字母级别对齐
- `log_warn` MSG... —— 警告，不中断
- `log_error` MSG... —— 输出错误（stderr），并把最后一条错误记进 SK_ERRMSG
- `log_debug` MSG... —— 仅在 SHELLKIT_DEBUG=1 或 SHELLKIT_LOG_LEVEL=debug 时输出
- `log_section` TITLE —— 分段标题，带前导空行 json 模式下什么都不输出：JSON 行是给采集器消费的，标题没有 level 语义， 混进去会破坏「一行一条记录」的约定。文本模式保持原样。
## error

- `die` CODE MSG... —— CODE 必须是 0-255；不合法按用法错误退出 2，而不是让 exit 截成 255
- `fail` CODE MSG...  —— 不退出，只返回码；CODE 校验同 die
- `require_cmd` CMD... —— 零参数返回 SK_USAGE（否则 `require_cmd "$EMPTY"` 会静默通过）
- `require_root` —— 必须是 root 运行；否则返回 SK_PRECOND(3)
- `require_file` PATH... —— 零参数返回 SK_USAGE
- `require_bash` MAJOR [MINOR] —— 当前 bash 版本是否达标；不达标返回 SK_PRECOND(3)
## str

- `str_trim` VAR —— 去掉首尾空白，原地改写该变量
- `str_lower` VAR —— 转小写，原地改写该变量（3.2 没有大写展开语法）
- `str_upper` VAR —— 转大写，原地改写该变量（3.2 没有大写展开语法）
- `str_contains` HAYSTACK NEEDLE —— 返回码；空 needle 恒返回 1
- `str_starts_with` STR PREFIX —— 前缀匹配；用返回码而不是布尔值
- `str_ends_with` STR SUFFIX —— 后缀匹配；用返回码而不是布尔值
- `str_repeat` VAR COUNT STRING —— 把字符串重复 N 次写进变量
- `str_suggest` 距离相同时取先给的那个；没有候选时返回 1。
- `str_parse_indices` 区间写成 2-5 ⇒ 2 3 4 5；区间逆序（5-2）、越界（大于 MAX）、非数字一律判错。
## validate

- `validate_not_empty` VALUE —— 非空校验；失败原因写进 SK_VALIDATE_ERR
- `validate_single_line` VALUE —— 单行文本；配置项的值不允许带换行 —— 配置文件的值不允许换行
- `validate_key` VALUE —— 合法配置键名
- `validate_port` VALUE —— 1-65535 的端口号
- `validate_ip` VALUE —— 四段十进制，每段 0-255，且不接受前导零（010 会被当成八进制）
- `validate_version` VALUE —— x.y.z 或 v1.2.3 形式的版本号
- `validate_abs_path` VALUE —— 绝对路径
- `validate_url` VALUE —— http/https URL
- `validate_enum` VALUE "a|b|c" —— 取值必须在给定集合内
## trap

- `trap_push` CMD... —— 注册一个清理动作；后注册的先执行
- `trap_pop` —— 丢弃最近注册的一个动作（不执行）
- `trap_list` —— 逐行输出已注册的动作（调试用）
- `trap_cleanup` —— 逆序执行全部清理动作；幂等；单个失败不中断其余
- `trap_install` —— 安装 EXIT / INT / TERM / HUP 处理器；可重复调用 幂等性不能用标志位：子 shell 会继承变量，却不会继承「会执行」的 trap， 于是「以为装过了、其实没装」，退出时清理不执行。 也不能只靠「当前 shell 里有没有这个 trap」判断 —— bash 5 起，子 shell 里 `trap -p EXIT` 仍会显示父 shell 设的 trap（实测 5.3：看得见、但子 shell 退出时 不执行），而 bash 3.2 显示为空。只查 trap -p 会在 bash 5 的子 shell 里静默漏装， 表现为「( ... ) 里的 lock_acquire 拿到锁却没在退出时释放」。 所以：我们自己装的 trap（含子 shell 里的残影）一律重装一遍（重装同处理器无害）， 并且绝不把它当成「调用方原有的 handler」捕获下来，否则清理时会自噬。
## fs

- `fs_ensure_dir` DIR [MODE] —— 幂等建目录；给了 MODE 就 chmod
- `fs_atomic_write` FILE CONTENT [MODE] —— 原子写文件；默认权限 600，父目录不存在会先建 权限：MODE 给什么就是什么（默认 600），**覆盖已有文件也照样改**。 与 fs_atomic_copy 的分工：那个不传 MODE 时保留目标原权限，这个总是按 MODE 写 —— 「写内容」的场景（清单、配置）要的就是「权限是定死的」，不然改一次配置就把 权限改了。
- `fs_atomic_copy` SRC DST [MODE] —— 按字节把 SRC 复制到 DST；写法是原子的 与 fs_atomic_write 的分工：那个吃的是「内容」，命令替换会吃掉文件末尾的换行， 搬模板文件会变形；这个直接搬文件，逐字节一致。 为什么不用 cp：cp -f 先 truncate 目标再写 —— 写到一半被打断（断电、磁盘满、 进程被杀）留下的是**半截文件**，既不是旧内容也不是新内容；而且 cp 会跟随 **目标**的符号链接写穿，把内容写到别处去（链接本身纹丝不动，退出码还是 0）。 这里改成「写同目录的临时文件 → rename 过去」：rename 是原子的，失败要么 什么都没发生、要么整体换成新内容；它替换的是符号链接**本身**， 不会顺着链接写到别处。 权限：给了 MODE 就用它；不给时，目标是既有的普通文件就保留它的权限， 否则用源的权限（目标是符号链接时按源走 —— 这里替换的是链接本身）。 副作用：进程被中途杀掉时，目标目录里可能留下一个 `<DST>.tmp.XXXXXX` 的残留。
- `fs_backup` FILE [KEEP] —— 产出 FILE.bak.YYYYmmddHHMMSS，按名升序保留最新 KEEP 份 备份文件本身也是「同目录临时文件 + rename」写出来的：中途被打断时要么没有 这份备份、要么是一份完整可用的，不会留下半截内容去顶掉完好的旧备份。
- `fs_ensure_line` FILE LINE —— 整行精确匹配；不存在才追加。幂等。
- `fs_ensure_block` FILE BEGIN END CONTENT —— 标记块内内容整体替换；没有就追加。幂等。
- `fs_ensure_symlink` TARGET LINK —— 已是正确链接则不动；否者替换（绝不覆盖普通文件）
- `fs_tmpdir` —— 确保临时目录存在并输出路径。 目录名按 UID+进程号确定，因此同一进程内的 $(...) 子 shell 拿到的是同一个目录； 它不注册 trap，外部有 EXIT 需求请用 fs_tmp_init。
- `fs_tmp_init` —— 在当前 shell 初始化临时目录，并把清理动作推进清理栈。 与 0.1.0 的差别：以前「调用方已有 EXIT trap 就放弃清理」，现在改为入栈， 与调用方自己的 trap 共存（trap_install 会链式保留已有 EXIT trap）。
## run

- `run` [--always] [--no-die] [--secret-arg N] [--redact-value V] [--] CMD... —— 执行命令，失败即 die；--no-die 只返回码 命令行会进日志，敏感参数会被脱敏（键名像敏感字段、请求头、短选项 -u 等）。 启发式总会漏，所以还留了两个显式声明：   --secret-arg N     第 N 个参数（命令名不算）必脱敏，可以写多次   --redact-value V   值等于 V 的地方一律脱敏（令牌夹在参数中间也遮得到） 环境变量 SHELLKIT_SECRET_ARGS="2,3" 等价于 --secret-arg 2 --secret-arg 3， 对所有 run 生效 —— CI 里统一声明最省事。
- `run_concurrent` N [--timeout SEC] -- CMD... —— 把同一条命令并发跑 N 份 典型用法：对一批目标跑同一个动作（每个实例自己从环境变量读目标）。   run_concurrent 8 -- ./deploy.sh "$target" 输出约定（stdout 只给数据）：   stdout —— 成功实例的数量，一个整数，便于直接 $(...) 取走   stderr —— 每个实例的 stdout/stderr，逐行带 [i/N] 前缀；失败明细也在这里 返回码：全部成功返回 0；有实例失败则返回第一个失败实例的退出码。 注意：这里不用 die —— die 的 exit 在 if / || 里会退出整个 shell。
- `parallel_map` N [--timeout SEC] -- CMD... —— 把一批不同的目标分给 N 个并发实例 与 run_concurrent 明确区分：   run_concurrent —— 同一条命令并发跑 N 份（每个实例自己从环境变量读目标）   parallel_map   —— 每个实例跑一条不同的目标，条目从标准输入读 条目一行一个（空行跳过），每个实例执行的命令是「CMD... 条目」—— 条目作为最后一个参数追加在后面：   printf '%s\n' web1 web2 web3 | parallel_map 3 -- ./restart-service 输出约定（stdout 只给数据）：   stdout —— 每行一条结果：`<条目>`\t`<退出码>`（条目里有制表符时，取最后一个制表符之后的部分）   stderr —— 每个实例的 stdout/stderr，逐行带 [i/N] 前缀；失败明细也在这里 返回码：全部成功返回 0；有条目失败则返回第一个失败条目的退出码。 并发是「按批」的：一批最多 N 个，跑完这一批再下一批。这样不需要锁， 也不会有两个实例抢同一条目；代价是一批里最慢的那个会拖住整批。
- `run_timeout` 没有 perl 时退化为不带超时（直接执行）；SEC 为 0 表示不设超时。
- `run_func_timeout` 函数在子 shell 里跑（所以改不到调用方的变量）；stdout 收集后输出，stderr 丢弃。
- `run_install_sudo_shim` 这是全局副作用（改了当前 shell 的命令解析），所以必须显式调用才生效。
## os

- `os_name` —— linux | darwin | other
- `os_arch` —— x86_64 | aarch64 | other
- `os_is_root` —— 当前是否以 root 身份运行
- `os_has_cmd` CMD... —— 零参数返回 SK_USAGE（空真会让前置检查静默通过）
- `os_pkg_manager` —— 本机的包管理器名（apt-get/yum/dnf/zypper/apk）；没有则返回 1
- `os_pkg_update` —— 刷新包索引；没有受支持的包管理器返回 SK_PRECOND(3)
- `os_pkg_install` PKG... —— 用本机包管理器装包；没有受支持的包管理器返回 SK_PRECOND(3)
- `os_sed_i` ARGS... —— 就地编辑；Darwin 的 sed 必须给个备份后缀
- `os_md5` FILE —— 文件的 md5；两种工具都没有时返回 1
- `os_sha256` FILE —— 文件的 sha256；两种工具都没有时返回 1
- `os_release_field` KEY [FILE] —— 读 os-release 风格文件的字段值
- `os_distro_id` [FILE] —— 小写的发行版 ID
- `os_distro_name` [FILE] —— 发行版显示名（PRETTY_NAME，空则回退 NAME）
- `os_distro_family` [FILE] —— 发行版族：debian|rhel|suse|arch|alpine|unknown 判定顺序：包管理器实测 -> ID_LIKE 词表 -> ID 词表
- `os_desktop_env` —— 桌面环境：ukui|dde|gnome|kde|xfce|mate|cinnamon|lxqt|budgie|none 判定口径与 unix_script 的 detect_desktop 逐字等价：所有线索拼成一个串， 再按桌面类型优先级匹配（ukui > dde > kde > gnome > xfce > mate > cinnamon > lxqt > budgie）
- `os_is_desktop` —— 当前是否在桌面环境
- `os_pkg_manager_full` —— 本机包管理器名（含 pacman/brew）   既有 os_pkg_manager 不认 pacman/brew，这是另一套口径（unix_script 的   detect_pkg_manager 认这两个）—— 两套并存，不改既有函数。
- `os_sudo_ready` —— 确保 sudo 可用（不要求已经是 root）   已是 root 直接放行；否则先试免密（sudo -n true），不行则提示输入一次（sudo -v）。
- `os_pkg_install_root` PKG... —— 提权安装（root 直跑，否则 sudo）
- `os_pkg_remove_root` PKG... —— 提权卸载
- `os_pkg_update_root` —— 提权刷新包索引
- `os_pkg_installed` PKG —— 包是否已安装（不需要提权）
## svc

- `svc_platform` —— 当前平台的服务管理器   可用 SK_SVC_PLATFORM 覆盖（测试与特殊环境用）。
- `svc_start` UNIT —— 启动服务
- `svc_stop` UNIT —— 停止服务
- `svc_restart` UNIT —— 重启服务
- `svc_reload` UNIT —— 重载服务配置
- `svc_enable` UNIT —— 开机自启
- `svc_disable` UNIT —— 取消开机自启
- `svc_enable_now` UNIT —— 开机自启并立即启动
- `svc_disable_now` UNIT —— 取消开机自启并立即停止
- `svc_is_active` UNIT —— 服务是否在跑（只读，不套 dry-run）
- `svc_is_enabled` UNIT —— 服务是否开机自启（只读，不套 dry-run）
- `svc_daemon_reload` —— 让 systemd 重新读 unit 文件
- `svc_install_unit` NAME —— 从 stdin 读 unit 内容写入系统目录并 daemon-reload NAME 必须是单个合法文件名（字母数字与 :_.@+-）：它会被拼进 /etc/systemd/system/ 后面，带路径组件就能写到那个目录之外。 root 下直接写、不套 sudo（极简容器里常有 root 但没有 sudo）。
## ver

- `ver_cmp` A B —— 比较两个版本号
- `ver_gt` A B —— A 是否比 B 新
- `ver_lt` A B —— A 是否比 B 旧
- `ver_eq` A B —— 两个版本是否相等
## status

- `status_is_machine` —— 机器模式返回 0，人类模式返回 1
- `status_state_valid` STATE —— 状态码是否在有限集里
- `status_emit` STATE HUMAN_MSG —— 输出状态   人类模式用 printf %b：文案里的颜色是 ESC[... 这样的**字面转义序列**，   用 %s 会原样打印 —— 颜色会变成一堆反斜杠文本。
- `status_version` VERSION —— 机器模式下输出 VERSION 行（人类模式不重复输出）
- `status_extra` KEY=VALUE —— 机器模式下输出 EXTRA 行（人类模式不重复输出）
## registry

- `registry_add` 与 registry_scan 的区别：registry_scan 扫目录，registry_add 登记单份文件。
- `registry_scan` ROOT PATTERN —— 扫描清单文件并建立索引 条目名 = 清单文件所在目录名。PATTERN 是文件名模式（如 .manifest）。
- `registry_scan_multi` （如 unix_script 的 `<分类>`/`<模块>`/.manifest 布局：每个分类目录各扫一次）。
- `registry_get` NAME KEY —— 取字段值（未声明时为空） KEY 以**字面量**参与匹配：它是调用方传进来的字段名，不该有正则语义。 匹配语义与旧 awk 实现逐字一致：**行首**恰好 KEY= 的第一处，值去首尾空白。 实现走内存 blob（见文件头「为什么把全文读进内存」），全程不 fork 外部命令。
- `registry_list` —— 列出全部条目名（每行一个）
- `registry_visible` NAME FIELD —— 条目在当前平台是否可见 字段为空 ⇒ 未声明平台限制 ⇒ 可见。平台列表用逗号或空格分隔都行。
- `registry_deps` NAME FIELD —— 传递依赖（拓扑序，空格分隔，不含自身）
- `registry_topo` FIELD —— 全体拓扑序（空格分隔）
## profile

- `profile_write` FILE —— 创建/清空 profile 文件
- `profile_append` FILE MODULE [KEY=VALUE...] —— 追加一条
- `profile_parse` FILE —— 解析 profile 输出：`<模块名>``<TAB>``<k=v,k=v>`（每行一个） 注释从**第一个 #** 起截断（与 unix_script 的 profile 解析同口径）。
- `profile_env` MODULE_TAB_KV PREFIX —— 把键值对变成环境变量赋值（每行一个）
## scaffold

- `scaffold_vars_set` KEY VALUE —— 设一个模板变量
- `scaffold_vars_get` KEY [DEFAULT] —— 读一个模板变量；未设置时给默认值
- `scaffold_vars_list` —— 逐行输出 KEY=VALUE
- `scaffold_config_load` FILE —— 从 template.config 载入模板变量 格式与 conf 模块一致：KEY=VALUE，# 开头是注释。 值为空是合法的（表示「这个变量默认没有值，生成时问用户」）。
- `scaffold_render` SRC DST —— 用当前模板变量渲染文件 未声明的 {{KEY}} 原样保留（这样模板里的示例占位符不会被误伤）。 返回非 0 表示没写出来，调用方必须判。
- `scaffold_manifest_write` DIR NAME COMDS TEMPLATE_VERSION [FILELIST] 写 DIR/.shellkit-manifest。FILELIST 是换行分隔的相对路径（模板自有的文件）， 每个文件记一个 sha256 —— 升级时靠它判断「这个文件用户动过没有」。 记的是**基线**：上次成功应用的模板内容的指纹。生成工程时文件刚由模板渲染出来， 当前内容 == 模板内容，两者一样，所以这里直接取当前文件的 sha256。 升级时的基线由 scaffold_manifest_write_baselines 推进 —— 跳过的文件基线不动，否则下一次升级就会把用户的修改当成「没动过」而覆盖掉。
- `scaffold_manifest_write_baselines` DIR NAME COMDS TEMPLATE_VERSION FILELIST BASELINES 与 scaffold_manifest_write 写同一个格式的清单，但基线由调用方给： BASELINES 是换行分隔的「相对路径=指纹」，指纹可以为空（表示没有指纹）。 BASELINES 里没提到的文件，基线记为空。 为什么要有这个入口：升级时「用户改过、被跳过的文件」不能把基线推进到用户 的内容上 —— 推进了下一次升级就会覆盖掉用户的修改。只有真正成功应用了 模板的文件才能推进基线。
- `scaffold_manifest_read` DIR —— 读 DIR/.shellkit-manifest 标量进 SK_MANIFEST_* 公开变量，@var 条目进模板变量表。
- `scaffold_manifest_get` KEY —— 读 manifest 里的一个标量
- `scaffold_manifest_list_files` —— 逐行输出模板自有的文件（相对路径）
- `scaffold_manifest_file_sum` DIR RELPATH —— 读 manifest 里记的某个文件的 sha256
- `scaffold_run_hook` FILE PROJECT_DIR —— 跑一个模板钩子 钩子是模板目录里的可执行脚本（template.hooks.d/pre、template.hooks.d/post）。 环境变量里会带上：SHELLKIT_PROJECT_DIR / SHELLKIT_PROJECT_NAME / SHELLKIT_PROJECT_COMMANDS / SHELLKIT_TEMPLATE_VERSION，以及每个模板变量。 钩子不存在就跳过；不可执行就跳过并告警（不因为钩子没设执行位就让生成失败）。
## retry

- `retry` ATTEMPTS CMD... —— 失败退避重试；用法错与校验失败不重试
- `retry_classify` CODE —— 把退出码分类成 success / timeout / failure   超时码由 SHELLKIT_RETRY_TIMEOUT_CODE 决定（默认 124）。
- `retry_last_class` —— 上一次 retry 的结果分类（success / timeout / failure）   没跑过 retry 时是 none。
- `retry_last_rc` —— 上一次 retry 里被重试命令最后的退出码   没跑过 retry 时是 none。
## lock

- `lock_acquire` NAME [WAIT_SEC] —— 0 成功；SK_PRECOND 被占用/超时；SK_USAGE 名字非法
- `lock_release` NAME —— 只释放自己持有的锁
- `lock_held` NAME —— 返回码判断是否被占；被占时 stdout 输出持有者 pid
## net

- `net_sha256` FILE —— 文件的 sha256；两种工具都没有时返回 1
- `net_verify` FILE SHA256 —— 校验文件的 sha256；对不上返回 SK_VERIFY(5)
- `net_download` URL DEST [SHA256] —— 下载并可选校验 sha256；已有本地缓存且校验通过就不重下
- `net_wait_port` HOST PORT [TIMEOUT] —— 等端口可连；超时返回 SK_NET(4)
- `net_wait_http` URL [TIMEOUT] —— 等 HTTP 可用；超时返回 SK_NET(4)
## http

- `net_request` METHOD 不区分大小写；请求完成返回 0，状态码不算错误。
- `net_json` 有 jq 用 jq，有 python3 用 python3，都没有返回 SK_PRECOND(3)。
- `net_escape_json` 优先 jq，其次 python3；都没有时走内置降级路径。
- `http_github_latest_tag` 查询失败时输出空串并返回 0 —— 调用方把它当「没有新版本」处理。
- `http_github_release_asset` PATTERN 是正则（匹配 browser_download_url）；没有匹配时输出空串并返回 0。
## config

- `conf_init` FILE [--format env|dotenv] —— 载入配置文件；文件不存在不报错（当成空配置） --format 决定文件怎么解析：auto（默认，老行为 + 容忍 dotenv 写法）、 env（严格 KEY=VALUE）、dotenv（完整 dotenv 语义）。 严格格式（env / dotenv）下不合规的行会在载入时报警并跳过。
- `conf_file` —— 当前生效的配置文件路径；未初始化时为空
- `conf_format` —— 当前生效的配置格式（auto|env|dotenv）
- `conf_get` KEY [DEFAULT] —— 只输出值；未初始化或无文件时返回默认值 取值顺序：配置层 > 配置文件。键存在但值为空时返回空串，不回落默认值。
- `conf_has` KEY —— 返回码 0/1
- `conf_get_any` KEY [DEFAULT] —— 环境变量 > 配置层 > 配置文件 > 默认值
- `conf_load_dotenv` FILE —— 把 dotenv 文件的键值载入配置层 解析规则：空行与 '#' 开头的行忽略；允许行首 export 前缀；键必须是合法变量名； 成对的单/双引号剥掉（引号内内容原样保留，不解释转义）；未加引号的值去行尾空白、 保留中间空格；KEY= 是"键存在且值为空"；同一文件里后出现的键覆盖先出现的。 取舍：只进配置层，不 export 到调用方的环境变量 —— 环境变量优先级最高， 往里塞东西会盖掉调用方自己的设置。确实要导出时用 conf_source。 非法行跳过并告警，不整体失败。文件不存在返回 SK_PRECOND。
- `conf_source` FILE —— 把 dotenv 文件的键导出为环境变量（供子进程继承） 与 conf_load_dotenv 的区别：这里明确要 export，所以只导环境变量，不进配置层。
- `conf_set` KEY VALUE —— 校验 + 值未变则跳过 + 原子写 + 600
- `conf_unset` KEY —— 删掉一个键；幂等，键不存在也算成功
- `conf_disable` KEY —— 把 KEY=VALUE 改成注释行，保留原值
- `conf_keys` —— 逐行输出键名（配置层的键在前，文件里的键在后，不重复）
## prompt

- `ask` VAR PROMPT [DEFAULT] [TIMEOUT] —— 问一个问题，把答案写进 VAR；超时或 EOF 回退默认值   VAR 不能用库内部出参链路上的局部变量名（见 _sk_check_out_name），否则会静默失效。
- `ask_yn` VAR PROMPT [DEFAULT=y] [TIMEOUT] —— 结果写入 y 或 n
- `ask_choice` VAR PROMPT "a|b|c" [DEFAULT] [TIMEOUT] —— 多选一；超时或 EOF 回退默认值
- `ask_multi` （空格分隔，如 "1 3 5"），不是候选项的内容 —— 按序号取内容是调用方的事。
- `confirm` PROMPT [DEFAULT=n] [TIMEOUT] —— 只返回码
## cli

- `cli_group` TITLE —— 后续注册的命令归入该分组
- `cli_cmd` NAME DESC [USAGE] —— 注册一个子命令；要写在命令文件末尾
- `cli_has` NAME —— 该命令是否已注册
- `cli_usage_cmd` NAME —— 打印单个子命令的用法行
- `cli_usage_global` —— 打印总用法：命令按分组，选项固定五条
- `cli_completion_script` [bash|zsh] —— 生成补全脚本 子命令名取自注册表，所以新加一个 cli_cmd，补全里自动就有了 —— 不用像别的框架那样单独维护一份命令列表。 程序名取 SK_PROG（生成出来的工程可以在自己的入口里设成自己的名字）。
- `cli_run` ARGS... —— 分发入口：吃全局选项后按名字找同名 cmd_ 前缀的函数
- `cli_opt_init` —— 清空选项注册表。不接受参数；变量默认值请自己先赋好
- `cli_opt` VAR LONG [SHORT] [TAKES_ARG] —— 注册一个选项；第四个参数为 1 表示这个选项要吃值   VAR 是「选项值要写进的变量名」，不能用库保留名（__ / _sk_ 前缀）。
- `cli_opts` ARGS... —— 按 cli_opt 注册的规则解析子命令选项；剩余位置参数进 SK_OPTS_LEFT
## man

- `man_modules` —— 输出模块名，一行一个
- `man_page` —— 输出 shellkit(1) 的 roff 正文
- `man_module_page` MODULE —— 输出某模块第 3 节的 roff 正文
- `man_write_all` DIR —— 把所有页面写进 DIR
- `man_count_functions` —— 公开函数总数
## vendor

- `vendor_dir_rel` PROJECT_DIR —— 库副本相对工程目录的路径（配置值原样）   默认是 vendor/shellkit；配了 SHELLKIT_VENDOR_DIR 或 .shellkit-vendor-dir   就是那个值。
- `vendor_dir` PROJECT_DIR —— 库副本在工程里的绝对路径
- `vendor_dir_source` PROJECT_DIR —— 落点设置是从哪儿来的   用来把「为什么落在这个地方」讲清楚，而不是让人猜。
- `vendor_dir_detect` PROJECT_DIR —— 工程里「别处」的库副本   扫一层子目录，找形如 <子目录>/shellkit 的库副本（里面要有 lib/bootstrap.sh）。   解析出来的落点本身不算 —— 这里找的是「落点之外的那一份」。
## proc

- `proc_start` NAME COMMAND... —— 后台拉起一个进程组 脱离终端：nohup 忽略 SIGHUP + 标准输入接 /dev/null + 作业控制让它自带进程组。 pid 文件：$DIR/NAME.pid（原子写）。日志：$DIR/NAME.log（**追加**，不截断 —— 截断会把上次的现场抹掉，出事时没得查）。
- `proc_stop` NAME —— 停掉整个进程组 只 kill 主进程 ⇒ 子进程残留、端口还占着 —— 这是手写最常见的坑。 这里先给整组 TERM，留收尾的时间；还在就 KILL 整组。 「整组停」有两条硬约束（判据在 _sk_proc_group_of，只此一处）：   目标得自己就是组长，且那个组不是**我们自己的组** ——   否则 kill -- -PGID 会把调用方一起杀掉（静默自杀，退出码 143）。   满足不了就退化成只杀那个 pid（宁可留子进程，也不能自杀）。
- `proc_is_running` NAME —— 探活 僵尸 pid 文件会被清掉：文件还在、进程早没了 —— 手写看门狗最常见的另一种坑 （探活永远失败，但没人清理，重启就一直起不来）。
- `proc_watchdog` [--interval SEC] [--max-backoff SEC] [--max-restarts N] NAME COMMAND... 看门狗：进程挂了拉起来，带退避。 退避：连续失败时按 1→2→4… 翻倍（上限 --max-backoff）—— 没有退避的重启是**风暴**：进程起来就崩 ⇒ 无限循环重启，把机器打满。 进程连续活过几个周期 ⇒ 退避归零（不是一直用最大退避）。 --max-restarts N：连续 N 次拉起失败就放弃并返回非 0（0 = 不限）。 无人值守设备上「放弃了」必须有人看得见，所以放弃时是**非 0 退出**。
## git

- `git_default_branch` REPO —— 解析默认分支 顺序：origin/HEAD 的符号引用（正常 clone 都有）→ 本地已有的 origin/main 或 origin/master → 远端只有一个分支时就是它 → 多个远端分支且认不出 ⇒ 报歧义。 认不出就报错，不猜 —— 猜错了的代价是「拉错分支」。 只看 origin 这一个远端：默认分支是「这个仓的」概念，多远端时猜哪个远端 同样是猜 —— 与其猜，不如让调用方显式指定分支名。
- `git_is_dirty` REPO —— 脏仓守卫 有未提交改动（含未跟踪文件）⇒ 退出码 1，stdout 是 porcelain 摘要。 未跟踪文件也算脏：另一个会话刚建的文件，被 pull 冲掉一样是事故。
- `git_tag` REPO —— 取版本号（浅克隆安全） 浅克隆里 git describe --tags 会退化成哈希 ⇒ 产物版本变成 (devel)。 三层回退：   1) HEAD 上的精确 tag；   2) 浅克隆且拿不到 ⇒ 补取 tag（tag 跟不下来是浅克隆的常态）；   3) 还是拿不到 ⇒ 补深度（--deepen）：tag 指向的是**祖先**提交时，      只补 tag 不够 —— 浅边界把祖先链截断了，describe 仍认不出这个 tag      是不是 HEAD 的祖先，于是仍然失败。 第 2、3 步要联网；不想联网就设 SHELLKIT_GIT_NO_FETCH=1。 都取不到时退到「最近的可达 tag」：那个 tag **可能在祖先上**（HEAD 已经 往前走了几个提交）—— 它是这条提交链的版本号，不是 HEAD 自己的版本号。
- `git_fetch` REPO BRANCH —— 受控取数 脏仓直接拒绝：同机并行会话的工作不能被无声冲掉（我们被冲掉过两次）。 只取不改工作树，但仍然守脏仓 —— 「干净才动」是这一族函数的统一口径。
- `git_fast_forward` REPO BRANCH —— 只快进，绝不丢本地提交 能快进 ⇒ merge --ff-only；不能快进（本地有分叉）⇒ **明确报错，不动工作树**。 「快进 vs 强制重置」的区别就在这里：强制重置会丢本地提交，所以它另有 一个名字更直白的函数（git_reset_hard），要的人自己明说。 **只快进当前工作树所在的分支**：本地已有这个分支、而 HEAD 不在它上面时， 明确报错、不动工作树。不这么判的后果是「把 origin/main 合进当前分支」还 返回 0 —— 调用方以为快进了 main，其实被合进去的是另一个分支， 两边的提交也搅在了一起（假成功比报错坏得多）。
- `git_reset_hard` REPO REF —— 显式的破坏性重置 会丢本地提交 —— 名字里就写着 hard，调用方必须自己确认过。 想要「不丢」的语义就用 git_fast_forward。
- `git_worktree_add` REPO PATH BRANCH [START_POINT] —— 检出到工作树 多仓并行改动的标准做法：每个改动一个工作树，互不干扰， 也不会把别人的工作区冲掉（这正是脏仓守卫要防的那类事故）。 PATH 不能落在仓里：工作树建在仓内 ⇒ 主仓多出一堆未跟踪文件 ⇒ 主仓**永久变脏** ⇒ 脏仓守卫把取数与快进全锁死（而且没人知道为什么）。也不能是软链， 父目录必须已经存在（git 自己也要求）。 BRANCH 本地已有 ⇒ 检出那个分支（此时不能再给 START_POINT）；没有 ⇒ 新建并跟住。
## archive

- `archive_list` ARCHIVE —— 打印归档里的成员清单（相对路径，每行一个） 只读不解：不写盘、不建目录。用来「先看看包里有什么」再决定解不解。
- `archive_extract` ARCHIVE DEST [EXPECTED_SHA256] —— 安全解包 解到 DEST（不存在就建）。流程：   1. 校验魔数，认出格式；   2. 可选：先核对 sha256（给了就必须对上，对不上一个字节都不解）；   3. 查成员名的路径穿越 —— 归档里带穿越路径时**连解都不解**；   4. 查归档里声明的软链 —— 绝对目标**连解都不解**；   5. 解到**暂存目录**（不是直接解到 DEST）；   6. 扫解出来的文件系统，软链兜底再查一遍（这一遍是权威判据）；   7. 全通过才**整体换**进 DEST。 解之前还要查一件事：**结尾标记**。tar 流末尾必须有两块 512 字节的零， 缺了就是被截断了。GNU tar 读到 EOF 就当「归档到此为止」、照样退出 0 ⇒ 截断的包会被静默解成「只有前几个成员的包」⇒ 半份内容被装上，而调用方 拿到的是成功。查结尾标记 ⇒ 结论与 tar 的实现无关（bsdtar 更严、GNU tar 更松，同一份包在两边给出不同答案本身就是缺陷）。 为什么先解到暂存目录：tar 解到一半失败（磁盘满、成员损坏）时， 直接解到目标目录会留下**半份内容** —— 而调用方看到的是「目录存在了」。 半份内容比没有更危险：脚本会接着往下跑，读到截断的二进制。 为什么第 7 步是「整体换」而不是「逐项搬」：逐项搬在中途失败时， 目标目录会停在新旧混合的状态（前面几项已经进去了）。整体换是两次 rename —— 目标目录要么是旧的、要么是新的，不会混。 覆盖语义：包里有的路径以包为准；包里没有的旧文件保留。 目标目录是软链或不是目录时一律拒绝（不顺着软链写，也不覆盖普通文件）。 已知边界：解包只保证「**包里的东西**逃不出去」，不保证「目标目录本来 就干净」—— 调用方自己放在目标目录里的软链是它自己的数据，覆盖安装 后会原样保留（指向归档之外也照样保留）。要清就自己先清一遍。 目标目录是只读（555）时：新内容照常装上去，目录权限也照原样保留； 但**旧文件搬不回去**（那个目录不可写）⇒ 退 5 并把旧目录的位置报出来。 root 不受权限限制 ⇒ 那种环境里旧文件能搬回去 ⇒ 退 0。 进程被强杀可能留下两处残留，都能安全处理：   - `<目标目录的父目录>/.shellkit-extract.XXXXXX`：暂存目录（可能半份）；   - `<目标目录的父目录>/.shellkit-old.XXXXXX`：换上去的瞬间被挪开的旧目录     —— 这一处是**旧目标目录本身**，目标目录此刻可能整个不存在，     把它改名搬回去即可恢复。   - `<目标目录>/.shellkit-stage.XXXXXX`：父目录不可写时的降级暂存目录     —— 它落在**目标目录里面**，强杀后残留会出现在用户的安装目录里。             旧内容没搬回去，或目标目录权限没能还原
