# Install and upgrade

Three ways to install. Pick one: a single command, a local checkout, or an offline internal mirror.

## One command

```bash
curl -fsSL https://github.com/yi-nology/shellkit/releases/latest/download/install.sh | bash
```

The default prefix is `/usr/local`; if it is not writable, the installer falls back to `~/.local`.

The script itself never writes a file into the target directory. It only does four things:

1. Resolve the latest version (the `releases/latest` redirect).
2. Download `shellkit-<version>.tar.gz` and `SHA256SUMS`.
3. Verify sha256 -- a mismatch exits 5 and not a single byte is written.
4. Unpack the archive and hand over to the bundled `shellkit install-self`.

**The install logic exists exactly once**, inside `install-self`. The bootstrap script merely downloads it --
otherwise "one-click install" and "manual install" would eventually produce two different layouts.

<ShotFigure src="/diagrams/install-chain.svg" caption="The five-step trust chain: a sha256 mismatch exits 5 and not one byte lands on disk" />

The URL is a release asset, never `raw.githubusercontent.com`. The latter gets reset on some networks,
and the repository path is fixed anyway, so neither the website nor the README uses raw.

## Homebrew

```bash
brew install yi-nology/shellkit/shellkit
```

The tap lives in [yi-nology/homebrew-shellkit](https://github.com/yi-nology/homebrew-shellkit).
The formula is a generated artefact: `tools/brew_formula.sh` in the upstream repository produces it, and its
sha256 comes from the release `SHA256SUMS` -- Homebrew requires a byte-exact match, so a hand-copied
checksum is always wrong.

## Try it without installing (one command)

```bash
curl -fsSL https://github.com/yi-nology/shellkit/releases/latest/download/demo.sh | bash
```

It downloads the release, verifies the sha256, unpacks into a temporary directory, generates a project,
runs that project's **own** tests (on the real binary) and prints a short tour. Nothing is installed on
your machine; the temporary directory is removed when the process exits, and only the demo project remains.

## Pin a version, change the prefix, use a mirror

```bash
# change the install prefix
curl -fsSL https://github.com/yi-nology/shellkit/releases/latest/download/install.sh | PREFIX="$HOME/.local" bash

# pin a version
curl -fsSL https://github.com/yi-nology/shellkit/releases/latest/download/install.sh | VERSION=0.18.0 bash

# internal mirror: <base>/v<version>/<asset>
curl -fsSL https://github.com/yi-nology/shellkit/releases/latest/download/install.sh | SHELLKIT_RELEASE_BASE=https://mirror.example/shellkit bash
```

The mirror must be laid out as `<base>/v<version>/shellkit-<version>.tar.gz`. Even a local mirror
built with `file://` has to live under the `v<version>/` subdirectory, or the download fails.

## Install the working tree from a checkout

When you have cloned the repository and want **the current code**, not a release:

```bash
./shellkit install-self
./shellkit install-self --prefix "$HOME/.local"
```

`install.sh --prefix DIR` is equivalent to unpacking first and then calling `install-self`.

## Update

```bash
shellkit update --check
shellkit update
```

`--check` only compares versions, and **stdout carries the version number and nothing else**, so it pipes straight into scripts:

```bash
latest=$(shellkit update --check)
if [ "$latest" != "$(cat VERSION)" ]; then
  log_warn "new version available: $latest"
fi
```

`update` downloads, verifies sha256, and only then replaces anything. Offline or behind a firewall, hand it a local archive:

```bash
shellkit update --from shellkit-0.18.0.tar.gz --sha256 "$SUM"
```

## Uninstall

```bash
shellkit uninstall-self
```

Installation records every file it actually wrote into `PREFIX/share/shellkit/MANIFEST`. Uninstall removes only
the relative paths listed there; anything containing `../` is skipped with a warning. **Without a manifest it fails
with exit code 3** and leaves the decision to a human -- guessing is the fastest way to delete somebody else's files.

## What landed where

```text
PREFIX/bin/shellkit                  entry point
PREFIX/share/shellkit/lib/           the library (bootstrap.sh + core/*.sh)
PREFIX/share/shellkit/locale/        translations
PREFIX/share/shellkit/templates/     templates used by shellkit new
PREFIX/share/shellkit/tests/         assertions and runner (an installed copy can test itself)
PREFIX/share/shellkit/MANIFEST       the uninstall ledger
```

## Exit codes

| Code | When |
| --- | --- |
| 0 | Installed |
| 2 | Bad arguments (for example `--prefix` with no value) |
| 3 | Precondition unmet (no write permission, `PREFIX` is a file rather than a directory) |
| 4 | Download failed |
| 5 | Verification failed (sha256 mismatch, corrupt archive) |

`shellkit update` uses the same five codes, so callers can branch on them directly.
