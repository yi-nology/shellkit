# CLI framework

`lib/core/cli.sh` does five things only: registration, dispatch, help generation, option parsing, exit codes.

The key design decision: **a new command never touches the dispatcher**. `cli_run` finds `cmd_<name>` dynamically
with `declare -F`, and hyphens in the command name become underscores (`install-self` → `cmd_install_self`).

## Register

```bash
cli_group "ops"
cli_cmd deploy "deploy the service" "deploy [--force] <target>"
cli_cmd status "show status"
```

`cli_group` sets the heading a command appears under in help output; without it the command goes into the ungrouped
section. The third argument of `cli_cmd` is a usage line -- omit it and help shows the bare command name.

Registration happens at `source` time, so `cli_cmd` belongs at the **end** of the command file. Put it earlier and
the function does not exist yet; you only find out during dispatch (`command has no handler`).

## Dispatch

```bash
cli_run "$@"
```

That single line is all your entry script needs. It consumes the global options first, then takes the first
positional argument as the command name:

| Global option | Effect |
| --- | --- |
| `-h`, `--help` | print global usage (commands grouped, five options) |
| `-V`, `--version` | print `SK_VERSION` (or `dev` when unset) |
| `--verbose` | `SHELLKIT_DEBUG=1`, debug logging on |
| `--no-color` | disable colour |
| `-y`, `--yes` | `SHELLKIT_NONINTERACTIVE=1`, prompts take their defaults |

When the command name does not exist it suggests a prefix match and returns `SK_USAGE`:

```text
[ERROR] no such command: deply
[Did you mean]: deploy
```

## Options inside a subcommand

Three calls: clear the registry, register rules, parse.

```bash
cmd_deploy() {
  local __target="" __force="" __retries="3"

  cli_opt_init
  cli_opt __force --force -f
  cli_opt __target --target -t 1
  cli_opt __retries --retries -r 1
  cli_opts "$@" || return $?

  log_info "target=$__target force=$__force retries=$__retries"
  return "$SK_OK"
}
```

The rules:

- `cli_opt VAR LONG [SHORT] [TAKES_ARG]`. A fourth argument of `1` means the option consumes a value.
- Assign your defaults *before* registering -- `cli_opt_init` clears the registry, it does not touch your variables.
- After parsing, the remaining positional arguments are in **`SK_OPTS_LEFT`** (an array starting at index 0).
- Both `--opt=value` and `--opt value` work; a boolean option given `=` is rejected outright (stuffing garbage
  into a variable is harder to debug than an error).

## Errors are reported once

`log_error` prints once and records the last message in `SK_ERRMSG`; `cli_run` does not print it again. So call
`log_error` where you detect the problem, and do not combine `log_error` with `die`.

## A complete minimal CLI

```bash
#!/usr/bin/env bash
set -euo pipefail

. ./vendor/shellkit/lib/bootstrap.sh

cli_group "main"
cli_cmd hello "say hello" "hello [--name NAME]"

cmd_hello() {
  local __name="world"
  cli_opt_init
  cli_opt __name --name -n 1
  cli_opts "$@" || return $?
  printf '%s\n' "hello $__name"
  return "$SK_OK"
}

SK_PROG=hello
cli_run "$@"
```

Note that `printf` writes to stdout (that is data) while logs go to stderr, so a pipeline such as
`./hello --name x | jq` is never polluted by log output.
