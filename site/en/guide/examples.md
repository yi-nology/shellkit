# Example projects

Two complete projects you can run right now. What they demonstrate is **assembly**, not reimplementing the library.

## deploy-service: install a systemd unit idempotently

[examples/deploy-service](https://github.com/yi-nology/shellkit/tree/main/examples/deploy-service)

The job: write a unit file, enable it, restart the service -- and running it again changes nothing.

```text
examples/deploy-service/
|-- bin/deploy-service
|-- lib/app.sh
|-- commands/install.sh
|-- commands/status.sh
|-- tests/test_deploy.sh
`-- vendor/shellkit/
```

Three things matter:

1. **The destination is injected as a variable**, so the test never touches real system directories:

   ```bash
   DEPLOY_ROOT=${DEPLOY_ROOT:-/}
   dest="$DEPLOY_ROOT/etc/systemd/system/app.service"
   fs_atomic_write "$dest" "$unit" 644
   ```

2. **Idempotence comes from comparing content**, not from delete-then-create. If nothing changed, nothing is written
   and `systemctl` does not restart -- otherwise every run restarts the service, which in production is an incident.
3. **stdout carries data only**: the `status` subcommand prints one machine-readable line, logs go to stderr.

Run its test:

```bash
bash examples/deploy-service/tests/test_deploy.sh
```

## fetch-release: download, verify, switch atomically

[examples/fetch-release](https://github.com/yi-nology/shellkit/tree/main/examples/fetch-release)

The job: fetch an archive from upstream → verify sha256 → unpack → switch the symlink atomically → keep the
previous version for rollback.

Three things matter:

1. `net_download URL DEST SHA256` verifies the cache itself: if the local file already matches, it does not download again.
2. Upstream is `file://`, so the test is **fully offline** and depends on nothing external.
3. The switch goes through `fs_ensure_symlink`: it is atomic and **never overwrites a regular file**. If the target
   is a real directory rather than a symlink, it reports an error instead of deleting and starting over.

```bash
bash examples/fetch-release/tests/test_fetch.sh
```

## Why the tests go through the real binary

These two projects' tests **do not source internal functions**. They execute `bin/<name>` and assert on exit codes
and stdout. The reason: sourcing tests "the function does what I think it does", while executing the binary tests
"the behaviour a user receives". Only the latter catches things like "a subcommand was never registered" or
"the entry script cannot find vendor/", which are exactly the mistakes assembly makes.

Want more scenarios? [Cookbook](./cookbook.md) has fourteen, each as *scenario / code / why*.
