# backup-scripts

The backup scripts of this host family, in one repository. Each module is a
self-contained script with its own configuration and its own README; they share
one library and are chained by a nightly wrapper.

```
backup-docker-db  ->  /srv/backup/db-staging  ─┐
backup-tar        ->  /srv/backup/tar         ─┴─>  backup-restic  ->  restic repos
                                                 │
                                    backup-rclone-sync (pull)  ->  staging on another host  ->  backup-restic (local repo)
                                    backup-rclone-sync (push)  ->  a cloud without SSH
```

## Modules

| Module | Does |
|---|---|
| [`backup-docker-db/`](backup-docker-db/) | Dumps the databases of Docker stacks locally (SQLite, MariaDB, MySQL, PostgreSQL) into a staging directory and writes a completion marker. Holds no backup credential. |
| [`backup-tar/`](backup-tar/) | Writes **one compressed tar archive per configured path**, with per-path retention, checksum and verification. |
| [`backup-restic/`](backup-restic/) | Backs up local directories — including the output of the two above — into one or more restic repositories, local or remote. Any restic backend; rclone only for `rclone:` targets. |
| [`backup-rclone-sync/`](backup-rclone-sync/) | Mirrors trees with rclone, one per instance: pulls another host's staging or tar tree into a local staging directory (and writes a completion marker there), or pushes a local tree to a cloud. Refuses a source whose completion marker is missing or stale; caps deletions. |
| [`lib/runlib/`](lib/runlib/) | The shared run skeleton: log file, error account, lock, `instances/*.conf` loader, summary, Telegram, completion marker, command logging. Git submodule, bound once for all modules, see below. |

`backup-wrapper.sh` is the scheduler's entry point: a host-local copy of
`backup-wrapper.example.sh` (gitignored, not synced) that runs this host's
stages in order, once per night.

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

It is bound **here and nowhere else**: each module resolves it as
`../lib/runlib`, so one pointer moves all four scripts and they cannot drift
apart. The flip side is that a module directory does not run on its own — it
needs `lib/` beside it, both when testing and when rolling out.

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
| `backup-restic/repos.conf` | the restic repository list |
| `backup-restic/repo.password` | restic repository password, `0600` |
| `telegram.conf` | bot token and chat id for the whole host, `0600`, in the root of the collection — from `telegram.conf.example`, referenced by `TELEGRAM_CONF` in every `global.conf` |

Everything ending in `.conf` is gitignored; only the `*.example` templates are
versioned.

The Telegram credentials are one file per host, not one per module, so
rotating the token is a single edit. That file is `telegram.conf` in the root
of the collection, next to the module directories. It stays inside the tree
deliberately: the other secrets (`repo.password`, the `global.conf` files) live
here as well, so one place holds everything a host has to protect, and the
`*.conf` rule keeps it out of git and out of the sync. Each module's
`global.conf` points at it with `TELEGRAM_CONF="$ROOT_DIR/telegram.conf"`,
where `ROOT_DIR` is the collection root the script sets before it sources
`global.conf`. Leaving both values at `xxx` silences notifications without a
code change.

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
./backup-restic/backup-restic.sh --list
./backup-rclone-sync/backup-rclone-sync.sh --list ; ./backup-rclone-sync/backup-rclone-sync.sh --dry-run
```

## Requirements

bash 3.2 or newer (busybox is a target too), plus per module: `docker` and the
database clients for `backup-docker-db`, `tar` and a compressor for
`backup-tar`, `restic` (and optionally `rclone`) for `backup-restic`, `rclone`
for `backup-rclone-sync`.

## Licence

MIT, see [LICENSE](LICENSE).
