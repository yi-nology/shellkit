# Five hard rules

These are not style preferences. Each one has a concrete failure mode, and violating it makes the script fail in
an obscure place that does not look like the script's fault ("the config value I read has `[INFO]` stuck to it").

## 1. stdout carries data only; logs always go to stderr

```bash
# Right: the function output is capturable, logs do not interfere
port=$(conf_get_any PORT 8080)
log_info "using port $port"
```

If `log_info` also wrote to stdout, `$(...)` would capture `[INFO] using port 8080`, so `$port` would become
`[INFO] using port 8080`, and every later use of it -- building a URL, opening a socket -- fails, with the error
surfacing somewhere completely unrelated.

Where this lands in the library: every `log_*` writes to `>&2`. It is also why `shellkit update --check` can
print a single version number and nothing else.

## 2. Out-parameters use `printf -v`; a function never assigns into the caller's variables

Bash 3.2 has no nameref (`local -n` arrived in 4.3), so there are only two reliable ways to return more than one
value: print to stdout and let the caller capture it, or let the caller name the destination. The library uses the second:

```bash
# the caller decides where the result lands
split_host_port() {
  local __target=$1 __outvar=$2 __host __port
  __host=${__target%%:*}
  __port=${__target##*:}
  printf -v "$__outvar" '%s %s' "$__host" "$__port"
}

split_host_port db.example.com:5432 parsed
log_info "parsed: $parsed"
```

Why not a "global variable by convention": two concurrent calls would overwrite each other. With `printf -v` the
variable name comes from the caller, so scoping is correct by construction.

One trap to avoid: `printf -v` assigns to the nearest scope that declares that name. If the out-parameter
name happens to match one of the library's own locals, the value is written into that inner scope -- your variable keeps
the old value, and nothing fails. The library therefore keeps a **reserved list** of every local on the
out-parameter path; calling with one of those names returns exit code 2 instead of failing silently. Names
outside the list work as usual, `__` prefix or not.

## 3. Precedence: explicit argument > environment variable > config file > default

```bash
conf_init ./config || exit $?

# PORT from the environment > PORT in the config file > 8080
port=$(conf_get_any PORT 8080)
```

This is implemented exactly once, inside `conf_get_any`. Reimplementing it per script means some script forgets
to look at the environment, so `PORT=9090 ./deploy.sh` silently does nothing for it -- and that kind of
inconsistency is very hard to test for.

`conf_get` reads the config file only; `conf_get_any` adds the environment. If you want "ignore the config file,
always use this value", use `conf_get` with your own default.

## 4. File writes are always atomic

```bash
# Interrupting it cannot leave half a file: temp file + mv -f
fs_atomic_write /etc/app/conf "$content" 600

# Backups sort by name and keep the newest five; two runs in the same second do not clobber each other
fs_backup /etc/app/conf 5
```

A `>` redirect interrupted halfway leaves a **syntactically broken** config. The next start reads it and the error
usually points at the file contents rather than at "the last write was interrupted". Temp file + `mv -f` is an
atomic replace on the same filesystem.

The `fs_ensure_*` family writes atomically too and preserves the original mode with `cp -p`. Plain `echo >>` on a
mode-600 file turns it into 644 -- the most common "I only changed a setting and the key file became world-readable"
incident there is.

## 5. The library never changes the caller's shell options or working directory

`set -euo pipefail` is enabled by **your entry script**, not by the library. Once a library is sourced it shares
the shell, so if it ran `set -e` itself, every deliberate `grep -q x || true` in the caller would start behaving
differently.

Likewise the library never `cd`s. Functions that need another directory do it in a subshell:

```bash
# inside the library: parentheses = subshell, the cwd change cannot leak
( cd "$dir" && tar -czf "$out" . )
```

So you can safely enable `set -euo pipefail` in your entry point. The library will not switch it off, and adds no
other global side effects.

## Two related practices

- **Fail with the documented exit code**, never a blanket `exit 1`. See the exit-code table in [Troubleshooting](./troubleshooting.md).
- **Leave a way back when you delete something.** `shellkit uninstall-self` depends on MANIFEST, and
  `fs_ensure_symlink` never overwrites a regular file. Same idea both times: do not guess when unsure.
