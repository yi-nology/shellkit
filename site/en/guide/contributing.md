# Contributing

## Run the gate first

```bash
make check
```

All nine steps must be green. To run one step on its own:

```bash
bash tests/run.sh
./shellkit docs --check
bash tools/check_versions.sh
bash tools/check_docs.sh
```

## Adding a module means four edits; miss one and the gate goes red

1. Write `lib/core/<name>.sh`: every public function **must** be preceded by a comment on the line directly above
   (`docs-check` blocks otherwise).
2. Insert it into the module sequence in `lib/bootstrap.sh` -- in **dependency order**, not alphabetical order.
3. Add it at the same position in `MODULES` in `tools/shdoc.sh` (the two lists must agree).
4. Write `tests/test_<name>.sh`: the `tests/test_*.sh` glob executes it automatically.

Functions marked `@internal` are not exported and are exempt from the comment-coverage check; internal functions
whose names start with an underscore (`_sk_*`) are exempt as well.

## Changing an existing function needs its own version

Within 0.x we only add, never change. When a change alters results (return code, output file name, output text):

1. give it a version of its own (say 0.6.0 → 0.7.0);
2. add a "behaviour changes that alter results" table to `docs/MIGRATING.md`;
3. state the old behaviour, the new behaviour, and what callers must do.

Additive changes can ship as a patch.

## Releasing

```bash
make release-dry VERSION=x.y.z
make release VERSION=x.y.z
```

The first is a dry run: bump the version → regenerate pot and docs → sync version references in the site → run
the gate → **restore the working tree**. The second really ships: commit, tag, push, and the tag triggers the
release workflow. Details in [Releasing](./releasing.md).

## Documentation

| What you changed | What to run |
| --- | --- |
| a public function's comment | `./shellkit docs` (regenerates REFERENCE and the three AI artefacts) |
| a message id | `bash po/messages.sh` |
| a site page | `cd site && npm run build` (which syncs `docs/` first) |
| an example in the README | nothing by hand; `check-docs` verifies it |

`docs/` is the single source of truth: the site's Cookbook, migration, release and API reference pages are generated
from `docs/` by `tools/site_sync.sh`. Do not edit those pages inside `site/` -- the next build overwrites them.

## Commits

- One commit, one change. Do not mix a bug fix with a docs edit.
- Write the message as *why*, not *what* -- the diff already says what.
- For a behaviour change that needs proving, paste the real command and its output into the commit body or PR.
