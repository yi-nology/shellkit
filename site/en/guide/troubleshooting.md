# Troubleshooting

Start with the exit code, then the symptom table. **The exit code is part of the interface** and it is more reliable
than the logs -- logs can be changed by `--no-color` or a redirect, exit codes cannot.

## Exit codes

| Code | Macro | Meaning | Typical source |
| --- | --- | --- | --- |
| 0 | `SK_OK` | success | --- |
| 1 | `SK_ERR` | general error | a command function calling `fail "$SK_ERR"` |
| 2 | `SK_USAGE` | usage error | bad arguments, unknown option, `_sk_need_args` |
| 3 | `SK_PRECOND` | precondition unmet | missing command, not root, interactive without a default, lock unavailable |
| 4 | `SK_NET` | network failure | `net_download`, `net_wait_port` timing out |
| 5 | `SK_VERIFY` | verification failure | sha256 mismatch, docs disagree with code, `vendor --check` drift |

Callers use this code to decide whether to retry: `retry` retries `SK_NET` only, and gives up immediately on
`SK_USAGE` and `SK_VERIFY` -- a hundred retries of those produce the same answer.

## Symptom → fix

| Symptom | Most likely cause | What to do |
| --- | --- | --- |
| `$(...)` captured a value with `[INFO]` in it | something logged to stdout | logs only via `log_*` (stderr); custom output with `printf >&2` |
| `bad substitution` | `${v^^}` / `${v,,}` used | switch to `tr a-z A-Z`, see [Bash 3.2](./bash32.md) |
| `declare: -A: invalid option` | associative array used | use a `case` dispatch or two parallel arrays |
| `command not found: mapfile` | `mapfile` used | switch to `while IFS= read -r` |
| `unbound variable` pointing at an array | empty array expanded under `set -u` | write `${arr[@]+"${arr[@]}"}` |
| the script exits from inside `if run ...` | `run` failed and called `die`; `exit` ignores `if` | switch to `run --no-die` and inspect the code |
| every deploy restarts the service | the file is written without comparing content | compare first, write only on change; `fs_ensure_*` is idempotent by design |
| config file mode turned into 644 | plain `echo >>` append | use `conf_set` / `fs_atomic_*` (they go through `cp -p` and keep the mode) |
| two backups in the same second, only one survives | backup names only had second resolution | since 0.6.0 names carry pid and a sequence number; upgrade |
| `lock_acquire` never succeeds | a previous run was `SIGKILL`ed and left a lock directory without a pid | since 0.6.0 a pid-less lock gets a 5 second grace period before reclamation |
| `make check` goes red after a docs edit | generated artefacts were not refreshed | run `./shellkit docs`, then `bash po/messages.sh` |
| `check-docs` reports unknown function | an example uses a function that does not exist or was renamed | check the signature in the [API reference](/en/reference/index.md) |
| `messages-check` red every time | the pot carries absolute paths or line numbers | regenerate with `bash po/messages.sh` (`--no-location` is baked in) |

## Three debugging disciplines

1. **Reproduce first, then change code.** A fix without a stable reproduction only changes how the symptom looks.
2. **Judge on artefacts, not on "the command did not complain".** Commands like `gh issue close` or
   `gh issue create` can print nothing at all when they succeed; read the state or the artefact back.
3. **Verify in reverse once.** After fixing, confirm the test is red on the old code and green on the new one. A test
   that was never red proves nothing.

## Debug switches

```bash
# turn on debug logging
SHELLKIT_DEBUG=1 ./bin/myapp start

# disable colour so logs paste cleanly
SHELLKIT_COLOR=never ./bin/myapp start

# non-interactive: every prompt takes its default; a prompt without one returns SK_PRECOND(3)
SHELLKIT_NONINTERACTIVE=1 ./bin/myapp start

# keep the temporary directory to inspect the scene afterwards
SHELLKIT_TMP_KEEP=1 ./bin/myapp start
```

Under `SHELLKIT_NONINTERACTIVE=1`, a prompt that **has no default** makes the library return 3 rather than block
waiting for input. That converts "CI ran into an interactive point" into a clear failure instead of a hang.
