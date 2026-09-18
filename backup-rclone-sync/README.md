# backup-rclone-sync

Mirrors directory trees between this host and somewhere else with
[rclone](https://rclone.org), one mirror per configured instance. Either side
may be a local path or an rclone remote, so one script covers two jobs the
collection had no script for:

| Direction | Mirror | Role in the pipeline |
|---|---|---|
| **pull** | `milos:/srv/backup/tar` → `/volume1/backup/staging/milos-tar` | a **producer**, like `backup-docker-db` and `backup-tar`: writes a completion marker into the local tree, which `backup-restic` then backs up into a repository on this host |
| **push** | `/volume1/backup/staging/milos-tar` → `pcloud:Backup/milos-tar` | a **consumer**, like `backup-restic`: copies a local tree to a cloud that speaks no SSH; no marker |

It copies **what it is pointed at and nothing else**: no archive is created, no
snapshot taken. That is deliberate — each script in this family does one job:

| Script | Does |
|---|---|
| [backup-docker-db](../backup-docker-db/) | dumps the databases of Docker stacks into a staging directory |
| [backup-tar](../backup-tar/) | writes one compressed tar archive per configured path |
| [backup-restic](../backup-restic/) | backs up local directories into restic repositories |
| **this script** | moves trees between hosts and clouds, so the three above can work on local paths |

So a remote host's data ends up in a local restic repository by pulling it into
staging here and pointing a `backup-restic` instance at the staging directory —
not by teaching `backup-restic` about SSH.

## Files

```
<location>/
├── backup-rclone-sync.sh        # the script (identical on all hosts)
├── global.conf                  # host-specific global config (from global.conf.example)
├── instances/                   # one *.conf per mirror
│   ├── instances.conf.example   # template for a mirror
│   └── <name>.conf              # e.g. milos-tar.conf, milos-db.conf, cloud-tar.conf
├── lib/
│   └── rclone-sync-lib.sh       # rclone helpers: log filter, marker fetch, statistics
└── logs/                        # one log file per run (auto-rotated), created by the script
```

plus, one level up, the shared library of the collection:

```
../lib/runlib/                   # shared run skeleton — git submodule, see below
```

The script determines its own location at runtime; all paths derive from it, so
the location is freely choosable — as long as `lib/runlib/` sits next to it in
the parent directory.

## Configuration model

Configuration is split in two:

- **`global.conf`** — switches that apply to the whole run: `RCLONE_BIN`,
  `RCLONE_CONFIG_FILE`, `STAGING_BASE`, `MARKER_NAME`, `MAX_DELETE`,
  `MARKER_MAX_AGE_HOURS`, `PROGRESS_INTERVAL`, bandwidth and parallelism,
  access mode and group of the staging tree, `TELEGRAM_CONF`,
  `LOG_RETENTION_DAYS`.
- **`instances/<name>.conf`** — one file per mirror. The script collects every
  `*.conf` in `instances/`. The file name (without `.conf`) is the mirror's
  name in the log and its sub-directory under `STAGING_BASE`. Each file may
  set:

  | Variable | Default | Meaning |
  |---|---|---|
  | `SOURCE` | — (required) | Tree to read: an absolute local path or `remote:path`. |
  | `DEST` | `$STAGING_BASE/<name>` | Where it lands: an absolute local path or `remote:path`. |
  | `MODE` | `sync` | `sync` mirrors (deletions included), `copy` only adds and updates. |
  | `SOURCE_MARKER` | empty | Name of the producer's completion marker at the root of `SOURCE`. Set it, and the mirror refuses to run when that marker is missing or stale. |
  | `MARKER_MAX_AGE_HOURS` | from `global.conf` (26) | How old the source marker may be. |
  | `EXCLUDES` / `EXCLUDE_FROM` | empty | rclone filter patterns, relative to `SOURCE`. |
  | `MAX_DELETE` | from `global.conf` (100) | How many deletions a `sync` may perform before it is aborted. |
  | `RCLONE_OPTS` | empty | Extra rclone flags for this mirror. |
  | `ENABLED` | `true` | `false` skips the mirror without deleting its file. |

A path is **local** when it starts with `/`; everything else must carry a colon
(`name:path` from `rclone.conf`, or an on-the-fly
`:sftp,host=…,user=…,key_file=…:path`). Anything else is rejected, so a typo
cannot silently become a relative local path.

## What a run does

1. Read `global.conf` and every `instances/*.conf`, validate them (a mirror
   inside its own source, a source inside its mirror, and two mirrors sharing a
   local tree are refused), check that rclone is there and its configuration
   readable.
2. For each mirror, in its own subshell:
   - if `SOURCE_MARKER` is set, fetch it with `rclone cat` and read
     `completed_epoch`; a missing or stale marker fails the mirror **before
     anything is copied**;
   - for a local destination, create it with the configured mode and group;
   - run `rclone sync` (or `copy`) with the excludes, the deletion cap and the
     script's own markers excluded, streaming rclone's JSON log through a filter
     that writes one progress line per `PROGRESS_INTERVAL` seconds and keeps the
     final statistics.
3. Write a completion marker into every **local** destination that was mirrored
   without error. A failed mirror keeps its older marker: a reader judges by
   age, and yesterday's tree is still yesterday's good tree.
4. Summary to the log + Telegram notification.

## Retention, and the two guards that replace it

A mirror has **no retention of its own**. `sync` makes the destination an exact
copy of the source, deletions included, so what is kept for how long is decided
where the data is produced (`backup-tar`'s `ARCHIVE_RETENTION_DAYS`,
`backup-docker-db`'s `DUMP_RETENTION_DAYS`) or where its history lives
(`backup-restic`'s `forget`). A tar tree pushed to a cloud has exactly the
retention of the host that writes it, `KEEP_MIN` safety net included.

The flip side is the classic accident: a source that is suddenly empty — a
share that was not mounted, a path that moved — would make `sync` empty the
destination too. Two guards cover it:

- **`MAX_DELETE`** caps the deletions of one run (`--max-delete`). Above the
  cap rclone stops deleting, the copies already made stay, the mirror counts
  as failed and keeps its older marker. Size it above what a normal night
  deletes; raise it per mirror for an expected cleanup.
- **`SOURCE_MARKER`** ties a mirror to its producer. `backup-tar` and
  `backup-docker-db` write their marker only after an error-free run, so a
  tree whose marker is missing or older than `MARKER_MAX_AGE_HOURS` is a tree
  whose producer did not finish — and it is not copied over yesterday's good
  copy. The values read (`completed_at`, `host`, `generator`) are recorded in
  this mirror's own marker as `source_completed_at`, `source_host` and
  `source_generator`; the source's marker file itself is not copied.

`MODE="copy"` is the escape hatch for a destination that should hold more than
the source — it never deletes, and the cleanup is yours.

## The completion marker

Every local destination gets `<DEST>/<MARKER_NAME>` (default `.complete`) after
an error-free mirror, written atomically by runlib's `write_marker`:

```
completed_at=2026-09-18T03:12:44+0200
completed_epoch=1789693964
host=ikaria
source=milos:/srv/backup/tar
mode=sync
sync_bytes=138372
source_completed_at=2026-09-18T01:07:02+0200
source_host=milos
source_generator=tar-backup
generator=rclone-sync
```

That is the contract with whatever consumes the tree next — a `backup-restic`
instance, a monitoring check, or another mirror that names it as its
`SOURCE_MARKER`. A push (remote destination) writes no marker; the run's
summary then says so.

## What rclone can and cannot carry

rclone copies file contents and modification times. Between two **local**
paths it also carries mode, owner and group (`--metadata` is added
automatically). Over **sftp** or a **cloud** backend it cannot: files in the
staging tree belong to the user running the script, with the mode the umask
(`STAGING_UMASK`) gives them, and `backup-restic` records exactly that. For
dumps, archives, documents and media this does not matter. For a tree whose
ownership must survive a restore — a container's data directory — mirror the
tar archive `backup-tar` makes of it: tar keeps uid and gid inside the archive.

Symlinks in a local source are skipped with a notice; add `--links` (copy as
`.rclonelink` files) or `--copy-links` (follow) to `RCLONE_OPTS` if you want
them. An sftp source prints one notice per symlink it skips;
`--sftp-skip-links` silences it.

Excludes use rclone's filter syntax, relative to `SOURCE`. The two rules worth
knowing: a pattern without a leading `/` matches at any depth, one with a
leading `/` only at the root; `*` does not cross `/`, `**` does — so a
**directory** and its contents are excluded with `name/**`, a bare `name` only
matches a file of that name. DSM shares want `"@eaDir/**"`, `"#recycle/**"`
and `"#snapshot/**"`.

## Setup

1. **Create the global configuration** (host-specific):
   ```bash
   cp global.conf.example global.conf
   $EDITOR global.conf
   ```
   Set `STAGING_BASE`, and `RCLONE_BIN` / `RCLONE_CONFIG_FILE` where the
   scheduler's `PATH` or user differs from the one you configured rclone as.

2. **Configure the remotes** — as the user the script will run as:
   ```bash
   rclone config        # sftp remote per source host, cloud remote per push target
   ```
   An sftp remote needs a key the source host accepts. Use a key of its own,
   restricted on the source to what the mirror reads (`command=` in
   `authorized_keys`, or `ForceCommand internal-sftp` with a chroot), and keep
   `rclone.conf` at `0600`. It must **not** be password-encrypted for an
   unattended run — rclone would block on the password prompt.

   > The script runs as **root** under cron or a task scheduler. If `rclone
   > config` was run as a normal user, the `rclone.conf` sits in that user's
   > home and is not what root reads. Either configure as root, or set
   > `RCLONE_CONFIG_FILE` in `global.conf` to the absolute path. The script
   > checks this at startup and writes the result to the log.

3. **Create one instance per mirror:**
   ```bash
   cp instances/instances.conf.example instances/milos-tar.conf
   $EDITOR instances/milos-tar.conf
   ```
   A pull from another script of this family sets `SOURCE_MARKER`; a push sets
   `DEST` to the remote.

4. **Try it without writing anything:**
   ```bash
   ./backup-rclone-sync.sh --list       # what is configured
   ./backup-rclone-sync.sh --dry-run    # what rclone would copy and delete
   ```

5. **Point the consumer at the staging tree** — one `backup-restic` instance
   per mirror, with `BACKUP_PATH` set to the mirror's `DEST` and a local
   repository in its `repos.conf`.

## Running

```bash
sudo ./backup-rclone-sync.sh
```

| Option | Meaning |
|---|---|
| `-i`, `--instance NAME` | Mirror only this instance (repeatable). The other mirrors and their markers are left untouched. |
| `-n`, `--dry-run` | rclone lists what it would copy and delete; nothing is written, no marker is touched. |
| `-l`, `--list` | List the configured mirrors, then exit. Writes nothing. |
| `-h`, `--help` | Show the usage summary. |

Exit code: `0` on success, `1` on one or more errors.

## What the notification says

```
✅ [ikaria] rclone sync completed
Duration: 4m12s
Mirrors: 3/3 successful
Data: 1.2 GB
Marker: written for all 2 local mirrors

  - milos-db: ok — 84.3 MB in 0m20s
  - milos-tar: ok — 1.1 GB in 3m40s
  - cloud-tar: ok — 1.1 GB in 0m12s
```

`Data:` is what rclone transferred — the difference, not the size of the trees.
A mirror that was refused because its source marker was stale, or aborted at
the deletion cap, shows as `FAILED (exit N)` with the reason a few lines up in
the log; the summary of the run then says `written for 1 of 2 local mirrors`.

## Logging

One file `logs/rclone-sync-<timestamp>.log` per run; output also goes to stdout.
rclone's own messages are rendered into it with their level and object
(`[RCLONE] ERROR: sub/b: Got fatal error on delete: --max-delete threshold
reached`), and one `[STATS]` line per `PROGRESS_INTERVAL` seconds shows percent,
bytes, files, deletions and ETA. Files older than `LOG_RETENTION_DAYS` (default
64) are deleted at the start of each run. Log files are created world-readable
(`0644`); they contain paths and remote names but no secrets — an on-the-fly
remote that carried a password in its spec would, so use `rclone.conf` for
those.

## The shared library

The per-run log file, the error account that decides the exit code, the lock,
the `instances/*.conf` loader, the summary, the Telegram notification and the
completion marker — writing it and, new with this script, reading one back
(`marker_value`, `marker_age`) — are not implemented here. They live in
[runlib](https://github.com/sisyphosloughs/runlib) and are pulled in as a git
submodule at `../lib/runlib/`, bound once for the whole collection.

What stays in this script is what is about rclone: telling a remote from a
path, the marker fetch, the JSON log filter, the deletion cap, and the
per-mirror marker.

## Requirements

| Tool | Purpose | Note |
|---|---|---|
| `bash` | script interpreter | 3.2 or newer; busybox is a target too |
| `rclone` | the mirror itself | found in `PATH`, or set `RCLONE_BIN` to an absolute path; 1.5x or newer for `--use-json-log` and `--metadata` |
| `awk` | rendering rclone's JSON log | gawk, mawk or busybox awk |
| `curl` | Telegram notification | only needed if Telegram is configured |
| `flock` | single-instance lock | optional — the run continues without it and says so |

Nothing is needed on a source host beyond `sshd` with sftp enabled. This is the
reason for rclone over rsync here: a source needs no rsync, and the same script
also reaches a cloud target. What that costs — ownership and symlinks over
sftp — is described above.
