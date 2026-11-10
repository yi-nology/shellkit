# Testing and gates

Testing here has three layers, all in service of the same thing: **proving it actually ran**, not that it "should" run.

| Layer | Where | What it covers |
| --- | --- | --- |
| module tests | `tests/test_<module>.sh` | each module's behaviour, failure branches included |
| scaffold tests | `tests/test_scaffold.sh`, `tests/test_install.sh` | `shellkit new` and the installed layout |
| example tests | `examples/*/tests/` | whole projects, exercised through the real binary |

## Run

```bash
bash tests/run.sh
```

`tests/run.sh` is a per-file runner: it globs `tests/test_*.sh`, gives each file its own subprocess, connects stdin
to `/dev/null` (a test must never wait for a keypress or CI hangs), and applies a per-file limit when `timeout` exists.

Output has exactly two shapes: `ok` or `FAIL: <message>`. **Any FAIL line means failure** -- and you have to look at it,
not just at the exit code.

## Machine-readable output

What CI actually needs is *which case failed*, not which file. The runner has three formats:

```bash
bash tests/run.sh                      # plain (default; behaviour is byte-for-byte the old one)
bash tests/run.sh --format tap         # TAP 13, straight into any test reporter
bash tests/run.sh --format junit        # JUnit XML, for GitHub Actions / Jenkins
```

Other options:

```bash
bash tests/run.sh --jobs 4             # run in parallel (each file gets its own temp root)
bash tests/run.sh --filter '*fs*'      # only files whose name matches
bash tests/run.sh --list               # list what would run, run nothing
```

`--filter` takes a shell glob (add your own `*`). When it matches nothing the runner exits 2 and lists the
available test files -- an empty run is never reported as green.

Case granularity comes from `# CASE: title` comments inside the test file. A file without any `CASE` marker
degrades to one file-level case, and the failure reason is the `FAIL:` line the assertion printed.

**"A failure reported as all green" cannot happen**: every format returns non-zero when something fails, and the
failure shows up as `not ok` / `<failure>` / `FAILED:` in the report. `tests/test_runner.sh` holds that invariant
down -- it copies the real runner into a fake repository and drives it with controlled failing cases.

## Assertions

`tests/test_helper.sh` is a deliberately minimal assertion library. A failed assertion exits 1, and the runner marks
the file red.

| Assertion | Usage |
| --- | --- |
| `assert_eq` | `assert_eq EXPECTED ACTUAL [MSG]` |
| `assert_ne` | `assert_ne UNEXPECTED ACTUAL [MSG]` |
| `assert_contains` | `assert_contains HAYSTACK NEEDLE [MSG]` |
| `assert_not_contains` | `assert_not_contains HAYSTACK NEEDLE [MSG]` |
| `assert_true` / `assert_false` | `assert_true CMD ARGS...` |
| `assert_exit_code` | `assert_exit_code WANT CMD ARGS...` |
| `assert_stdout_empty` | `assert_stdout_empty CMD ARGS...` |
| `assert_file_mode` | `assert_file_mode FILE 600` |
| `tmpdir` | one isolated directory per case, path on stdout |

## One test file

```bash
#!/usr/bin/env bash
. "$(dirname "$0")/test_helper.sh"

. "$TEST_ROOT/lib/bootstrap.sh"

assert_eq 2 "$SK_USAGE" "usage errors exit 2"
assert_exit_code 2 require_cmd
assert_stdout_empty log_info "logs must not reach stdout"
assert_contains "$(log_info hi 2>&1)" "hi" "stderr must carry the message"
```

Note that the last two form a pair: `assert_stdout_empty` proves stdout is clean, `assert_contains` proves the
message really went to stderr. Test only the first and "printed nothing at all" passes too.

## stub: exercise failure branches without unplugging the network

`stub` shadows an external command with a shell function of the same name. Shell functions are visible inside
`$(...)` subshells, so `curl` calls made from inside the library are intercepted:

```bash
workdir=$(tmpdir)

# make curl exit 7 (connection failure) and check net_download maps it to SK_NET(4)
stub curl --exit 7
assert_exit_code 4 net_download "https://example.com/x" "$workdir/x"
assert_stub_called curl "curl should have been called"
unstub curl
```

The same approach works for `date` (freeze time, assert on backup file names) and `sleep` (do not actually sleep,
still assert on the retry delay window).

## The gate: fifteen steps of `make check`

| Step | What it blocks |
| --- | --- |
| `syntax` | `bash -n` over every script and template |
| `test` | `tests/run.sh` |
| `lint` | `shellcheck -S warning -x` (templates are rendered before checking) |
| `module-order-check` | a module calling a function from a module loaded later |
| `check-exitcode-docs` | a public function that does not document its return code, or whose comment block is separated from it by a blank line |
| `local-names-check` | a library local that is not `__`-prefixed, or a local on the out-parameter path that is missing from the reserved list (callers using that name silently keep the old value) |
| `module-count-check` | the hand-written "N modules" in the docs does not match `lib/modules.txt` |
| `pipe-safety-check` | an early-exit consumer in a pipeline (`grep -q` / `head`): the producer is killed by SIGPIPE, so a caller with `pipefail` sees the whole pipeline fail |
| `docs-check` | public functions without a comment, generated artefacts out of sync |
| `versions-check` | `VERSION` against its five projections |
| `check-docs` | every bash block in markdown must pass `bash -n`, and every function name must exist |
| `cookbook-check` | the hand-written "N scenarios" in the docs does not match the real cookbook |
| `messages-check` | pot versus sources (skipped when `xgettext` is absent) |
| `examples` | each project's own test under `examples/` |
| `fmt` | `shfmt -d -i 2 -ci` (checks, never rewrites) |

`check-exitcode-docs` backs the promise "the return code is part of the interface". The README makes that promise,
so a gate has to keep it. The sixteen core files written before the rule existed carried no `@exitcode` at all -- the
interface was half missing.

`check-docs` is the easiest to overlook: it turns "documented but not implemented" into a build failure. Rename a
function and the example in the README goes red immediately instead of silently becoming wrong -- and an AI that
finds a wrong example will copy it, confidently.

## Add a test

Create `tests/test_<name>.sh`. That is all: the glob picks it up, so no runner edit and no registration.

Two disciplines when writing tests:

1. **Assert on artefacts**, not only on exit codes. Exit 0 while writing nothing is the most common false green.
2. **Verify in reverse once**: run it against the old code and confirm it goes red, then against the new code and
   confirm it goes green. A test that has never been red proves nothing.
