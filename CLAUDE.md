# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this directory is

**Not one repository — four independent ones**, plus two files that belong to no repo:

| Path | Role |
|---|---|
| `runlib/` | shared Bash library, published as `sisyphosloughs/runlib` |
| `backup-docker-db/` | dumps Docker stack databases into a staging directory |
| `backup-tar/` | one compressed tar archive per configured path |
| `backup-restic-push/` | pushes local directories into restic repositories |
| `backup-wrapper.sh` | the cron entry point; calls the three scripts in order |
| `telegram.conf` | bot token + chat id, `0600`, referenced by `TELEGRAM_CONF` |

`runlib/` is also vendored into each of the three script repos as the git
submodule `lib/runlib/`. The clone at the top level is where it is *developed*.

## The development environment is unusual — read this first

This directory is an **SFTP/NFS mount of the remote host `milos`**
(`/home/shanty/scripts`). Editing here edits the live host.

**The data does not exist on the development machine.** Docker, the containers,
`/srv/backup`, restic and the real configurations live only on `milos`. Anything
you want to verify has to run there:

```bash
ssh milos '<command>'          # BatchMode key auth is set up
```

Running the scripts straight from the mount fails on paths that do not exist
locally. Running them on the host as `shanty` fails too: `logs/` in
`backup-docker-db` and `backup-tar` is owned by `root` (cron runs as root), and
`prepare_*_dir` chgrps to `nape`. The working recipe is a throwaway copy:

```bash
ssh milos 'T=$(mktemp -d); cp -a /home/shanty/backup-scripts/backup-tar "$T/x"
  rm -rf "$T/x/logs"; mkdir -p "$T/x/logs"
  sed -i "s/^BACKUP_GROUP=.*/BACKUP_GROUP=\"shanty\"/" "$T/x/global.conf"
  "$T/x/backup-tar.sh" --list; rm -rf "$T"'
```

`backup-restic-push`'s `logs/` is `shanty`-owned, so it runs in place.

## Checks

There is no build and no test framework. The checks are:

```bash
bash -n <script>
cd <repo> && shellcheck -x <script> lib/*.sh    # MUST be run from the repo dir
```

`shellcheck -x` resolves `source` paths relative to the **current directory** —
running it from the parent produces false findings. `backup-restic-push.sh` has
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
`generator=`. The `generator` value is read by consumers — treat it as an
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
cd runlib && git commit … && git push origin main
cd ../<repo> && git submodule update --remote lib/runlib
# then commit lib/runlib together with the code that needs the new version
```

Deploying to a fresh host needs `git clone --recurse-submodules`, an existing
one `git submodule update --init`.

## Verification standard used here

The repos are verified by **comparison, not by assertion**: run the old and the
new version against identical input on the host and diff the logs, expecting
only the deliberately changed lines. Byte-for-byte comparison of rendered
messages against the original `printf` statements is the accepted proof that a
refactor preserved wording. For anything touching credentials, test each
resolution path separately rather than only the happy one.
