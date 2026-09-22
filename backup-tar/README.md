# backup-tar

Archives any number of configured paths into **one compressed tar archive per
path**, under a target directory that is configurable globally and per path.

One archive per path, deliberately: a single archive over everything has to be
unpacked as a whole to get one directory back, one unreadable byte in it costs
all of them at once, and every path would be stuck with the same retention. Here
each path has its own archive, its own retention, its own line in the summary —
and one path failing does not cost the others.

```
BACKUP_BASE/
├── .complete                                  # written only after a clean run
├── nextcloud/
│   ├── nextcloud-2026-07-29T02-30-01.tar.gz
│   └── nextcloud-2026-07-29T02-30-01.tar.gz.sha256
└── photos/
    └── photos-2026-07-29T02-41-17.tar.zst
```

It shares its configuration model, logging, Telegram notification and marker
contract with
[backup-docker-db](https://github.com/sisyphosloughs/backup-docker-db) — see
[Relationship to backup-docker-db](#relationship-to-backup-docker-db). The two are
designed to run next to each other: the dump script writes the databases as
files, this one archives the files.

## What a run does

1. Read `global.conf` and every `instances/*.conf`, validate them, check that the
   programs the configured compressors need are actually there.
2. Take a concurrency lock (`flock`), so two overlapping cron runs cannot write
   into the same target directory.
3. For each path, in order:
   - run `PRE_CMD` (optional — stop the container writing into the source),
   - delete archives older than `RETENTION_DAYS`, keeping at least `KEEP_MIN`,
   - write the archive to `DEST_DIR/<name>-<timestamp>.tar.gz`,
   - read it back to prove it is readable, write its `.sha256`,
   - run `POST_CMD` on **every** exit path, including a failed archive.
4. Write `BACKUP_BASE/.complete` — **only** if not a single error occurred.
5. Log a summary, send it via Telegram, exit `0` only on a fully clean run.

Each path is archived in its own subshell: a path that fails ends there, the
remaining paths still run, and every failure shows up in the summary.

## Files

```
<location>/
├── backup-tar.sh              # the script (identical on all hosts)
├── global.conf                # host-specific global config (from global.conf.example)
├── instances/                     # one *.conf per path that is archived
│   ├── instances.conf.example     # template for a path
│   └── <name>.conf            # e.g. nextcloud.conf, photos.conf
├── lib/
│   └── tar-lib.sh             # archive helpers (compressor, tar call, verification, retention)
└── logs/                      # one log file per run (auto-rotated), created by the script
```

plus, one level up, the shared library of the collection:

```
../lib/runlib/                 # shared run skeleton — git submodule, see below
```

The script determines its own location at runtime; all paths derive from it, so
the location is freely choosable (e.g. `/opt/backup-tar`) — as long as
`lib/runlib/` sits next to it in the parent directory.

**Requires GNU tar** (for `--exclude-caches`, `--one-file-system` and
`--use-compress-program`). `COMPRESSION_LEVEL` and `COMPRESSION_THREADS`
additionally need GNU tar ≥ 1.27. On a host where `tar` is the BSD one, install
GNU tar and point `TAR_BIN` at it — the script checks this at startup and says
so rather than producing a subtly different archive.

## Configuration model

Nothing is hard-coded in the script. Configuration is split in two, exactly as
in `backup-docker-db`:

### `global.conf` — the whole run

| Variable | Default | Meaning |
|---|---|---|
| `BACKUP_BASE` | — (required) | Target directory; each path gets a sub-directory under it. |
| `INSTANCES_DIR` | `instances/` next to the script | Where the per-path configurations live. |
| `MARKER_NAME` | `.complete` | Name of the marker inside `BACKUP_BASE`; `""` disables it. |
| `ARCHIVE_RETENTION_DAYS` | `30` | Default retention of the archives (per path overridable). |
| `KEEP_MIN` | `2` | Archives kept per path **regardless of age**. |
| `LOG_RETENTION_DAYS` | `64` | Log retention; the script rotates its own logs, no logrotate needed. |
| `COMPRESSION` | `gz` | `gz`, `zst`, `xz`, `bz2` or `none`. |
| `COMPRESSION_LEVEL` | empty | Compressor's own default when empty. |
| `COMPRESSION_THREADS` | `0` | Cores for pigz/pbzip2/zstd/xz; `0` = all. |
| `ONE_FILE_SYSTEM` | `false` | Do not descend into other filesystems. |
| `SPARSE` | `false` | Store holes in sparse files (VM images, sparse DB files). |
| `EXCLUDE_CACHES` | `true` | Skip directories tagged `CACHEDIR.TAG`. |
| `EXCLUDE_VCS` | `false` | Skip `.git`/`.svn`/… |
| `VERIFY_ARCHIVE` | `true` | Read every finished archive back — see [Verification](#verification). |
| `WRITE_CHECKSUM` | `true` | Write `<archive>.sha256` next to each archive. |
| `MIN_FREE_MB` | `0` | Refuse to write when the target has less free space; `0` = no check. |
| `NICE_LEVEL` / `IONICE_CLASS` | `0` / empty | Keep a nightly multi-GB archive from starving the host. |
| `BACKUP_MODE` | `0750` | Mode of the target directories. |
| `BACKUP_GROUP` | empty | Group that may read the archives. |
| `BACKUP_UMASK` | `0027` | umask for the archives (→ files `0640`). |
| `TAR_BIN` | `gtar`, else `tar` | GNU tar to use. |
| `EXTRA_PATH` | empty | Directories prepended to `PATH` (cron has a minimal one). |
| `TELEGRAM_CONF` | empty | Path to the file holding `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` for the whole host (0600; in this collection `telegram.conf` in the root directory, from `telegram.conf.example`). Setting the two directly in `global.conf` still wins; leaving both unset disables notifications. |

### `instances/<name>.conf` — one file per path

Adding a path means **adding a file**, never editing the script. The file name
(without `.conf`) is the path's name: the label in the log, the sub-directory
under `BACKUP_BASE`, and the prefix of every archive it produces.

| Variable | Default | Meaning |
|---|---|---|
| `SOURCE` | — (required) | The directory or file to archive. |
| `DEST_DIR` | `$BACKUP_BASE/<name>` | **Where this path's archives go** — a second disk, a mounted share, a bigger volume. |
| `ENABLED` | `true` | `false` skips the path without deleting its configuration. |
| `RETENTION_DAYS` / `KEEP_MIN` | from `global.conf` | Retention for this path. |
| `COMPRESSION` / `_LEVEL` / `_THREADS` | from `global.conf` | Compression for this path. |
| `EXCLUDES` | empty | Array of tar exclude patterns. |
| `EXCLUDE_FROM` | empty | File with one pattern per line. |
| `TAR_EXTRA_OPTS` | empty | Anything else, e.g. `( "--acls" "--xattrs" )`. |
| `PRE_CMD` / `POST_CMD` | empty | Hooks around the archive — see [Consistency](#consistency-pre_cmd--post_cmd). |
| everything else from the table above | from `global.conf` | Per-path override. |

Each file is sourced on its own with all of these reset to the global defaults
beforehand, so values never leak between paths. Only `SOURCE` is required — a
complete, perfectly ordinary configuration is one line:

```bash
SOURCE="/opt/containers/nextcloud"
```

### Where the archives go

Three levels, most specific first:

1. `--dest DIR` on the command line — for one run, overrides everything.
2. `DEST_DIR` in `instances/<name>.conf` — this path's archives, anywhere you like.
3. `BACKUP_BASE/<name>` — the default.

`DEST_DIR` must not lie **inside** `SOURCE`. The run would archive its own
archives and grow without bound, so the script refuses that configuration
instead of producing a backup of backups. If one path's target sits inside
*another* path's source it is only a warning — with small archives that can be
deliberate.

## What ends up in the archive

Paths are stored **relative to the source's parent**: `/opt/containers/nextcloud`
becomes `nextcloud/…` in the archive, not `/opt/containers/nextcloud/…`. That is
what lets you unpack it into a staging directory and look before you overwrite
anything. (`SOURCE="/"` therefore has no meaningful name to store and is
rejected — configure the directories below it.)

Excludes are matched against those stored names. Two GNU tar rules are worth
knowing:

- a pattern **without** a `/` matches at any depth — `node_modules` excludes
  every directory of that name anywhere below the source;
- wildcards also match `/`, so `*/cache/*` spans several levels.

Excluding caches, temp files and re-downloadable data is usually the single
biggest lever on both archive size and runtime.

## Compression

| `COMPRESSION` | Suffix | When |
|---|---|---|
| `gz` | `.tar.gz` | The safe default. Readable everywhere. Uses `pigz` (all cores) when installed, otherwise `gzip`. |
| `zst` | `.tar.zst` | Clearly faster than gzip at a better ratio. Needs `zstd` on the **restoring** host too. |
| `xz` | `.tar.xz` | Smallest, by far the slowest. For archives written once and read almost never. |
| `bz2` | `.tar.bz2` | No reason to prefer it over zstd today; kept for hosts already standardised on it. |
| `none` | `.tar` | Already-compressed data — photos, videos, media libraries. Compressing those only costs CPU. |

The parallel implementations (`pigz`, `pbzip2`) produce ordinary `.gz`/`.bz2`
files, so nothing about restoring changes: `tar -xzf` works with or without
`pigz` on the restoring host. A tar backup of a large tree is CPU-bound on the
compressor, so installing `pigz` is usually the cheapest speed-up available.

## Consistency (`PRE_CMD` / `POST_CMD`)

tar reads a live directory file by file. Whatever changes **while** it reads ends
up in the archive as a mixture of old and new. For static files that is
irrelevant; for a database's files it is the difference between a restore and a
corrupt database.

`PRE_CMD` and `POST_CMD` are where that is handled. Both run through `bash -c`
with `PATH_NAME`, `SOURCE` and `DEST_DIR` in their environment:

```bash
PRE_CMD="docker compose -f /opt/containers/nextcloud/docker-compose.yml stop"
POST_CMD="docker compose -f /opt/containers/nextcloud/docker-compose.yml start"
```

Or, without downtime, dump the database into the directory that is about to be
archived — [backup-docker-db](https://github.com/sisyphosloughs/backup-docker-db)
does exactly that, and this script picks its dumps up as ordinary files.

What you can rely on:

- `POST_CMD` runs on **every** exit path, including a failed archive, so a
  container stopped by `PRE_CMD` comes back up.
- A failing `PRE_CMD` means **no archive is taken**. An archive that only
  pretends to be consistent is worse than a missing one.
- A failing `POST_CMD` makes the path count as **failed** even if its archive is
  fine — the run must not report success, and must not write the marker, while a
  container it stopped stays down.
- If `PRE_CMD` failed, `POST_CMD` is skipped: the state it was to establish never
  existed, and undoing it blindly is guesswork.

## Verification

Every finished archive is read back completely (`tar --list`) before the run
calls it a success. This is the only thing that proves the archive can be read at
all — the one property a backup must have, and the one nobody checks until the
day it matters. An archive that fails is **deleted**: an unreadable archive left
on disk looks like a backup and is not one.

It costs roughly the read half of the backup again. On a host where the backup
window is too tight, `VERIFY_ARCHIVE=false` turns it off — knowing what you are
giving up.

`WRITE_CHECKSUM` additionally writes `<archive>.sha256` next to each archive, so
a later transfer or a suspicious disk can be checked with
`cd <dir> && sha256sum -c <archive>.sha256`.

## Retention

Archives older than `RETENTION_DAYS` are deleted at the **start** of the path's
run — on a nearly full target, making room before writing is what lets the new
archive succeed.

`KEEP_MIN` is the safety net: the newest N archives survive regardless of age.
Without it a source that has not changed for months would have all its archives
expire on the same day and be left with no backup at all. Do not go below 2 — the
older archive is the fallback if the newest one turns out to be unusable.

Rotation matches on the timestamp in the file name, which sorts chronologically
because it sorts lexically. It therefore also survives a copy that did not
preserve mtimes.

## The marker contract

`BACKUP_BASE/.complete` is written atomically (temp file + `mv` inside the same
directory) and **only** after a completely error-free run, so it is never seen
half-written and never vouches for a partial target directory. Its content:

```
completed_at=2026-07-29T02:41:19+0200
completed_epoch=1785292879
host=vps01
paths_ok=3
paths_total=3
archive_bytes=4831838208
generator=tar-backup
```

It is the contract for anything downstream — a backup host pulling this tree, a
monitoring check: **marker present *and* not older than a configurable
threshold** → the directory is usable. Otherwise → alarm, use nothing.

A failed run deliberately leaves an **existing older marker untouched** instead
of deleting it. A reader then still sees yesterday's timestamp, still has
yesterday's valid archives, and raises the alarm as soon as its freshness
threshold is exceeded. Deleting the marker would escalate a single failed path
into a total backup outage.

Partial runs (`--instance`, `--source`) never write it: they say nothing about the
paths they did not touch.

## Setup

1. **Place the files**, e.g. in `/opt/backup-tar`, and make the script
   executable:
   ```bash
   chmod +x backup-tar.sh
   ```

2. **Create the global configuration:**
   ```bash
   cp global.conf.example global.conf
   $EDITOR global.conf          # BACKUP_BASE, compression, Telegram, …
   chmod 600 global.conf        # contains the Telegram token
   ```

3. **One configuration per path:**
   ```bash
   cp instances/instances.conf.example instances/nextcloud.conf
   $EDITOR instances/nextcloud.conf
   chmod 600 instances/*.conf       # may contain credentials in PRE_CMD/POST_CMD
   ```

4. **Optional — prepare read access** for a backup host that fetches the
   archives. A tar of an arbitrary directory contains everything that was in it,
   including files only root could read, so it must not become world-readable:
   ```bash
   groupadd backuppull
   useradd -r -g backuppull -s /usr/sbin/nologin backuppull
   ```
   then set `BACKUP_GROUP="backuppull"` in `global.conf`. The script creates the
   target directories `0750` and setgid and writes the archives `0640`, so the
   group can read them and nobody else can.

5. **Test the run** before putting it in cron:
   ```bash
   ./backup-tar.sh --list                # what is configured?
   ./backup-tar.sh --dry-run             # what would happen, where?
   ./backup-tar.sh --instance nextcloud  # archive one path (writes no marker)
   ./backup-tar.sh                       # the full run
   ```

6. **Schedule it:**
   ```cron
   30 2 * * * /opt/backup-tar/backup-tar.sh >/dev/null 2>&1
   ```
   The script logs to its own file and notifies via Telegram, so cron mail is not
   needed. Run it as root if the sources contain files only root can read —
   otherwise the archive silently misses them.

## Manual runs

```
Usage: backup-tar.sh [options]

  -p, --instance NAME     Archive only this configured path (repeatable).
  -s, --source DIR    Archive DIR without a configuration file (repeatable).
  -d, --dest DIR      Target directory for this run, overrides BACKUP_BASE.
  -n, --dry-run       Show what would be archived where, write nothing.
  -l, --list          List the configured paths and exit.
  -h, --help          Show this help and exit.
```

`--instance` is for testing a new `instances/<name>.conf`, not for scheduled runs: a
partial run leaves the marker alone.

`--source` is the ad-hoc mode — a one-off archive of something that has no
configuration and does not need one:

```bash
./backup-tar.sh --source /var/www --source /etc/nginx --dest /mnt/usb
```

`instances/*.conf` is then ignored entirely, every other setting (compression,
retention, verification) comes from `global.conf`, the archive is named after the
directory, and no marker is written.

## Restoring

The archives are ordinary tar files — no tooling from this repository is needed
to read them, which is the point.

```bash
# What is in it?
tar -tzf nextcloud-2026-07-29T02-30-01.tar.gz | less

# Is it still intact?
sha256sum -c nextcloud-2026-07-29T02-30-01.tar.gz.sha256

# Unpack somewhere harmless FIRST and look, before overwriting anything:
mkdir /tmp/restore && tar -xzf nextcloud-…tar.gz -C /tmp/restore
#  -> /tmp/restore/nextcloud/…

# A single file:
tar -xzf nextcloud-…tar.gz -C /tmp/restore nextcloud/config/config.php
```

`-z` is for `.tar.gz`; use `-J` for `.tar.xz`, `-j` for `.tar.bz2`, and
`--zstd` (or `zstd -dc … | tar -x`) for `.tar.zst`. Restoring as root keeps the
original owners and permissions; restoring as a normal user does not.

**A backup you have never restored is a hypothesis.** Unpack one archive
somewhere and look at it — the verification pass proves the archive is readable,
not that it contains what you assumed.

## Logging and notifications

One log file per run, `logs/tar-backup-<timestamp>.log`, written to the terminal
at the same time and world-readable (paths and sizes, never secrets). Old logs
are deleted after `LOG_RETENTION_DAYS` — no logrotate configuration on the host.

Telegram gets a summary at the end of every run with a per-path status; on
failure the last 50 log lines are attached. An unexpected abort raises its own
alarm through the EXIT trap.

**Exit code `0` only on a completely error-free run** — that is what cron or a
monitoring wrapper evaluates. Any error (a failed archive, an unusable path
configuration, a `POST_CMD` that did not come back) means exit `1` *and* no
completion marker.

An interrupted run (`SIGINT`/`SIGTERM`) raises the abort alarm and writes no
marker. It finishes the archive it is currently writing first — bash defers
signal handlers until the running command returns, and for a backup that is the
better behaviour anyway: you get one complete archive instead of a wasted
partial one. The archive being written is a `.part` file until it is complete, so
an interruption can never leave something behind that looks like a finished
backup; the next run's rotation clears stale `.part` files.

## Relationship to backup-docker-db

This script is the file half of the same idea as
[backup-docker-db](https://github.com/sisyphosloughs/backup-docker-db), and it
deliberately reuses that repository's structure rather than inventing a second
way of doing the same things:

- **`../lib/runlib/` is a git submodule.** The per-run log file, the error
  account, the lock, the configuration loader, the summary and the Telegram
  notification live in [runlib](https://github.com/sisyphosloughs/runlib) and
  are shared by every script of the family, so a log line or a Telegram message
  means the same thing no matter which one produced it. It is bound once for the
  whole collection, not once per script. It replaced the vendored copy of
  `lib/common-lib.sh` that used to sit here. What stays specific to this script
  is the wording (`RUN_WHAT`, `INSTANCE_LABEL`, …) and everything about tar.

  A fresh clone needs `git clone --recurse-submodules`; an existing one
  `git submodule update --init`. To move to a newer runlib, from the root of the
  collection: `git submodule update --remote lib/runlib && git add lib/runlib`.
- **Same configuration model.** `global.conf` for the run, one `*.conf` per unit
  of work, sourced in isolation with everything reset beforehand. Adding a path
  is adding a file.
- **Same run shape.** Log file before configuration, EXIT trap as soon as the
  Telegram credentials are known, `flock`, per-unit subshell, error-free-only
  completion marker, exit `0` only on a clean run.
- **Same marker contract**, so the same pull side can consume both trees.

What is specific to this script: the compressors, the archive/verify/checksum
step, retention with `KEEP_MIN`, and `PRE_CMD`/`POST_CMD` in place of
`STOP_SERVICES` — a path is not a compose stack, so the hook is a plain command
instead of a list of services.

**Used together:** point `backup-docker-db` at a staging directory *inside* the
stack, or run its dump from this script's `PRE_CMD`, and the archive contains the
files and a consistent database dump next to each other.


## Telegram credentials

The token and chat id live in **one file for the whole host**, not once per
script, so rotating them is a single edit: `telegram.conf` in the root of the
collection, next to the module directories, created from
`telegram.conf.example` there. It is gitignored and not synced like every other
`*.conf`, and it stays inside the tree on purpose — the other secrets of the
collection (`repo.password`, the `global.conf` files) are there as well, so one
place holds everything a host has to protect. Point `TELEGRAM_CONF` in
`global.conf` at it; `ROOT_DIR` is the collection root, which the script sets
before it sources `global.conf`:

```bash
# global.conf
TELEGRAM_CONF="$ROOT_DIR/telegram.conf"
```

```bash
# <collection root>/telegram.conf   —   from telegram.conf.example, chmod 600
TELEGRAM_BOT_TOKEN="123456:AA..."
TELEGRAM_CHAT_ID="987654"
```

`TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` set directly in `global.conf` still
take precedence, so scripts can be moved over one at a time. Leaving both unset
(or at `"xxx"`) disables notifications. A `TELEGRAM_CONF` that is set but
unreadable is reported as an error rather than silently swallowed — a backup
that has quietly stopped reporting is the failure this notification exists to
prevent.

## Troubleshooting

**"is not GNU tar"** — the host's `tar` is BSD tar or busybox tar. Install GNU
tar and set `TAR_BIN` (often `TAR_BIN="gtar"`).

**"tar reported changed files during the run (exit 1)"** — files changed while
tar read them. The archive was written and is readable; single files may be a
mixture of before and after. Normal on a live system; if it concerns files that
must be consistent, quiesce the writer with `PRE_CMD`.

**"target directory lies inside the source"** — `DEST_DIR` is below `SOURCE`, so
the archives would archive themselves. Move `DEST_DIR` outside the source.

**"archive is not readable"** — the verification pass could not read back what
was just written; the file was deleted. Almost always the storage or the
filesystem underneath, not tar. Check `dmesg` and the free space of the target.

**"only N MB free … MIN_FREE_MB"** — the target is running out of space. Lower
`RETENTION_DAYS`, exclude more, or switch that path to `zst`/`xz`.

**"tar not found" under cron, but it works in the shell** — cron's minimal
`PATH`. Set `EXTRA_PATH` in `global.conf`.

**The run takes far too long** — install `pigz` (parallel gzip) or switch to
`COMPRESSION="zst"`; set `COMPRESSION="none"` for already-compressed data; and
check what the excludes are *not* catching with
`tar -tzf <archive> | sed 's|/[^/]*$||' | sort | uniq -c | sort -rn | head`.

**A path is missing files that are there** — the script is probably not running
as root, or `ONE_FILE_SYSTEM=true` is stopping it at a mount point below the
source.
