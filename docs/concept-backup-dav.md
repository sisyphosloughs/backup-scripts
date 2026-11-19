# Concept: `backup-dav` — calendars, tasks and contacts from Nextcloud

Status: **draft, not implemented.** This document is the brief for building a
new module in this repository. It records the decisions taken so far, the
shape the code has to have to fit the existing modules, and what is still open
(section 13). Where it says "verify", the assumption has not been tested yet
and the first implementation step has to check it.

## 1. Goal and constraints

Back up the calendars, tasks (`VTODO`, stored in calendars) and address books
on a **Hetzner Storage Share** (managed Nextcloud), keep a **warm standby** of
that data on ikaria that clients can use in an emergency, and **prove
regularly** that the backup can be restored.

**Scope at the start: one account, `bbruecker`.** More accounts may follow
later and are added by hand: one `instances/<account>.conf`, one netrc, one
Baïkal principal. The design is "one `*.conf` per account" from the start, so
adding an account needs no code change.

Given by the platform:

- No shell, no database, no scriptable `occ` on Storage Share. Hetzner offers
  a fixed list of occ commands in its konsoleH web interface, run by hand; any
  other command needs a support ticket. Nothing there can be scheduled.
- What remains is HTTP: CalDAV/CardDAV under `/remote.php/dav`.
- Admin rights give **no** access to other accounts' DAV data. Every account
  is read with **its own app password**, created by its owner under
  Personal settings → Security. This matters only once there are more
  accounts.
- Hetzner's own snapshots restore only the whole instance (and the instance is
  offline while that runs). They are not a way to get one calendar back.

Given by the repository (see `CLAUDE.md`): bash with `set -uo pipefail` and no
`-e`; bash 3.2 and busybox as targets; runlib's run skeleton; one `*.conf` per
object; two log channels; secrets never on the command line; completion
markers as an interface; verification by comparison.

## 2. Overview

```
Storage Share (Nextcloud)                        ikaria
───────────────────────────                      ─────────────────────────────────────────────
CalDAV/CardDAV  ──── ?export, per account ────▶  backup-dav.sh            (producer, nightly)
                                                     └▶ /volume1/backup/staging/nextcloud-dav/<account>/
                                                         *.ics *.vcf manifest.tsv .complete
                                                           │                         │
                                                           │                         └▶ backup-restic (existing; staging is already a BACKUP_PATH)
                                                           ▼
                                                 backup-dav-standby.sh    (consumer, nightly)
                                                     └▶ Baïkal 0.13.0 at /volume1/baikal/, port 9976, LAN only
                                                        principal per account = warm standby
                                                 backup-dav-standby.sh --restore-test   (monthly)
                                                     └▶ restic restore → principal "restore-test" → compare
```

## 3. Module layout

**One module, two entry scripts.** Both scripts work on the same accounts, so
the accounts are configured once. That keeps them from drifting apart, and
putting both in one directory gives them a shared `logs/.lock`: an export and
a standby sync never run at the same time.

```
backup-dav/
  README.md
  backup-dav.sh                  export: Nextcloud → staging (producer, marker)
  backup-dav-standby.sh          staging → Baïkal (consumer); --restore-test, --self-test
  global.conf.example
  instances/instances.conf.example
  lib/dav-lib.sh                 domain library (see 6)
  baikal/
    Dockerfile                   own Baïkal 0.13.0 image (see 8.1)
    compose.example.yml          Baïkal deployment template (see 8.1)
    README.md                    setup, LAN restriction, port checks (8.4), emergency runbook (9)
  tests/
    run-tests.sh                 offline tests, no framework (see 10)
    fixtures/  expected/
    integration.sh               against the live Baïkal, principal "selftest"
```

`tests/`, not `test/`: the root `.gitignore` ignores `test/`.

The module directory belongs on `main` and has no host-specific content. The
paths on ikaria (`/volume1/...`, LAN IP, port) appear only as examples in the
templates and for real in the live `*.conf` files and `compose.yml`.

### Wording knobs and interface names

| | `backup-dav.sh` | `backup-dav-standby.sh` |
|---|---|---|
| log prefix (`run_init`) | `dav-export` | `dav-standby` |
| `INSTANCE_LABEL` / `_LC` | `Account` / `account` | `Account` / `account` |
| `RUN_WHAT` | `DAV export` | `DAV standby` / `DAV restore test` |
| `RUN_UNIT` | `Accounts` | `Accounts` |
| `RUN_OK_VERB` | `export successful` | `standby in sync` / `restore verified` |
| `RUN_USES_MARKER` | 1 | 0 |
| marker `generator=` | `dav-export` | — |

The log prefix and the generator value are fixed once released (`log_rotate`
matches by prefix; markers are an interface). Log lines are in English like the
rest of the collection: `Account 'bbruecker': calendar 'personal' — 412 objects
(398 VEVENT, 14 VTODO)`.

## 4. Configuration

### `global.conf`

```bash
TELEGRAM_CONF="/volume1/scripts/backup-scripts/telegram.conf"
CURL_BIN="curl"                 # /usr/bin/curl on ikaria

STAGING_BASE="/volume1/backup/staging/nextcloud-dav"
STAGING_MODE="0750"; STAGING_GROUP=""; STAGING_UMASK="0027"
MARKER_NAME=".complete"

CURL_CONNECT_TIMEOUT=20         # seconds
CURL_MAX_TIME=600               # per request; a large address book with photos is slow
MAX_SHRINK_PERCENT=20           # trend guard default (see 5.4)

# Standby (see 8.1). The scripts use the IP, not a name, so they do not depend
# on the Fritz!Box's DNS. Plain HTTP, LAN only.
BAIKAL_URL="http://192.168.223.2:9976/dav.php"
BAIKAL_AUTH="digest"            # Baïkal's default; see 8.1
MARKER_MAX_AGE_HOURS=26         # staging marker must be fresher than this
MAX_DELETE=50                   # per collection and run
STANDBY_FREEZE_FILE="/volume1/baikal/FROZEN"   # see 9

# Restore test
RESTIC_BIN="/usr/local/bin/restic"
RESTIC_REPOSITORY=""            # the repository backup-restic writes the staging into
RESTIC_PASSWORD_FILE=""
RESTORE_TEST_PRINCIPAL="restore-test"
SELFTEST_PRINCIPAL="selftest"

LOG_RETENTION_DAYS=64
```

The scripts take host and port **only from `BAIKAL_URL`** and hard-code
them nowhere.

### `instances/<account>.conf` — one per Nextcloud account

At the start there is exactly one file, `instances/bbruecker.conf`:

```bash
DAV_URL="https://<instance>.your-storageshare.de/remote.php/dav"
DAV_USER="bbruecker"            # default: the file name
NETRC_FILE="/volume1/scripts/backup-scripts/backup-dav/secrets/bbruecker.netrc"
INCLUDE_SHARED=false            # collections shared TO this account (…_shared_by_…)
EXCLUDE_COLLECTIONS=()          # glob patterns on the collection URI
MAX_SHRINK_PERCENT=20           # overrides the global default
ACCEPT_SHRINK=false             # one-off override after a deliberate cleanup
STANDBY=true                    # mirror this account into Baïkal
STANDBY_USER="bbruecker"        # Baïkal principal; default DAV_USER
```

### Secrets

One netrc file per account, mode `0600`, owner root. It holds **two** `machine`
lines: one for the Storage Share host with the Nextcloud app password and one
for the Baïkal host with the Baïkal password of that principal. curl picks the
line by host name, so one file covers both scripts. The Baïkal line must use
the host part of `BAIKAL_URL` exactly, which is the IP.

```
machine <instance>.your-storageshare.de login bbruecker password <nextcloud-app-password>
machine 192.168.223.2 login bbruecker password <baikal-password>
```

Every request uses `curl --netrc-file "$NETRC_FILE"`, never `-u user:pass`: a
password in an argument shows up in `ps` and would depend on `cmd_run`'s
redaction. To add to the repository:

- `.gitignore`: `*.netrc` and `secrets/`
- `mutagen.example.yml`: the same patterns in the ignore list
- `validate_account`: refuse a netrc that is not a regular file or is readable
  by group or others (the same strictness ssh applies to keys)

## 5. `backup-dav.sh` — the export

### 5.1 Command line

Like `backup-rclone-sync`: `-i/--instance NAME` (repeatable), `-l/--list`
(accounts from the configuration, no network), `-n/--dry-run` (discover and
count on the server, download nothing, write no marker), `-h/--help`.

### 5.2 Per account (worker, in a subshell)

1. **Discover.** Send `PROPFIND Depth: 1` to `calendars/<user>/` and
   `addressbooks/users/<user>/`, asking for `resourcetype`, `displayname`,
   `getctag` and `supported-calendar-component-set`. Skip:
   - the account root itself, the `inbox`, `outbox` and `trashbin`;
   - subscriptions (`resourcetype` contains `calendarserver:subscribed`);
   - the generated birthday calendar `contact_birthdays`;
   - Deck calendars (`app-generated--deck--board-*`);
   - shared-in collections (`…_shared_by_…`) unless `INCLUDE_SHARED=true`;
   - anything matching `EXCLUDE_COLLECTIONS`.

   Each skip is logged with its reason, so the scope of the backup is visible
   in the log.
2. **Count on the server.** Send `PROPFIND Depth: 1` with only `getetag` to
   each collection. The result, the number of `response` elements minus one,
   is `server_count`.
3. **Download.** Request `GET <collection>/?export` into
   `<account>.new/calendars/<uri>.ics` or `addressbooks/<uri>.vcf`. Use curl
   with `--fail` and `-w '%{http_code} %{content_type}'`; anything other than
   `200` with `text/calendar` or `text/vcard` counts as a failure.
4. **Check** (5.3). The result goes into `manifest.tsv`.
5. **Swap.** Only if every collection passed, rename `<account>` →
   `<account>.old`, `<account>.new` → `<account>`, then delete `.old`. If
   anything failed, delete `.new`, so the previous export and its marker stay
   in place.
6. **Marker.** Done at run level after the worker loop, for every account in
   `OK_INSTANCES`, exactly like section 10 of `backup-rclone-sync.sh`.

**Stop an account on HTTP 401 or 403 at once**, without retrying and without
moving on to its other collections. Nextcloud throttles failed logins per
source IP. One wrong app password, retried, would slow down or lock out every
account requested from ikaria.

### 5.3 Checks during the export

| Check | Fails when |
|---|---|
| Transport | the HTTP status is not 200, the content type is wrong, or the body is empty |
| Structure | the file does not start with `BEGIN:VCALENDAR` / `BEGIN:VCARD` or end with the matching `END:`; or `BEGIN:`/`END:` are unbalanced (checked after removing CR and unfolding lines) |
| Completeness | calendars: number of distinct UIDs of `VEVENT`/`VTODO` ≠ `server_count`; address books: number of `VCARD` ≠ `server_count` |
| Trend (5.4) | the object count dropped by more than `MAX_SHRINK_PERCENT` since the previous manifest |

UIDs are counted, not components: an exception of a recurring event is a
second `VEVENT` with the same UID in the same object. A UID inside a `VALARM`
(RFC 9074) is nested one level deeper and is not counted.

### 5.4 Trend guard

This guard is the analogue of `MAX_DELETE` in `backup-rclone-sync`. It
compares each collection with the same collection in the previous
`manifest.tsv`. When the new count is too small, the account fails, the
previous export stays, and the log names the collection and both counts. A
collection that disappeared completely is reported the same way.

`ACCEPT_SHRINK=true` in the account's conf lets one deliberate cleanup through
and has to be removed again afterwards. A warning in every run while it is set
keeps it from being forgotten.

### 5.5 Staging layout (interface)

```
$STAGING_BASE/<account>/
  .complete                 generator=dav-export, account=, server=,
                            collections=, objects=, vevents=, vtodos=, cards=, bytes=
  manifest.tsv              one line per collection, tab-separated:
                            kind  uri  displayname  server_count  objects  vevents  vtodos  cards  bytes
  calendars/<uri>.ics
  addressbooks/<uri>.vcf
```

`manifest.tsv` and the marker keys are an interface in the same sense as the
existing markers. The standby, the restore test and the trend guard read them.

## 6. `lib/dav-lib.sh` — domain library

Its own bare `log()` writes to stderr only, and functions return values on
stdout, the same convention as the other domain libraries. Only `awk`, `tr`,
`grep` and `sed` are used, in a bash 3.2- and busybox-compatible way. Nothing
needs `python3` or `jq`, even though ikaria has both.

| Function | Purpose |
|---|---|
| `dav_propfind <url> <netrc> <depth> <body>` | one PROPFIND → multistatus on stdout |
| `ms_responses` / `ms_prop <name>` | minimal multistatus parsing: one line per response with href and the requested properties; tolerant of the namespace prefix (`d:`, `D:`, none) |
| `dav_count <url> <netrc>` | number of objects in a collection |
| `ics_unfold` | remove CR, join folded lines |
| `ics_stats <file>` | `bad vevents vtodos uids` |
| `vcf_stats <file>` | `bad cards` |
| `ics_split <file> <outdir>` | one VCALENDAR per UID, carrying the `VTIMEZONE` blocks its `TZID`s reference; the file name is `uid_name` |
| `vcf_split <file> <outdir>` | one VCARD per file |
| `uid_name <uid>` | a stable, path-safe file name for a UID. Hash it rather than escape it, because UIDs contain `/`, `@` and the like. The md5/sha tool differs between DSM, busybox and macOS, so this needs a small helper that tries `md5sum` and then `md5 -q` |
| `manifest_read` / `manifest_compare` | trend guard |
| `curl_rc_text <rc>` | curl exit code in words, like `rclone_rc_text` |

Splitting happens when the standby imports, not in staging. Staging keeps the
server's export unchanged; that keeps the backup a plain copy of what the
server delivered.

## 7. `backup-dav-standby.sh` — the warm standby

### 7.1 Nightly sync (default action)

For each account with `STANDBY=true`:

1. **Preconditions.**
   - `STANDBY_FREEZE_FILE` must not exist (see 9).
   - The staging marker must be present and younger than
     `MARKER_MAX_AGE_HOURS`. If the Nextcloud export failed, the standby is
     left unchanged; this is the same rule `SOURCE_MARKER` enforces in
     `backup-rclone-sync`.
   - Baïkal must answer under `BAIKAL_URL` (host and port only from there):
     `PROPFIND` on the principal returns 207, and 401 without credentials.

   If one of these fails, the account fails and nothing is written.
2. **Collections.**
   - A collection in `manifest.tsv` that is missing in Baïkal is created with
     `MKCALENDAR` or an extended `MKCOL` (`resourcetype` addressbook), with
     its display name.
   - A collection in Baïkal that is no longer in the manifest is **never
     deleted automatically**, only reported. Deleting a whole calendar is
     rare, and done by mistake it is expensive.
3. **Objects.** Split the export (`ics_split`/`vcf_split`) into a temp dir,
   then `PROPFIND` the Baïkal collection for href and etag.
   - New or changed objects get a `PUT`.
   - Objects that are gone from the export get a `DELETE`.
   - "Changed" means the etag differs from the md5 of the object. sabre's PDO
     backend uses md5 of the stored data as etag. Verify that Baïkal keeps
     the data byte for byte; if not, always `PUT` and accept the extra
     traffic.
   - The deletions are guarded by `MAX_DELETE` per collection: above that,
     the collection fails before anything is deleted.
4. **Check.** Afterwards the object count per Baïkal collection must equal
   `objects` from the manifest. Every `PUT` that does not get 201 or 204 is
   logged with its UID, its collection and the server's error text (decided,
   13).

### 7.2 `--restore-test` (monthly, DSM Task Scheduler)

This proves that the **restic backup**, not the staging copy, can be restored
into a standards-compliant server.

1. `restic restore latest --include "$STAGING_BASE" --target <tmp>` with
   `RESTIC_REPOSITORY` and `RESTIC_PASSWORD_FILE`. Neither the repository nor
   the password goes on the command line; restic reads both from the
   environment or the file.
2. Delete all collections of the principal `RESTORE_TEST_PRINCIPAL`, then
   recreate them per account and collection as `<account>--<uri>`.
3. Import with the same code as 7.1, but from the restored tree, with no
   deletion guard (the target is empty).
4. Compare the counts per collection with the **restored** `manifest.tsv`.
   Also report the marker's `completed_at`, so the log and the notification
   state the date of the state that was verified. The result is reported only
   through the log and Telegram; no marker is written (decided, 13).
5. Delete the temp tree. The test principal keeps its data until the next
   test, so you can still look at the state afterwards.

This touches neither the standby principals nor the staging.

### 7.3 `--self-test`

This runs `tests/integration.sh` (10.2) against the live Baïkal. It runs at the
start of every `--restore-test` and by hand **after every image rebuild**
(8.1). It is cheap and separates "Baïkal is broken" from "the backup is
broken".

## 8. Baïkal on ikaria

### 8.1 Deployment under `/volume1/baikal/`

- **Folder.** Create `baikal` as a **DSM shared folder**, not just a `mkdir`,
  so it gets DSM permissions and shows up in DSM's own tools.
  `/volume1/baikal` does not exist yet.
- **Layout.**
  ```
  /volume1/baikal/
    compose.yml          live copy of backup-dav/baikal/compose.example.yml
    Dockerfile           copy of backup-dav/baikal/Dockerfile (or build: pointing at the module)
    config/              → /var/www/baikal/config    (baikal.yaml)
    Specific/            → /var/www/baikal/Specific  (db/db.sqlite)
    FROZEN               only in an emergency (see 9)
  ```
  The volume paths follow the layout of the Baïkal release zip; verify them
  for 0.13.0.

#### Image: our own build of Baïkal 0.13.0

Baïkal **0.13.0** is the current release (2026-10-19; it ships sabre/dav
4.7.1). The usual image `ckulka/baikal` has **no 0.13 tag**: its newest
version tag is `0.10.1` with PHP 8.1/8.2, and a pull request for 0.13.0 on
PHP 8.4 (ckulka/baikal-docker #334) is open and unmerged, with no image
published. On top of that, an issue about a critical PHP vulnerability (#331)
is open there. Pinning to 0.13 with ckulka is not possible, so we build our
own image (checked 2026-11-19).

`backup-dav/baikal/Dockerfile`:

- Base `php:8.4-apache`, the official image, pinned to the minor tag. Never
  `latest`.
- The official release zip
  `https://github.com/sabre-io/Baikal/releases/download/0.13.0/baikal-0.13.0.zip`,
  checked against a sha256 fixed in the Dockerfile (`sha256sum -c`); a
  different file fails the build.
- Apache `DocumentRoot /var/www/baikal/html`, `mod_rewrite` on, owner
  `www-data`.
- Verify: Baïkal's PHP requirements for 0.13.0 and whether `pdo_sqlite` is
  present (in the official PHP images it is by default).
- compose: `build: .` and `image: local/baikal:0.13.0-php8.4`.

**PHP security updates are now our own job.** The image is rebuilt monthly
with `docker compose build --pull && docker compose up -d`, as part of the
restore-test cycle: restore test, rebuild, `--self-test` (7.3). On a critical
PHP CVE it is rebuilt straight away. A Baïkal update means a new version and
checksum in the Dockerfile; read the release notes first (0.13.0, for
instance, asks for a backup before upgrading from older SQLite installs). If
ckulka publishes a 0.13 image later (#334), switching back to an external
image is an option.

#### Network: LAN only, port 9976, plain HTTP

The address `192.168.223.2` is fixed (DHCP reservation or static). In the
LAN, the host is reachable as `ikaria`, `ikaria.fritz.box` and
`192.168.223.2`; all three point at the same address, so the binding below
covers all of them. Clients should use `ikaria.fritz.box`, because the bare
name `ikaria` depends on the client's DNS search domain. The scripts use the
IP, so they keep working even when the Fritz!Box DNS does not.

- compose publishes `"192.168.223.2:9976:80"`, bound to the LAN address, not
  `0.0.0.0`.
- A DSM firewall rule allows TCP 9976 only from `192.168.223.0/24`.
- No router port forwarding, no QuickConnect, no reverse proxy rule.
- Run the port checks (8.4).
- **No TLS** (decided, 13). Baïkal is spoken to over plain HTTP, and only
  within the LAN. The consequence: anyone in the LAN can read the transferred
  calendar and contact data. DAVx⁵ accepts HTTP; macOS and iOS warn when
  setting up the account.
- **Auth.** Digest (Baïkal's default). Without TLS it is what keeps the
  password off the wire; Basic would send it readable in every request.
- **No outgoing mail.** Baïkal sends invitations (iMIP) when an imported
  event has `ATTENDEE`/`ORGANIZER` and a sender address is configured. So:
  leave "invite from" empty and configure no SMTP. Otherwise every import
  mails real attendees.
- **Setup wizard.** Baïkal's first start asks in the browser for an admin
  password, the database (SQLite), auth type (Digest) and time zone. This is
  done once, by hand.
- **Principals.** Baïkal has no API for creating users, so they are created in
  its admin UI, by hand: at the start `bbruecker`, `restore-test` and
  `selftest`; later one more per added account (same name as the Nextcloud
  account). The standby script checks that the principal exists and reports
  clearly if it does not.

### 8.2 Backing up Baïkal itself

In normal operation the standby is a derived copy, but in an emergency it
becomes the primary. So `/volume1/baikal` gets its own `backup-restic`
instance (`BACKUP_PATH="/volume1/baikal"`).

SQLite consistency: the nightly writes come from the standby sync, which runs
before restic (11), so the file is at rest during the snapshot. In an
emergency, when clients write, a `sqlite3 .backup` before the snapshot would
be cleaner. The own image can include the `sqlite3` client for that; decide
when building it.

### 8.3 Health

The standby script checks Baïkal on every run (7.1, step 1). There is no
separate monitoring, because an error already reaches Telegram through
runlib.

### 8.4 Port checks (content of `baikal/README.md`)

The README carries these checks as a checklist. Each command says what it
should show; if it shows something else, Baïkal is not exposed the way it is
meant to be, and it must not be used until that is fixed.

Run the checks **before the first start, after the first start, and again
after every Baïkal or DSM update, image rebuild and router change.**

**a) Before setup: is the port free?** On ikaria, as root, because without
sudo `docker ps` and `netstat -p` do not show everything:

```bash
sudo netstat -tlnp | grep ':9976 '                                 # expect: no output
sudo /usr/local/bin/docker ps --format '{{.Names}} {{.Ports}}' \
  | grep 9976                                                      # expect: no output
```

Also check in DSM that no reverse proxy rule (Login Portal → Advanced →
Reverse Proxy) and no package uses 9976. A read-only check on 2026-11-19
found nothing listening on 9976.

**b) After starting: is the binding right?**

```bash
sudo netstat -tln | grep ':9976 '          # expect: 192.168.223.2:9976
sudo /usr/local/bin/docker port baikal     # expect: 80/tcp -> 192.168.223.2:9976
```

If it shows `0.0.0.0:9976` or `:::9976`, the IP is missing from the port
mapping in `compose.yml`.

**c) Reachable from the LAN, under all three names?** From the Mac:

```bash
# expect "HTTP/1.1 401" three times
for h in ikaria ikaria.fritz.box 192.168.223.2; do
  printf '%s: ' "$h"; curl -sI --max-time 5 "http://$h:9976/dav.php" | head -n1
done
```

A timeout means the firewall rule or the binding is wrong. If only `ikaria`
fails, the client is missing the `fritz.box` search domain; that is a client
setting, not a fault of the setup.

**d) Not reachable from the host itself?** On ikaria:
`curl -sI --max-time 5 http://127.0.0.1:9976/` must **fail**. If it gets an
answer, Baïkal is bound to more than the LAN address.

**e) Not reachable from outside?** From outside the LAN, e.g. from milos or a
phone on mobile data:

```bash
curl -sI --max-time 10 http://<public-ip>:9976/    # expect: timeout or connection refused
nc -vz -w 10 <public-ip> 9976                      # expect: not "succeeded"/"open"
```

Also check that the router has no port forwarding for 9976 and that
no QuickConnect or DDNS entry of DSM points at Baïkal.

## 9. Emergency mode and failback

What makes a warm standby dangerous is the nightly sync **overwriting** what
clients wrote into Baïkal during an emergency. So:

- **Freeze.** `touch /volume1/baikal/FROZEN` before the first client is
  pointed at Baïkal. While the file exists, the standby sync refuses to do
  anything and reports `standby frozen since <mtime>` as an **error**. That
  is deliberate: the run is red every night until the emergency is closed, so
  it cannot be forgotten.
- **Automatic protection.** If Nextcloud is unreachable, the export fails, the
  staging marker ages, and the standby stays untouched after
  `MARKER_MAX_AGE_HOURS` at the latest (7.1, step 1). Freezing is still
  required, because Nextcloud may come back while clients are still writing
  to Baïkal.
- **Failback, by hand** (runbook in `baikal/README.md`):
  1. Export from Baïkal, per collection with `?export`. Verify that Baïkal
     enables sabre's ICSExportPlugin; if not, export with a client or
     vdirsyncer.
  2. Import into Nextcloud, through the web UI or by `PUT` per object with the
     same library.
  3. Repoint the clients to Nextcloud.
  4. Let the export run.
  5. Delete `FROZEN`, so the standby follows Nextcloud again.

Data loss on the Nextcloud side, such as a calendar deleted by mistake, is not
covered by the standby: it follows the deletion within a night, apart from
whole collections (7.1, step 2) and the `MAX_DELETE` guard. **The history is
in restic**, and the standby is not a backup.

## 10. Tests

This repository has no test framework and should not get one. The tests are
plain bash scripts with a clear exit code, and they compare against expected
output, in line with the verification standard in `CLAUDE.md`.

### 10.1 Offline: `tests/run-tests.sh`

- Sources `lib/dav-lib.sh` and runs each function against `tests/fixtures/`.
- Compares the result with `tests/expected/` using `diff -u`. Prints one
  `PASS`/`FAIL` line per case; the exit code is the number of failures.
- No network, no root, no host. It runs **on the Mac under bash 3.2** as well
  as on ikaria (bash 4.4), which tests the compatibility targets for free.
- Fixtures are **synthetic** and contain no real data. At least these:

  | Fixture | Covers |
  |---|---|
  | `simple.ics` | a few VEVENT, one VTODO |
  | `recurrence.ics` | a recurring event with two exceptions (same UID) |
  | `timezones.ics` | two VTIMEZONEs, events referencing one, both, none |
  | `folded.ics` | a folded UID line and a folded DESCRIPTION, CRLF |
  | `valarm-uid.ics` | a VALARM with its own UID (must not be counted) |
  | `truncated.ics` | export cut off mid-object |
  | `empty-calendar.ics` | VCALENDAR without components (valid, 0 objects) |
  | `error-page.html` | HTML body that arrived with status 200 |
  | `contacts.vcf` | vCard 3.0 and 4.0 mixed, a folded base64 PHOTO |
  | `propfind-nextcloud.xml` | recorded multistatus from Nextcloud (anonymised), including subscription, birthday calendar, Deck, shared-in, trashbin |
  | `propfind-baikal.xml` | recorded multistatus from Baïkal 0.13.0 |
  | `manifest-*.tsv` | trend guard: within limit, over limit, collection gone |

- What it covers: `ics_unfold`, `ics_stats`, `vcf_stats`, `ics_split` (one
  object per UID, only the referenced VTIMEZONEs), `vcf_split`, `uid_name`
  (stable, path-safe), the multistatus parsing and filter rules, and
  `manifest_compare`.

### 10.2 Integration: `tests/integration.sh`

Runs against the live Baïkal with the principal `SELFTEST_PRINCIPAL`, under
`BAIKAL_URL` from `global.conf`, so it tests Baïkal exactly the way the
standby reaches it:

1. create a collection,
2. `PUT` the split fixtures,
3. `PROPFIND` and compare the count,
4. `?export` and compare the UID set with the fixture,
5. change one object and check that only that object is `PUT` again (etag
   logic),
6. delete it, check that `MAX_DELETE` triggers,
7. remove the collection.

Started by hand, through `backup-dav-standby.sh --self-test`, and after every
image rebuild (7.3). It never touches standby or restore-test principals. It
does not replace the port checks (8.4), which test exposure, not function.

### 10.3 Against Nextcloud: read-only

Nextcloud is checked through `backup-dav.sh --list` (configuration only) and
`--dry-run` (discovery and server counts, no download), not through a test
suite. On the host this uses the throwaway-copy recipe from `CLAUDE.md`, as
`bbruecker` under `/volume1/@tmp`, with `TELEGRAM_CONF` pointing at an `xxx`
file.

### 10.4 Static checks

These go into the checks section of `CLAUDE.md`:

```bash
cd backup-dav && shellcheck -x backup-dav.sh backup-dav-standby.sh lib/dav-lib.sh tests/*.sh
```

## 11. Scheduling on ikaria

The order in `backup-wrapper.sh`, which is host-local; `backup-wrapper.example.sh`
gets the commented lines:

```bash
/volume1/scripts/backup-scripts/backup-rclone-sync/backup-rclone-sync.sh
/volume1/scripts/backup-scripts/backup-dav/backup-dav.sh
/volume1/scripts/backup-scripts/backup-dav/backup-dav-standby.sh
/volume1/scripts/backup-scripts/backup-restic/backup-restic.sh
```

The export runs before restic, so restic backs up tonight's export, and the
standby runs before restic, so Baïkal's SQLite is at rest during the snapshot.
As usual there is no error handling between the stages.

The restore test is a separate monthly DSM task with
`backup-dav-standby.sh --restore-test`, not run after a restic run that may
still be going (the lock does not cover restic). The image rebuild (8.1)
follows it, by hand or as a second task.

`PATH` on DSM: `docker` and `restic` are only under `/usr/local/bin`, so
`RESTIC_BIN` is absolute. The scripts do not need `docker`; only the rebuild
does.

## 12. Further points

- **Consent.** At the start only your own data is backed up. With the first
  additional account the point comes back: the backup then holds other
  people's private appointments and contacts, and the standby makes them
  readable to anyone with LAN access and a Baïkal password. The account
  owners should know about it and create their app passwords themselves.
- **What is not covered.**
  - Attachments (`ATTACH` with a link into Nextcloud Files) are kept only as
    links.
  - Nextcloud-specific properties (`X-NC-…`, colours) may get lost in Baïkal.
  - Nextcloud's own calendar trash bin is not exported.
  - Files, Deck boards and Talk are out of scope. These limits belong in the
    README.
- **Rate limits and size.** The number of requests per run is small (two
  PROPFINDs and one GET per collection). Large address books with photos need
  `CURL_MAX_TIME`. Verify how Storage Share behaves under brute-force
  protection; 5.2 avoids retries on 401.
- **File modes.** Export and staging files `0640`, directories `0750`
  (`STAGING_UMASK=0027`). The log file stays `0644` and contains no object
  contents, only collection names, counts and the UIDs of failed objects.
  UIDs are accepted in the log (13).
- **Repository changes beyond the module.**
  - `CLAUDE.md`: module table, pipeline diagram, log prefixes `dav-export` and
    `dav-standby`, `generator=dav-export`, checks.
  - Root `README.md`.
  - `.gitignore` and `mutagen.example.yml` (secrets).
  - `backup-wrapper.example.sh`.
  - A restic instance for `/volume1/baikal` on ikaria (live configuration
    only).
- **Rejected alternatives.**
  - Per-object download with `REPORT calendar-query` would keep the
    server's resource names and etags, but it means unescaping calendar data
    out of XML. That is fragile in awk.
  - vdirsyncer is two-way sync and needs Python packages on DSM.
  - calcardbackup needs the database.
  - occ is not scriptable on Storage Share.
  - Sharing calendars to a backup account hides private events.
  - The image `ckulka/baikal` has no 0.13 (8.1).
  - A coverage check through the OCS user list is unnecessary, because
    accounts are added by hand.

## 13. Open questions

**Decided (2026-11-19):**

- Accounts: only `bbruecker`. More accounts later, added by hand; for that
  reason there is no coverage check.
- Baïkal port: **9976**. The LAN address `192.168.223.2` is fixed.
- TLS: **no**. Baïkal runs on plain HTTP in the LAN with Digest auth; no
  reverse proxy, no certificate (8.1).
- Restore test: no marker. The result is reported through the log and
  Telegram.
- Image: our own build of Baïkal 0.13.0 on `php:8.4-apache` (8.1).
- Log: the UIDs of failed objects may appear in the `0644` log.
- Host names: `ikaria`, `ikaria.fritz.box` and `192.168.223.2`, all three
  without restriction. Clients use `ikaria.fritz.box`, the scripts the IP.

**Open:** nothing at the moment. The "verify" points in the text are checked
during implementation.

## 14. Implementation order

1. `lib/dav-lib.sh` with `tests/run-tests.sh` and fixtures. Offline, on the
   Mac.
2. `backup-dav.sh` with `--list`/`--dry-run`, then a real export of
   `bbruecker` into a throwaway copy on ikaria; compare manifest and
   `server_count` by hand with the web UI.
3. Baïkal on ikaria:
   1. build the image (`Dockerfile`, checksum);
   2. create the shared folder; port checks a);
   3. start, setup wizard, principals; port checks b)–e);
   4. `tests/integration.sh`.
4. `backup-dav-standby.sh` sync, then `--restore-test`.
5. Documentation, `CLAUDE.md`, wrapper template, restic instance for
   `/volume1/baikal`.

Every step is one commit, and each script change is verified by comparing logs
on the host as `CLAUDE.md` describes.
