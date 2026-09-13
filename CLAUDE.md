# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this directory is

**One repository, `sisyphosloughs/backup-scripts`**, holding three independent
scripts, the library they share, and the wrapper that chains them:

| Path | Role |
|---|---|
| `lib/runlib/` | shared Bash library, published as `sisyphosloughs/runlib` |
| `backup-docker-db/` | dumps Docker stack databases into a staging directory |
| `backup-tar/` | one compressed tar archive per configured path |
| `backup-restic-push/` | pushes local directories into restic repositories |
| `backup-wrapper.sh` | the cron entry point; calls the three scripts in order by absolute `/home/shanty/backup-scripts/...` paths, with no error handling between stages |
| `backup-restic-push/backup-restic-push-wrapper.sh` | **manual** runs only: re-execs itself inside tmux and prompts for `RCLONE_CONFIG_PASS`; cron does not use it |
| `telegram.conf` | bot token + chat id, `0600`, gitignored, read via `TELEGRAM_CONF` |

The three modules were separate repositories until the monorepo import; wording
that still says “this repo” in a module README means the module.

runlib is bound **once**, as the submodule `lib/runlib/`. All three scripts load
it from there (`$ROOT_DIR/lib/runlib/runlib.sh`, with
`ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"`). It used to be a separate submodule
per module as well; that allowed four diverging pointers, which would have
broken the one property the shared library exists for.

**A module directory is therefore not standalone-deployable.** It needs its
sibling `lib/`. Anything that copies a module — a throwaway test copy, a rollout
to another host — has to take `lib/` along.

## The development environment is unusual — read this first

There are **two separate git clones** of the same GitHub repository:

| Where | Path | Role |
|---|---|---|
| development machine (macOS) | this directory | editing, `shellcheck` |
| host `milos` | `/home/shanty/backup-scripts` | the live copy root's cron runs |

Editing here does **not** change the host. Changes reach `milos` through git
(push here, `git pull && git submodule update --init` there). No sync session is
set up (`mutagen.yml` is gitignored in case one is created ad hoc). Before comparing
behaviour, check that both clones are on the same commit. A fresh local clone
has an empty `lib/runlib/` until `git submodule update --init` is run, and
`shellcheck -x` cannot follow the runlib `source` without it.

**The data does not exist on the development machine.** Docker, the containers,
`/srv/backup`, restic and the real configurations live only on `milos`. Anything
you want to verify has to run there:

```bash
ssh milos '<command>'          # BatchMode key auth is set up; no passwordless sudo
```

Running the scripts in place on the host as `shanty` fails. The `logs/`
directories are `shanty`-owned, but they hold `root`-owned files from cron runs,
including the `.lock` that `acquire_lock` opens. On top of that, `prepare_*_dir`
chgrps to `nape`. The working recipe is a throwaway copy with fresh `logs/` and
the group changed to `shanty` (`BACKUP_GROUP` in `backup-tar`, `STAGING_GROUP` in
`backup-docker-db`).

The copy has to keep the collection's shape — module directory *and* `lib/`
next to each other — because the script resolves runlib as `../lib/runlib`:

```bash
ssh milos 'T=$(mktemp -d); mkdir -p "$T/x"
  cp -a /home/shanty/backup-scripts/backup-tar /home/shanty/backup-scripts/lib "$T/x/"
  rm -rf "$T/x/backup-tar/logs"; mkdir -p "$T/x/backup-tar/logs"
  sed -i "s/^BACKUP_GROUP=.*/BACKUP_GROUP=\"shanty\"/" "$T/x/backup-tar/global.conf"
  "$T/x/backup-tar/backup-tar.sh" --list; rm -rf "$T"'
```

This applies to `backup-restic-push` as well, since its `logs/.lock` is `root`-owned too.
To test uncommitted local changes, copy the module and `lib/` from here into the
temp directory (`scp -r`/`rsync`) instead of from the host clone.

## Checks

There is no build and no test framework. The checks are:

```bash
bash -n <script>
cd backup-docker-db   && shellcheck -x backup-docker-db.sh lib/db-dump-lib.sh
cd backup-tar         && shellcheck -x backup-tar.sh lib/tar-lib.sh
cd backup-restic-push && shellcheck -x backup-restic-push.sh backup-restic-push-wrapper.sh   # no lib/ of its own
cd lib/runlib         && shellcheck *.sh
shellcheck backup-wrapper.sh
```

`shellcheck -x` resolves `source` paths relative to the **current directory** —
running it from the parent produces false findings, and the `source=` directives
for runlib now point one level up (`../lib/runlib/runlib.sh`). `backup-restic-push.sh` has
2 pre-existing SC2094 infos; everything else is clean, and should stay that way.

Dry checks that touch no data and write no completion marker:

```bash
./backup-docker-db.sh --list
./backup-tar.sh --list ; ./backup-tar.sh --dry-run
./backup-restic-push.sh --list
```

To silence Telegram while testing, point `TELEGRAM_CONF` at a file holding
`xxx` values — `telegram_configured` then turns notifications off with no code
change.

## Architecture

The three scripts are a pipeline of single-purpose stages, run nightly at 01:00
by **root's crontab**, which invokes only `backup-wrapper.sh` (verified in
syslog; `shanty`'s crontab is empty and there are no systemd timers).

```
backup-docker-db  ->  /srv/backup/db-staging  ─┐
backup-tar        ->  /srv/backup/tar         ─┴─>  backup-restic-push  ->  restic repos
```

Stages communicate through the filesystem plus a **completion marker**
(`write_marker` in runlib): a temp file moved into place atomically, holding
`completed_at`, `completed_epoch`, `host`, domain-specific keys, and
`generator=` (`docker-db-dump`, `tar-backup`). Nothing in this repository reads
the marker. `backup-restic-push` sets `RUN_USES_MARKER=0` and neither reads nor
writes one. The consumers are pull-side users outside the repo (the reason for
`STAGING_GROUP`/`BACKUP_GROUP`), so treat the keys and `generator` value as an
interface, not a label.

Each script owns a **domain library** that stays out of runlib because it is not
generic: `backup-docker-db/lib/db-dump-lib.sh` (engines, container detection,
dump rotation) and `backup-tar/lib/tar-lib.sh` (compressor choice, tar call,
verification, archive rotation).

`runlib` supplies the run skeleton: `run_init`/`run_traps`/`run_worker_loop`/
`run_finish`, the one-`*.conf`-per-object loader `instances_load`, `log_*`,
`acquire_lock`, Telegram, `write_marker`, and `cmd_run`.

### Domain wording is preserved deliberately

Generic code must not flatten the vocabulary of each script. The log says
`Stack 'vaultwarden'`, `Path 'containers'`, `Instance 'db-staging'` — three
different words for the same loader. This is done through wording knobs, not
through duplicated code: `INSTANCE_LABEL` for loader messages, `RUN_WHAT` /
`RUN_UNIT` / `RUN_OK_VERB` / `RUN_ABORT_HINT` and friends for summaries and
notifications, and per-script `validate-*` callbacks that keep their own exact
error texts. Preserve this when touching runlib.

## Invariants that are easy to break

**`set -uo pipefail`, deliberately without `-e`.** Exit codes are handled
explicitly (`|| rc=$?`, `PIPESTATUS[0]`). Because of `set -u`, every array
expansion that may be empty needs the guard `"${arr[@]+"${arr[@]}"}"`.

**bash 3.2 and busybox are targets.** No `${var,,}`, no `${var@Q}`, no `{n}`
regex intervals in awk, no GNU-only `find -printf`. `printf %q` is avoided too —
its output differs between bash versions, which would make log diffs between
hosts noisy.

**Two log channels, and they must not mix.** runlib's `log_info`/`log_error`
write to stdout *and* the log file. The domain libraries bring their own bare
`log()` that writes to **stderr only**, because they return values through
stdout (`cid="$(_resolve_container …)"`). runlib deliberately defines no bare
`log()` so the two names stay apart. `cmd_run` follows the stderr rule: it
**never** writes to stdout, because callers redirect the command's stdout into a
dump file, into `/dev/null`, or into restic's `--json` pipe.

**Log file names do not follow the script names.** The prefixes are `db-dump`,
`tar-backup` and `backup`. `log_rotate` matches old files by prefix, so renaming
one orphans the existing logs. (Renaming them is a live option — it needs a
one-time rename of the old files in the same change.)

**The log file is `chmod 644` on purpose**, on the stated promise that it holds
paths, sizes and instance names — no secrets. `runlib/cmd.sh` redacts
credential-looking `NAME=VALUE` arguments and URL user info before logging. That
filter is a safety net; the real protection is that the call sites keep secrets
off the command line. Note that `-e OVR_PW=…` is visible in `ps` on the host
whenever `DB_PASSWORD` is configured — independent of logging.

**Live configuration is gitignored.** `global.conf`, `instances/*.conf`,
`repos.conf`, `repo.password` exist only on the host and have no version-control
safety net. Back them up before editing, and expect templates (`*.example`) and
live files to drift — the Docker removal cleaned the templates but left the live
files carrying dead keys until they were fixed separately.

## Changing runlib

The submodule pointer cannot resolve a commit that is not on GitHub, so:

```bash
cd lib/runlib && git commit … && git push origin main && cd ../..
git submodule update --remote lib/runlib
# then commit the moved pointer together with the code that needs the new version
```

One pointer moves all three scripts at once — that is the point of binding
runlib only here.

Deploying to a fresh host needs `git clone --recurse-submodules`, an existing
one `git submodule update --init`.

## Verification standard used here

The scripts are verified by **comparison, not by assertion**: run the old and the
new version against identical input on the host and diff the logs, expecting
only the deliberately changed lines. Byte-for-byte comparison of rendered
messages against the original `printf` statements is the accepted proof that a
refactor preserved wording. For anything touching credentials, test each
resolution path separately rather than only the happy one.
