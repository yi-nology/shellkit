# FAQ

## Why not just use bash 5?

Because the `/bin/bash` that ships with macOS is 3.2.57, and plenty of machines cannot install homebrew. A 3.2
baseline means the scripts run on other people's Macs and in slim CI images. You can use 5.x on top of it -- the
library just never assumes you have it.

## Why must logs go to stderr?

Because `v=$(conf_get KEY)` has to capture a clean value. If logs also went to stdout, `$v` would become
`[INFO] 8080` and the error would surface somewhere completely unrelated. That single rule is where the whole
design starts.

## Can I use only one or two modules?

By default `lib/bootstrap.sh` loads all 20 modules -- each module is small, and the lot is under 400KB.

To slim it down, name the modules you want:

```bash
SHELLKIT_MODULES="log fs" . ./vendor/shellkit/lib/bootstrap.sh
```

Only the listed modules are loaded, and their **transitive dependencies come along automatically** (`i18n` is always
loaded, because every module needs translations). An unknown module name is an error, not a silent skip.

If you only want the testing capability, copy `tests/run.sh` and `tests/test_helper.sh` -- two files, zero
dependencies.

## Why does `shellkit new` copy the library into `vendor/`?

Two reasons: CI does not need shellkit installed first, and "someone upgraded the system shellkit last week" cannot
silently change what today's build produces. `shellkit vendor . --check` compares byte by byte to catch local edits
to vendor.

## Is a generated project production-ready?

Yes, after three things: replace `config.example` with documentation of the real paths; replace the TODOs in
`commands/` with real logic; and confirm the exit-code classification is right (do not leave a blanket `exit 1`).

## What does `run` do that typing the command does not?

`run` dies on failure and includes the original command text and its exit code in the message. With
`SHELLKIT_DRY_RUN=1` it only prints, and the printed command is **quoted** so you can copy and run it as-is. To judge
success inside a condition, use `run --no-die`.

## Why does the `exit` inside `die` ignore `if` / `||`?

Because `die` calls `exit`, not `return`. In `if run rsync ...`, `run` calling `die` still terminates the script;
`if` cannot intercept it. That is intentional: the default semantics are "stop on failure", and wrapping it in a
condition must not quietly turn it into "carry on after failure".

## What is the difference between `conf_get` and `conf_get_any`?

`conf_get` reads the config file only; `conf_get_any` applies "environment > config file > default". If you want
`PORT=9090 ./deploy.sh` to take effect, use the latter.

## Do I need gettext for internationalisation?

No. Without gettext installed, `_t` returns the English message id and the program runs as usual, and
`po/messages.sh --check` skips rather than fails. You only need gettext when you want to **regenerate** translations.

## Why does uninstall depend on MANIFEST?

Because guessing is the shortest path to deleting somebody else's files. Installation records exactly what it wrote;
uninstall removes only those relative paths and skips anything containing `../`. No manifest means exit 3, and a
human decides.

## Can I use it on a machine without root?

Yes. `shellkit install-self --prefix "$HOME/.local"` installs into your own directory; add `$HOME/.local/bin` to
`PATH`. The modules that do not need root at run time (`conf_*`, `fs_*`, `net_*`) all work; where root is genuinely
required, `require_root` reports 3 explicitly instead of some random step failing later.

## What size of script is this meant for?

Anything from a 50-line ops tool to a multi-thousand-line installer. It is not a "business framework"; it only
covers the parts **every script rewrites and every script writes differently**: logging, exit codes, config I/O,
download verification, retries, locking, cleanup, prompting, CLI, and translations.
