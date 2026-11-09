# Bash 3.2 compatibility

The baseline is **Bash 3.2+**, not 4.x and not 5.x. The reason is concrete: the `/bin/bash` that ships with macOS
is 3.2.57, and operations scripts run on other people's Macs, on machines without homebrew, and in slim CI images.

Read this table before you write anything. The left column **crashes outright on 3.2**; it is not a style issue.

| Do not write | Write this instead | What 3.2 does |
| --- | --- | --- |
| `declare -A m` | a `case` dispatch, or two parallel arrays | `declare: -A: invalid option` |
| `${v^^}` / `${v,,}` | `printf '%s' "$v" \| tr a-z A-Z` | `bad substitution` |
| `local -n ref=$1` | out-parameter: `printf -v "$outvar" '%s'` | invalid option |
| `mapfile -t a < f` | `while IFS= read -r l; do ...; done < f` | `command not found` |
| `[[ -v x ]]` | `[ -n "${x:-}" ]` | conditional expression syntax error |
| `"${arr[@]}"` (array may be empty) | `${arr[@]+"${arr[@]}"}` | unbound variable under `set -u` |
| `arr+=(x)` | `arr[${#arr[@]}]=x` | works, but do not mix it with empty-array expansion |

## Why these crash instead of degrading

The first few fail at **parse time**. The parameter expansion `${v^^}` simply does not exist in the 3.2 interpreter,
so it reports `bad substitution` and exits. There is no "partially working" state to fall back from, which is why
you cannot paper over it at runtime -- you must not write it at all.

The last row (empty array expansion) fails at **run time**, and only in a specific combination:

```bash
set -euo pipefail

# on 3.2: unbound variable, the whole script exits
for item in "${arr[@]}"; do
  printf '%s\n' "$item"
done

# correct: expands to nothing when there is no element, instead of naming an undefined variable
for item in ${arr[@]+"${arr[@]}"}; do
  printf '%s\n' "$item"
done
```

Under `set -u`, `"${arr[@]}"` on an empty array is treated as expanding an undefined variable. With the `+` test,
the whole expression disappears when the array is empty and the loop body never runs -- which is the behaviour you want.

## Three traps we already hit

### 1. `trap` semantics differ between bash 3.2 and 5

Inside a **subshell**, `trap -p EXIT` returns nothing on 3.2; on 5.x it still prints the parent shell's trap, but the
subshell does not run it. So idempotence cannot rely on `trap -p` alone: when you see your own handler, install it
again (reinstalling is harmless), and never capture your own handler as if it belonged to the caller.

### 2. `$(trap -p ...)` never reads anything

Command substitution is itself a subshell. To read trap state, redirect it to a file and `cat` that file. Not `$(...)`.

### 3. A command-less `exec` pins the redirection onto the caller

```bash
# wrong: not only closes fd 3, it also sends the caller's stderr to /dev/null from here on
exec 3>&- 2>/dev/null

# right: the redirection disappears with this one command
(: <"/dev/tcp/127.0.0.1/5432") 2>/dev/null
```

The third one is easy to hit when writing a port probe. The symptom is "the test returns 1 but not a single FAIL line
is visible", because the runner's stderr went to `/dev/null`.

## Replacements at a glance

| You want to | On 3.2, write |
| --- | --- |
| dispatch a subcommand | `declare -F cmd_<name>` to test existence |
| return several values | out-parameter + `printf -v` |
| change case | `tr a-z A-Z` |
| append to an array | `arr[${#arr[@]}]=x` |
| iterate a possibly empty array | `${arr[@]+"${arr[@]}"}` |
| test substring containment | `case "$s" in *"$needle"*) ... ;; esac` |

## Self-check

```bash
bash -n my-script.sh
shellcheck -S warning -x my-script.sh
```

`bash -n` catches the parse-time rows (`${v^^}` and `declare -A` only fail at run time on 3.2, so the reliable move
is to actually run it on 3.2). `shellcheck` flags some incompatible constructs, but by default it reasons about the
bash version it was built against.

The one genuinely reliable check: **run it once on the `/bin/bash` that ships with macOS**. `/bin/bash --version`
printing 3.2.57 means that is the one.
