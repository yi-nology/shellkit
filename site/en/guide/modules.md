# Module map

`lib/bootstrap.sh` is the single entry point. It loads all 19 modules once, in **topological order**. You do not
pick and choose what to source, and you should not copy one module's implementation into your own script -- that is
just another way of hitting the same trap twice.

## The table

| Module | Responsibility | Key functions |
| --- | --- | --- |
| [error](/en/reference/error.md) | failure and preconditions | `die` `fail` `require_cmd` `require_root` `require_file` `require_bash` |
| [i18n](/en/reference/i18n.md) | translation lookup | `_t` `_tn` |
| [log](/en/reference/log.md) | everything to stderr | `log_info` `log_ok` `log_warn` `log_error` `log_debug` `log_section` |
| [str](/en/reference/str.md) | string ops 3.2 lacks | `str_trim` `str_lower` `str_upper` `str_contains` `str_starts_with` `str_ends_with` `str_repeat` |
| [validate](/en/reference/validate.md) | input validation | `validate_not_empty` `validate_single_line` `validate_key` `validate_port` `validate_ip` `validate_version` `validate_abs_path` `validate_url` `validate_enum` |
| [fs](/en/reference/fs.md) | atomic writes, idempotent edits | `fs_atomic_write` `fs_backup` `fs_ensure_dir` `fs_ensure_line` `fs_ensure_block` `fs_ensure_symlink` `fs_tmp_init` |
| [os](/en/reference/os.md) | the only place for platform differences | `os_name` `os_arch` `os_is_root` `os_has_cmd` `os_pkg_install` `os_sed_i` `os_md5` `os_sha256` |
| [trap](/en/reference/trap.md) | the cleanup stack | `trap_push` `trap_pop` `trap_cleanup` `trap_install` `trap_list` |
| [run](/en/reference/run.md) | run a command | `run` |
| [retry](/en/reference/retry.md) | retries with backoff | `retry` |
| [lock](/en/reference/lock.md) | single instance | `lock_acquire` `lock_release` `lock_held` |
| [net](/en/reference/net.md) | downloads and readiness probes | `net_download` `net_verify` `net_sha256` `net_wait_port` `net_wait_http` |
| [http](/en/reference/http.md) | sending HTTP requests | `net_request` `net_json` `net_escape_json` |
| [config](/en/reference/config.md) | KEY=VALUE and dotenv configuration | `conf_init` `conf_get` `conf_get_any` `conf_has` `conf_set` `conf_unset` `conf_disable` `conf_keys` `conf_load_dotenv` `conf_source` |
| [scaffold](/en/reference/scaffold.md) | template variables, manifests, hooks | `scaffold_vars_set` `scaffold_vars_get` `scaffold_config_load` `scaffold_render` `scaffold_manifest_read` `scaffold_run_hook` |
| [prompt](/en/reference/prompt.md) | interaction | `ask` `ask_yn` `ask_choice` `confirm` |
| [cli](/en/reference/cli.md) | registered-command framework | `cli_group` `cli_cmd` `cli_run` `cli_opt` `cli_opts` `cli_has` `cli_usage_global` |
| [man](/en/reference/man.md) | man page generation | `man_page` `man_module_page` `man_write_all` `man_modules` `man_count_functions` |

## Load order is not alphabetical

Topological order exists because later modules call earlier ones. `log` needs `_t` (so `i18n` loads first), `error`
needs `log_error`, and `cli` needs both `log_error` and `_t`.

That order lives in **one file** -- `lib/modules.txt`, with two columns:

```text
i18n
log          i18n
error        i18n log
str          error
```

The first column is the module name, the second lists its **direct** dependencies (space separated, optional).
`lib/bootstrap.sh` loads from it, `tools/shdoc.sh` generates the API reference from it, the site syncs from it --
adding a module means editing one file, with no second place to forget.

Dependencies must come first. Getting the order wrong does not have to wait for runtime to surface:
`make module-order-check` names the offending call directly.

## Load only what you need

By default everything loads (19 modules). To slim it down:

```bash
SHELLKIT_MODULES="log fs" . ./vendor/shellkit/lib/bootstrap.sh
```

Only the listed modules are loaded, and their **transitive dependencies come along automatically** (`i18n` is always
loaded, because every module needs translations).

## Pick a module by task

| What you are doing now | What to use |
| --- | --- |
| emit a log line | `log_info` / `log_ok` / `log_warn` / `log_error` / `log_debug` / `log_section` |
| fail with an exit code | `die` / `fail` / `require_cmd` / `require_root` / `require_file` |
| read configuration (environment wins) | `conf_init` then `conf_get_any` |
| change configuration idempotently | `conf_set`; for any file, `fs_ensure_line` / `fs_ensure_block` |
| write a file without corrupting it | `fs_atomic_write`; back up with `fs_backup` |
| download and verify | `net_download URL DEST [SHA256]`; mirror fallback is built in |
| wait for a port / for HTTP | `net_wait_port` / `net_wait_http` |
| run a command, stop on failure | `run systemctl restart nginx` |
| run a command, judge success yourself | `run --no-die systemctl is-active nginx` |
| retry a few times | `retry 5 curl -fsS "$url" -o x` |
| guarantee a single instance | `lock_acquire deploy 30` |
| always clean up on exit | `trap_push 'rm -rf "$workdir"'` + `trap_install` |
| ask the user something | `ask` / `ask_yn` / `ask_choice` / `confirm` |
| add a subcommand | register with `cli_cmd`, implement `cmd_<name>` |
| output in several languages | `_t 'english msgid'`, translations in `locale/` |

## Boundaries that are easy to get wrong

- `run` **dies on failure** by default, and the `exit` inside `die` ignores the caller's `if` / `||`. To test success
  inside a condition, use `run --no-die`, which only returns the exit code.
- `retry` **does not retry** usage errors (`SK_USAGE`) or verification failures (`SK_VERIFY`). Retrying those a
  hundred times gives the same answer.
- `lock_acquire` pushes the release onto the cleanup stack as soon as it takes the lock, so you never write
  `trap 'lock_release'` by hand.
- `conf_get` reads the config file only; `conf_get_any` is the environment-first one. The names differ slightly,
  the behaviour differs a lot.
