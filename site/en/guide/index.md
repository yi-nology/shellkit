# Guide

This documentation is organised by *what you need to solve right now*, not by feature directory.
Every page stands on its own; the cross-links tell you where to go next.

## Three common paths

| Your situation | These three pages are enough |
| --- | --- |
| First contact, deciding whether it is worth using | [Thirty seconds](./quickstart.md) → [Five hard rules](./conventions.md) → [Cookbook](./cookbook.md) |
| Scripts already in production, want the library without a rewrite | [Install](./installation.md) → [Five-step migration](./migrating.md) → [Testing and gates](./testing.md) |
| Need the exact signature of one function | [API reference](/en/reference/index.md), one page per module |

## Getting started

- [Install and upgrade](./installation.md) -- one command, pinned versions, internal mirrors, offline archives, update and uninstall.
- [Thirty seconds](./quickstart.md) -- generate a project, read its layout, add your first subcommand.

## Core concepts

- [Five hard rules](./conventions.md) -- why stdout carries data only, and why out-parameters use `printf -v`.
- [Bash 3.2 compatibility](./bash32.md) -- the syntax that crashes on the bash macOS ships, and why.
- [Module map](./modules.md) -- the 18 modules, what each one owns, and when to reach for it.

## Common tasks

- [Cookbook](./cookbook.md) -- 24 scenarios, each one *scenario / code / why*.
- [CLI framework](./cli.md) -- registered commands, generated help, option parsing.
- [Internationalisation](./i18n.md) -- English msgids, pot/po/mo, and degrading gracefully without gettext.
- [Testing and gates](./testing.md) -- the assertion library, the per-file runner, what each `make check` step blocks.
- [Working with AI](./ai.md) -- three artefacts from one source, plus a prompt you can paste.

## Advanced

- [Example projects](./examples.md) -- two projects you can run right now; the topic is assembly.
- [Five-step migration](./migrating.md) -- kill stdout pollution first, then configuration, prompts, CLI, tests.
- [Releasing](./releasing.md) -- one command bumps the version, and why it is built that way.
- [Contributing](./contributing.md) -- adding a module means four edits; miss one and the gate goes red.

## When things break

- [Troubleshooting](./troubleshooting.md) -- exit code → symptom → fix.
- [FAQ](./faq.md) -- twelve questions that were actually asked.
