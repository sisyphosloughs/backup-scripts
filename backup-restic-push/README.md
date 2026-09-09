# backup-restic-push

Pushes local directories into one or more restic repositories, on various hosts
(e.g. a Linux VPS or a NAS). A single script, with host-specific configuration in
separate files in the same directory. Any backend supported by restic can serve
as the target (local, SFTP, S3, REST, …); rclone is optional and only needed for
`rclone:` targets.

It backs up **what it is pointed at and nothing else**: no container is stopped,
no database is dumped here. That is deliberate — each script in this family does
one job:

| Script | Does |
|---|---|
| [backup-docker-db](https://github.com/sisyphosloughs/backup-docker-db) | dumps the databases of Docker stacks into a staging directory |
| [backup-tar](https://github.com/sisyphosloughs/backup-tar) | writes one compressed tar archive per configured path |
| **this script** | pushes directories — including the two above — into restic repositories |

So a database ends up off-site by pointing an instance at `backup-docker-db`'s
staging directory, not by teaching this script about containers.

What gets backed up is described **per object** in `instances/<name>.conf` — one
file per directory. The global switches (binaries, repository list, Telegram, …)
live in `global.conf`.

## Files

```
<location>/
├── backup-restic-push.sh             # the script (identical on all hosts)
├── backup-restic-push-wrapper.sh     # optional interactive front-end for manual runs (tmux + rclone-config password prompt)
├── global.conf                  # host-specific global config (from global.conf.example)
├── instances/                   # one *.conf per backed-up object
│   ├── instances.conf.example   # template for an instance
│   └── <name>.conf              # e.g. containers.conf, audiobooks.conf
├── repos.conf                   # host-specific repository list, optionally named (from repos.conf.example)
├── repo.password                # restic password (chmod 600, owned by root)
├── lib/
│   └── runlib/                  # shared run skeleton — git submodule, see below
└── logs/                        # one log file per run (auto-rotated), created by the script
```

The script determines its own location at runtime; all paths are derived from
`SCRIPT_DIR`. The location is freely choosable.

## Configuration model

Configuration is split in two:

- **`global.conf`** — switches that apply to the whole run: `DRY_RUN`,
  `PROGRESS_INTERVAL`, `REPOS_FILE`, `RESTIC_BIN` / `RCLONE_BIN`,
  `RCLONE_CONFIG_FILE`, `RESTIC_PASSWORD_FILE`, `TELEGRAM_CONF` and
  `LOG_RETENTION_DAYS`.
- **`instances/<name>.conf`** — one file per object (directory) to back up. The
  script collects every `*.conf` in `instances/`. The file name (without
  `.conf`) is the instance name shown in the log. Each file may set:

  | Variable | Default | Meaning |
  |---|---|---|
  | `BACKUP_PATH` | — (required) | Directory to back up. Any directory — a share, a tree of Docker stacks, or another script's staging directory. |
  | `EXCLUDES` | empty | restic exclude patterns anchored to this instance's `BACKUP_PATH` (see below). |
  | `TARGET_REPOS` | empty | Which repositories (by name from `repos.conf`) to back this instance up to (empty = **all** repos). See [Per-instance target repositories](#per-instance-target-repositories-target_repos). |

> **Why `BACKUP_PATH` and not `PATH`?** `PATH` is the shell's executable search
> path — a config file that set `PATH=…` would break command lookup for the rest
> of the run. The per-object variable is therefore `BACKUP_PATH`.

**How the instances are combined:** by default every instance goes to **every**
repository in `repos.conf`. Each repository is backed up with **one `restic
backup` call** containing exactly the `BACKUP_PATH`s of the instances that
target it — one snapshot per repo. Each instance's `EXCLUDES` are **anchored to
its own `BACKUP_PATH`** by the script, so a pattern only affects the path it was
defined for (see
[Backup paths and excludes](#backup-paths-and-excludes-backup_path--excludes)).

## Setup

1. **Clone the repository / place the files** anywhere you like.

2. **Create the global configuration** (host-specific):
   ```bash
   cp global.conf.example global.conf
   cp repos.conf.example repos.conf
   $EDITOR global.conf repos.conf
   ```

3. **Create one instance per object to back up:**
   ```bash
   cp instances/instances.conf.example instances/audiobooks.conf
   cp instances/instances.conf.example instances/containers.conf
   $EDITOR instances/audiobooks.conf instances/containers.conf
   ```
   Set `BACKUP_PATH` in each, plus `EXCLUDES` / `TARGET_REPOS` as needed. At
   least one valid instance is required, or the run aborts.

4. **Store the restic password**:
   ```bash
   sudo sh -c 'echo "YOUR-RESTIC-PASSWORD" > repo.password'
   sudo chown root:root repo.password
   sudo chmod 600 repo.password
   ```

5. **Configure rclone** (only if `rclone:` targets are used):
   ```bash
   rclone config        # create remotes, e.g. pcloud, s3, b2
   ```
   This step is not needed for local, SFTP, S3 or REST targets.

   > **Important:** The backup script runs as **root**. If `rclone config` is
   > run as a normal user, the `rclone.conf` ends up in that user's home
   > (`~/.config/rclone/rclone.conf`) and is **not readable** by root — all
   > `rclone:` targets are then treated as "not reachable" and skipped (and if
   > that leaves **no** reachable repository at all, the whole run is aborted
   > with a Telegram warning — see the workflow below).
   > Remedy: either run `rclone config` as root straight away
   > (`sudo rclone config`), **or** set `RCLONE_CONFIG_FILE` in `global.conf` to
   > the absolute path of the `rclone.conf`. The script checks this at startup
   > and writes a corresponding note to the log.

6. **Initialise the repositories** (manually, once per target):
   ```bash
   # local target
   restic --repo /mnt/backup/restic-<host> \
     --password-file ./repo.password init

   # or via rclone
   restic --repo rclone:pcloud:restic-<host> \
     --password-file ./repo.password init
   ```

   > If `rclone` is not in `PATH`, or the `rclone.conf` is not at root's
   > default location, `restic init` needs the same options the script passes
   > on every run — see [NAS systems](#nas-systems).

7. **Databases** — not this script's job. Install
   [backup-docker-db](https://github.com/sisyphosloughs/backup-docker-db) on the
   host, point it at your stacks, and add one instance here for its
   `STAGING_DIR`:

   ```bash
   # instances/db-staging.conf
   BACKUP_PATH="/srv/backup/db-staging"
   ```

   That script publishes a `.complete` marker in the staging directory once
   every stack dumped without error — useful for a monitoring check that the
   dumps this script pushes are actually fresh.

## Per-instance target repositories (`TARGET_REPOS`)

By default every instance is backed up to **all** repositories in `repos.conf`.
`TARGET_REPOS` lets an instance pick **which** repositories it goes to — useful
when, say, large media should only land in the cheap local repo while documents
go to every off-site repo.

Repositories are referenced **by name**. In `repos.conf` a line may carry an
optional name:

```text
# repos.conf
offsite = rclone:pcloud:restic-srv1        # named → referenceable as "offsite"
archive = rclone:archive-host:/srv/restic  # named → "archive"
/mnt/backup/restic-srv1                    # bare URL → name is the URL itself
```

Then in an instance:

```bash
# instances/containers.conf — only to offsite + archive
BACKUP_PATH="/opt/containers"
TARGET_REPOS=(
  "offsite"
  "archive"
)
```

- **`TARGET_REPOS` empty / omitted** → all repositories (the default).
- **Populated** → only the named repositories; each repo's snapshot then contains
  only the `BACKUP_PATH`s of the instances that target it.
- An **unknown name** is logged as an error and ignored; an instance left with
  **no valid target** is skipped (not backed up).
- A repository that **no instance targets** receives no snapshot (logged as
  "skipped"); it is also not touched by forget/prune or the monthly check.

## Backup paths and excludes (`BACKUP_PATH` / `EXCLUDES`)

Each instance contributes its `BACKUP_PATH`; the instances targeting a repository
are backed up together into it (one snapshot per repo). `EXCLUDES` holds exclude
patterns that apply **only under this instance's `BACKUP_PATH`** — patterns from
different instances do not interfere with each other.

```bash
# instances/documents.conf
BACKUP_PATH="/srv/documents"
EXCLUDES=(
  "@eaDir"          # only excludes "@eaDir" under /srv/documents
  "*.tmp"           # only excludes *.tmp under /srv/documents
  "/srv/data/cache" # leading "/" → verbatim; anchored to /srv/data/cache
)
```

**How anchoring works:** restic's `--exclude` is global per backup call, so the
script automatically prepends each relative pattern with the instance's
`BACKUP_PATH` before passing it to restic. A relative pattern `<pat>` from an
instance with `BACKUP_PATH=/srv/documents` becomes two anchored forms:

- `/srv/documents/<pat>` — matches directly in the base directory
- `/srv/documents/**/<pat>` — matches at any depth below it

A pattern that **already starts with `/`** is used verbatim — the escape hatch
for patterns that span multiple paths or that you want to anchor yourself.

The resolved backup paths and active (anchored) excludes are written to the log
at the start of the backup step.

## Program paths (`RESTIC_BIN` / `RCLONE_BIN`)

By default the script calls `restic` and `rclone` as found in `PATH`. On some
hosts the binaries live in a non-standard location that the (cron) `PATH` does
not contain. In that case set the absolute paths in `global.conf`:

```bash
# global.conf
RESTIC_BIN="/opt/bin/restic"
RCLONE_BIN="/opt/bin/rclone"
```

restic launches rclone as a subprocess. The script passes the configured path
on via restic's `-o rclone.program=$RCLONE_BIN` option, so **rclone does not
need to be in `PATH`** — a fixed path is sufficient for both the reachability
check and the actual backup.

Leave the variables empty (the default) to use whatever is found in `PATH`.
A NAS is the common case for needing them — see [NAS systems](#nas-systems).

At startup the script checks and logs the availability of all required programs:
`restic` (always), and — depending on the configuration — `rclone` (only if
`rclone:` targets exist), `curl` (only if Telegram is configured) and `jq`. A
missing `restic` aborts the run; the other tools are logged as errors/notes.
This makes a mislocated binary obvious in the log instead of surfacing as a
cryptic failure later.

## The shared library

The per-run log file, the error account that decides the exit code, the lock,
the `instances/*.conf` loader, the summary and the Telegram notification are not
implemented here. They live in
[runlib](https://github.com/sisyphosloughs/runlib) and are pulled in as a git
submodule at `lib/runlib/`, so every script of this family runs the same code
and a log line means the same thing no matter which one produced it.

What stays in this script is what is about restic: the repository list, the
per-repo grouping of instances, reachability probing, `restic backup`, the
progress filter, forget/prune and the monthly check.

A fresh clone needs `git clone --recurse-submodules`; an existing one
`git submodule update --init`. To move to a newer runlib:

```bash
git submodule update --remote lib/runlib
git add lib/runlib && git commit -m "runlib: update"
```

## Running

The script must run with root privileges so that every file under the
configured paths is readable:

```bash
sudo ./backup-restic-push.sh
```

| Option | Meaning |
|---|---|
| `-i`, `--instance NAME` | Back up only this instance (repeatable). |
| `-l`, `--list` | List the configured instances with their target repos, then exit. Writes nothing. |
| `-h`, `--help` | Show the usage summary. |

Exit code: `0` on success, `1` on one or more errors.

## What the notification says

```
✅ [srv1] restic push completed
Duration: 0m39s
Repositories: 2/2 successful
Paths: /srv/backup/db-staging /opt/containers /srv/documents
Data: 358.7 MB processed, 142.7 MB added

  - offsite: ok — 142.7 MB added, snapshot e1961750 in 0m22s
  - archive: ok — 142.0 MB added, snapshot 9bd55b71 in 0m09s
```

Two of those lines carry information the counts alone do not:

- **`Paths:`** names the directories the run actually covered. An instance whose
  `BACKUP_PATH` no longer exists is skipped, and the run still reports success —
  only this line shows that the scope has shrunk.
- **`Data:` reports two numbers.** restic reads the whole tree on every run but
  writes only the deduplicated difference. "Processed" stays roughly constant
  and confirms the source was read; "added" is what actually reached the
  repositories, summed over all of them.

A repository that could not be reached is listed too (`SKIPPED (not
reachable)`), so the `2/3` in the count is never a riddle.

## Manual runs (`backup-restic-push-wrapper.sh`)

`backup-restic-push-wrapper.sh` is a thin, **interactive** front-end for backing up by
hand — the counterpart to the unattended `cron` run of `backup-restic-push.sh`. It
changes nothing about the backup itself; it only wraps the script in two
conveniences for kicking off a manual sync over SSH:

- **Runs inside `tmux`** so a long run survives a dropped SSH connection. On first
  invocation the wrapper re-executes itself inside a tmux session named
  `restic-backup` (`tmux new-session -A`, so an existing session is re-attached
  rather than duplicated). Detach at any time with the usual tmux keys
  (`Ctrl-b d`) and reattach later with `tmux attach -t restic-backup`; the backup
  keeps running in between.
- **Prompts for the rclone-config password.** The `rclone.conf` is
  **password-encrypted** (`rclone config` → *Set configuration password*), so the
  password is stored nowhere on disk. The wrapper reads it once (hidden input) and
  exports it as `RCLONE_CONFIG_PASS`; restic passes its environment on to rclone,
  which uses it to decrypt the config for the run. A trap unsets the variable
  again on exit.

At the end it prints the exit code and waits for Enter, so the result stays on
screen instead of the tmux window closing immediately.

Run it as **root**, exactly like the script it wraps:

```bash
sudo ./backup-restic-push-wrapper.sh
```

> **Requires `tmux`** in `PATH`. This path is for interactive use only — the
> unattended `cron` run calls `backup-restic-push.sh` directly (see [Cron](#cron)), so
> an encrypted `rclone.conf` is either used only for these manual runs, or
> `RCLONE_CONFIG_PASS` must be supplied to cron by other means.

## Dry run (`DRY_RUN`)

Set `DRY_RUN=true` in `global.conf` to do a trial run without writing anything.
restic then runs the backup with `--dry-run --verbose=2`, so a per-file listing
of what *would* be backed up (including which files your excludes skip) is
written to the log. No snapshot is created, and the repository-modifying
steps — `forget`/`prune` and the monthly `check` — are skipped. Handy for
verifying `BACKUP_PATH` / `EXCLUDES` before a real run:

```bash
# global.conf
DRY_RUN=true
```

The log and the Telegram message are marked with `[DRY RUN]`. Set it back to
`false` (the default) for normal operation.

## Progress (`PROGRESS_INTERVAL`)

A real (non-dry) backup is deliberately quiet — it does not list files. So that a
long run (typically the first, initial one) visibly does *something*, restic is
run with `--json` and the status stream is throttled to one compact progress line
per `PROGRESS_INTERVAL` seconds (default 30), printed to terminal and log:

```text
offsite:  42%  1.4 GB/3.4 GB  8123/19004 files  elapsed 2m00s  ETA 2m45s
```

This is a coarse overall estimate (on a large data set, files may change while the
backup is running — that is accepted). Set `PROGRESS_INTERVAL=0` to disable the
lines. When the backup finishes, each repo also logs a one-line summary of what
changed and how much *new* (deduplicated) data was written:

```text
offsite: backup successful (3.4 GB, snapshot a1b2c3d4)
offsite: files 12 new, 3 changed, 18989 unmodified; 45.2 MB added
```

`data_added` ("… added") is the new data actually written to the repo. Thanks to
deduplication it stays small even when many files are reported as "new" — e.g.
after the set of backup paths changes and restic finds no parent snapshot and so
re-reads everything.

## Workflow

1. Initialisation, open log file, load `global.conf`, collect `instances/*.conf`,
   check program availability, delete old logs
2. Check repository reachability up front. An unreachable (or not-yet-initialised)
   repo is **skipped** (logged as an error, so it shows up in the notification);
   the remaining repos are still backed up. Only if **no** repo is reachable is
   the run aborted here with a Telegram warning (nothing is backed up). The
   reachable repos are then unlocked.
3. For each reachable repository, back up the `BACKUP_PATH`s of the instances
   that target it (with their anchored excludes) — one snapshot per repo. A repo
   that no instance targets is skipped.
4. `restic forget --prune` (keep-daily 31, keep-monthly 99)
5. `restic check` — monthly only (on the 1st)
6. Summary to the log + Telegram notification

Containers keep running throughout — nothing is stopped and no database is
dumped. Both belong to the scripts named at the top.

With `DRY_RUN=true`, step 3 runs as `restic backup --dry-run --verbose=2`
(nothing written, per-file output to the log) and steps 4/5 are skipped.

If the script is aborted unexpectedly (`INT`/`TERM`/error), a trap handler sends
a Telegram warning.

## Logging

One file `logs/backup-<timestamp>.log` per run. Output also goes to stdout at
the same time. Files older than `LOG_RETENTION_DAYS` (default 64) days are
deleted at the start of each run — no logrotate needed. Log files are created
world-readable (`0644`) so the normal user can read/sync them even though the
script runs as root; they contain paths and snapshot IDs but no secrets.

## Cron

The script must run as **root**. Edit the root user's crontab:

```bash
sudo crontab -e
```

Daily backup at 03:00:

```cron
# m h dom mon dow  command
0 3 * * * /path/to/location/backup-restic-push.sh
```

`restic`/`rclone` are often located under `/usr/local/bin`, which may be missing
from the cron environment. To be safe, set `PATH`:

```cron
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Daily backup at 03:00
0 3 * * * /path/to/location/backup-restic-push.sh
```

Alternatively (or for binaries in non-standard locations), set `RESTIC_BIN` /
`RCLONE_BIN` to absolute paths in `global.conf` — see [Program paths](#program-paths-restic_bin--rclone_bin). The
startup program check then confirms in the log that the binaries were found.

The script writes its own log file to `logs/` per run and reports the result via
Telegram — an additional cron redirect is not needed. If you still want to
capture the cron output (e.g. the script's startup error):

```cron
0 3 * * * /path/to/location/backup-restic-push.sh >> /path/to/location/logs/cron.log 2>&1
```

## NAS systems

NAS firmware (Synology DSM, QNAP QTS and comparable systems) differs from a
plain Linux host in four ways that concern this script. The paths below follow
Synology's layout; adjust them for other systems.

**Task scheduler instead of crontab.** Most NAS systems ship a GUI task
scheduler and advise against editing the crontab directly. Set the task up
there as the user `root`, with the absolute path to the script as the command:

```bash
/path/to/location/backup-restic-push.sh
```

Telegram delivers the result; the full log is in `logs/`.

**Binaries outside `PATH`.** `restic` and `rclone` are often installed into a
package-manager prefix such as `/volume1/opt/bin`, which the scheduler's `PATH`
does not contain. Set the absolute paths in `global.conf` — see
[Program paths](#program-paths-restic_bin--rclone_bin):

```bash
# global.conf
RESTIC_BIN="/volume1/opt/bin/restic"
RCLONE_BIN="/volume1/opt/bin/rclone"
```

**`restic init` needs the same options.** If `rclone` is not in `PATH` and the
`rclone.conf` is not at root's default location, the one-time `restic init`
must be told what the script tells restic on every run. Otherwise it fails with
`Config file ... not found` or `directory not found`. Mirror `RCLONE_BIN` and
`RCLONE_CONFIG_FILE` from `global.conf`:

```bash
restic \
  -o rclone.program=/volume1/opt/bin/rclone \
  -o "rclone.args=serve restic --stdio --b2-hard-delete --config /volume1/homes/USER/rclone.conf" \
  --repo rclone:pcloud:/Backup/restic-<host> \
  --password-file ./repo.password init
```

**Filesystem metadata inside shares.** DSM keeps `@eaDir`, `#recycle` and
`#snapshot` directories in its shares; QTS uses `@Recycle`. Exclude them in the
instance that backs the share up:

```bash
# instances/<share>.conf
EXCLUDES=(
  "@eaDir"
  "#recycle"
  "#snapshot"
)
```

## Not included in the script (manual)

- Repository initialisation (`restic init`)
- rclone configuration (`rclone config`) — only for `rclone:` targets
- restic updates (`restic self-update`)
- Cron setup


## Telegram credentials

The token and chat id live in **one file for the whole host**, not once per
script, so rotating them is a single edit. Point `TELEGRAM_CONF` in
`global.conf` at it:

```bash
# global.conf
TELEGRAM_CONF="/etc/runlib/telegram.conf"
```

```bash
# /etc/runlib/telegram.conf   —   chmod 600, outside every repository
TELEGRAM_BOT_TOKEN="123456:AA..."
TELEGRAM_CHAT_ID="987654"
```

`TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` set directly in `global.conf` still
take precedence, so a single host can override the shared file. Leaving both unset
(or at `"xxx"`) disables notifications. A `TELEGRAM_CONF` that is set but
unreadable is reported as an error rather than silently swallowed — a backup
that has quietly stopped reporting is the failure this notification exists to
prevent.

## Requirements

The following must be available on the host:

| Tool | Purpose | Note |
|---|---|---|
| `bash` | script interpreter | works even with old Bash 3.2 |
| `restic` | backup, forget/prune, check | found in `PATH`, or set `RESTIC_BIN` to an absolute path |
| `rclone` | only for `rclone:` targets | **optional** — not needed for local/SFTP/S3/REST targets; set up remotes beforehand via `rclone config`. Found in `PATH`, or set `RCLONE_BIN` to an absolute path (no `PATH` entry needed then) |
| `curl` | Telegram notification | only needed if Telegram is configured |
| `jq` | parse restic's JSON output | **optional** — without `jq` a `grep` fallback is used |
| `tmux` | keep a manual run alive over SSH | **optional** — only for `backup-restic-push-wrapper.sh` (manual runs); not needed for cron |
