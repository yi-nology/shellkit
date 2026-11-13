---
home: true
title: shellkit
heroText: A starting point for ops shell scripts
tagline: A Bash library plus a project generator and a CLI framework, with explicit constraints.
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
    details: Logs always go to stderr, so $(...) never picks up an [INFO] line.
  - title: Output via printf -v
    details: No nameref in 3.2; this is the only reliable return channel.
  - title: Baseline is 3.2, not 5.x
    details: The macOS /bin/bash is 3.2.57. Associative arrays and nameref are banned.
  - title: Exit codes are an interface
    details: 0 through 5 each mean one thing; callers decide on retry from them.
  - title: Generate a project in one command
    details: shellkit new ships a vendored library and tests; make test passes immediately.
  - title: The AI contract is generated too
    details: Banned syntax and the task map are assembled from a single source of truth.
# footer and footerHtml must both be set: the theme footer component is v-if="footer".
footer: 'MIT licensed · For AI readers: llms.txt'
footerHtml: '<a href="https://github.com/yi-nology/shellkit/blob/main/LICENSE">MIT</a> · <a href="https://yi-nology.github.io/shellkit/en/llms.txt" target="_blank" rel="noopener noreferrer">For AI readers: llms.txt</a> - one file maps the whole site'
---

## How the three pieces fit together

<ShotFigure src="/diagrams/assembly.svg" caption="The library is the single source of truth: shellkit new vendors it into your project, the CLI covers the daily work" />

Full signatures and exit codes: [API reference](/en/reference/index.md).

## Install in one command

```bash
curl -fsSL https://github.com/yi-nology/shellkit/releases/latest/download/install.sh | bash
```

Installs to `/usr/local`, falling back to `~/.local` when not writable. Pin a version or change the prefix:

```bash
curl -fsSL https://github.com/yi-nology/shellkit/releases/latest/download/install.sh | PREFIX="$HOME/.local" bash
curl -fsSL https://github.com/yi-nology/shellkit/releases/latest/download/install.sh | VERSION=0.18.0 bash
```

Current version **[Download 0.18.0](https://github.com/yi-nology/shellkit/releases/latest)**.
If the sha256 does not match it exits 5 and writes nothing.

## Real terminal output

Every image below was produced by running real commands: each `$` line in `docs/shots/*.shot` is executed and rendered as SVG.

<ShotFigure src="/shots/doctor.svg" caption="See what the environment is missing; it never blocks the core library" />

<ShotFigure src="/shots/new-project.svg" caption="The generated project passes make test immediately" />

<ShotFigure src="/shots/gate.svg" caption="Rename a documented function and the gate goes red instead of rotting quietly" />

## Five hard rules

Each one has a concrete consequence, not a style preference:

1. **stdout carries data only, logs go to stderr.** Otherwise `$(...)` picks up `[INFO]` and the caller gets a dirty value.
2. **Output through `printf -v`; never mutate caller variables.** Bash 3.2 has no nameref.
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
