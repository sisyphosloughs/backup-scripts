# backup-scripts

The backup scripts of this host family, in one repository. Each module is a
self-contained script with its own configuration and its own README; they share
one library and are chained by a nightly wrapper.

```
backup-docker-db  ->  /srv/backup/db-staging  ─┐
backup-tar        ->  /srv/backup/tar         ─┴─>  backup-restic-push  ->  restic repos
```

## Modules

| Module | Does |
|---|---|
| [`backup-docker-db/`](backup-docker-db/) | Dumps the databases of Docker stacks locally (SQLite, MariaDB, MySQL, PostgreSQL) into a staging directory and writes a completion marker. Holds no backup credential. |
| [`backup-tar/`](backup-tar/) | Writes **one compressed tar archive per configured path**, with per-path retention, checksum and verification. |
| [`backup-restic-push/`](backup-restic-push/) | Pushes local directories — including the output of the two above — into one or more restic repositories. Any restic backend; rclone only for `rclone:` targets. |
| [`lib/runlib/`](lib/runlib/) | The shared run skeleton: log file, error account, lock, `instances/*.conf` loader, summary, Telegram, completion marker, command logging. Git submodule, see below. |

`backup-wrapper.sh` is the cron entry point: it runs the three scripts in the
order above, once per night.

Each module keeps its own domain library next to its script — 
`backup-docker-db/lib/db-dump-lib.sh` (engines, container detection, dump
rotation) and `backup-tar/lib/tar-lib.sh` (compressor choice, tar call,
verification, archive rotation). Those are not generic and deliberately stay out
of `runlib`.

## The shared library

`lib/runlib/` is a git submodule pointing at
[sisyphosloughs/runlib](https://github.com/sisyphosloughs/runlib), so every
script of the family runs the same skeleton and a log line means the same thing
no matter which one produced it. What differs per script is its wording, set
through the knobs runlib reads (`RUN_WHAT`, `INSTANCE_LABEL`, …).

```bash
git clone --recurse-submodules git@github.com:sisyphosloughs/backup-scripts.git
# an existing clone:
git submodule update --init
# move to a newer runlib:
git submodule update --remote lib/runlib
```

## Configuration

Live configuration never enters the repository. Per module:

| File | Purpose |
|---|---|
| `<module>/global.conf` | the whole run — from `global.conf.example` |
| `<module>/instances/<name>.conf` | one file per backed-up object — from `instances/instances.conf.example` |
| `backup-restic-push/repos.conf` | the restic repository list |
| `backup-restic-push/repo.password` | restic repository password, `0600` |
| `telegram.conf` | bot token and chat id, `0600`, referenced by `TELEGRAM_CONF` |

Everything ending in `.conf` is gitignored; only the `*.example` templates are
versioned. Set `TELEGRAM_CONF` to a file holding `xxx` values to silence
notifications without a code change.

## Checks

There is no build and no test framework:

```bash
bash -n <script>
cd <module> && shellcheck -x <script> lib/*.sh   # must run from the module dir
```

Dry checks that touch no data and write no completion marker:

```bash
./backup-docker-db/backup-docker-db.sh --list
./backup-tar/backup-tar.sh --list ; ./backup-tar/backup-tar.sh --dry-run
./backup-restic-push/backup-restic-push.sh --list
```

## Requirements

bash 3.2 or newer (busybox is a target too), plus per module: `docker` and the
database clients for `backup-docker-db`, `tar` and a compressor for
`backup-tar`, `restic` (and optionally `rclone`) for `backup-restic-push`.

## Licence

MIT, see [LICENSE](LICENSE).
