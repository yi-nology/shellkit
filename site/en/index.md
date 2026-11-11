---
home: true
title: shellkit
heroText: A starting point for ops shell scripts
tagline: A Bash library, a project generator and a CLI framework with explicit constraints. The point is not more features, but scripts that are correct and consistent.
actions:
  - text: Quick start
    link: /en/guide/quickstart.md
    type: primary
  - text: Install
    link: /en/guide/installation.md
    type: secondary
  - text: API reference
    link: /en/reference/index.md
    type: secondary
features:
  - title: stdout is for data only
    details: Logs always go to stderr, so v=$(conf_get KEY) never picks up an [INFO] line.
  - title: Output via printf -v
    details: Functions never mutate caller variables. Bash 3.2 has no nameref, so this is the only reliable return channel.
  - title: Baseline is 3.2, not 5.x
    details: The /bin/bash shipped with macOS is 3.2.57. Associative arrays, nameref and mapfile are banned across the library.
  - title: Exit codes are an interface
    details: 0 ok, 1 general error, 2 usage, 3 precondition, 4 network, 5 verification. Callers use them to decide whether to retry.
  - title: Generate a project in one command
    details: shellkit new produces a project with a vendored library copy, tests, a Makefile and the AI contract. make test passes immediately.
  - title: The AI contract is generated too
    details: Banned syntax, task-to-function map and the delivery checklist are assembled from one source of truth.
---

## Install in one command

```bash
curl -fsSL https://github.com/yi-nology/shellkit/releases/latest/download/install.sh | bash
```

Installs to `/usr/local`, falling back to `~/.local` when not writable. Pin a version or change the prefix:

```bash
curl -fsSL https://github.com/yi-nology/shellkit/releases/latest/download/install.sh | PREFIX="$HOME/.local" bash
curl -fsSL https://github.com/yi-nology/shellkit/releases/latest/download/install.sh | VERSION=0.16.0 bash
```

Current version **[Download 0.16.0](https://github.com/yi-nology/shellkit/releases/latest)**.
If the sha256 does not match it exits 5 and writes nothing.

## Real terminal output

Every image below was produced by running real commands: each `$` line in `docs/shots/*.shot` is executed
and the output is rendered as SVG, so versions, paths and exit codes are true at that moment.

<ShotFigure src="/shots/doctor.svg" caption="See what the environment is missing; it never blocks the core library" />

<ShotFigure src="/shots/new-project.svg" caption="The generated project passes make test immediately" />

<ShotFigure src="/shots/gate.svg" caption="Rename a documented function and the gate goes red instead of rotting quietly" />

## 23 modules, one topic each

Your job is assembly, not reimplementation. Full signatures and exit codes: [API reference](/en/reference/index.md).

| Module | Responsibility |
| --- | --- |
| [error](/en/reference/error.md) | fail with a defined exit code |
| [i18n](/en/reference/i18n.md) | English msgids, passthrough without gettext |
| [log](/en/reference/log.md) | everything on stderr, colour optional |
| [str](/en/reference/str.md) | case conversion via tr, because 3.2 has none |
| [validate](/en/reference/validate.md) | reasons land in SK_VALIDATE_ERR |
| [fs](/en/reference/fs.md) | atomic writes, backup rotation, idempotent edits |
| [os](/en/reference/os.md) | the only place Darwin/Linux differ |
| [trap](/en/reference/trap.md) | cleanup stack: LIFO, idempotent, exit-code faithful |
| [run](/en/reference/run.md) | stop on failure; dry-run only prints |
| [retry](/en/reference/retry.md) | backoff retries, never retries usage errors |
| [lock](/en/reference/lock.md) | mkdir atomic lock, pushed onto the cleanup stack |
| [net](/en/reference/net.md) | downloads with sha256 verification and mirror fallback |
| [http](/en/reference/http.md) | HTTP requests, transport errors apart from business errors |
| [config](/en/reference/config.md) | KEY=VALUE and dotenv, env vars win |
| [scaffold](/en/reference/scaffold.md) | template variables, manifests, hooks |
| [prompt](/en/reference/prompt.md) | timeouts fall back to defaults |
| [cli](/en/reference/cli.md) | registration-based dispatch |

## Five hard rules

These are not style preferences; each one has a concrete consequence:

1. **stdout carries data only, logs go to stderr.** Otherwise `$(...)` picks up `[INFO]` and the caller gets a dirty value.
2. **Output through `printf -v "$var"`; never mutate caller variables.** Bash 3.2 has no nameref.
3. **Precedence: explicit argument > environment > config file > default.** Implemented once, in `conf_get_any`.
4. **Every write is atomic.** Temp file plus `mv -f`; an interrupted run never leaves half a file.
5. **The library never changes your shell options or your cwd.** `set -euo pipefail` belongs to your entry script.

Read more in [Conventions](/en/guide/conventions.md) and [Bash 3.2](/en/guide/bash32.md).

## Where to go next

| Your situation | Start here |
| --- | --- |
| Decide in five minutes whether this is worth it | [Quick start](/en/guide/quickstart.md) |
| Scripts already run in production | [Five-step migration](/en/guide/migrating.md) |
| A concrete task: config, downloads, retries, locking | [Cookbook](/en/guide/cookbook.md) |
| Exact signature and exit code | [API reference](/en/reference/index.md) |
| Let an AI write the script | [For AI](/en/guide/ai.md) |
| See a complete project | [Examples](/en/guide/examples.md) |

## License

MIT — see [LICENSE](https://github.com/yi-nology/shellkit/blob/main/LICENSE).

The design skeleton was inspired by [jumpserver/installer](https://github.com/jumpserver/installer) (GPLv3); the original attribution is kept in [NOTICE](https://github.com/yi-nology/shellkit/blob/main/NOTICE). shellkit's code is an independent implementation — no code was copied from upstream.
