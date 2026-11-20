# Baïkal — the warm standby of backup-dav

Baïkal is a small CalDAV/CardDAV server (sabre/dav with an admin UI). On
ikaria it holds a copy of every account's calendars, tasks and contacts:
`backup-dav-standby.sh` mirrors the nightly export into it, and in an
emergency the clients can be pointed at it. It is **not** a backup: it follows
deletions within a night. The history is in restic.

| File | What it is |
|---|---|
| `Dockerfile` | our own image: Baïkal 0.13.0 on `php:8.4-apache-trixie`, release zip checked against a fixed sha256 |
| `baikal-entrypoint.sh` | prepares the two bind mounts (`Specific/db/`, owner `www-data`, `0750`), then starts Apache |
| `apache-baikal.vhost` | the one site: document root `html/`, `.htaccess` allowed (not `*.conf`: that pattern means live configuration here and is ignored) |
| `php-baikal.ini` | `sendmail_path=/bin/false` (no mail, ever), `expose_php=Off` |
| `compose.example.yml` | template for `/volume1/docker/baikal/docker-compose.yml` |

## Why our own image

Baïkal 0.13.0 (2026-10-19, sabre/dav 4.7.1) has no maintained image: the
usual `ckulka/baikal` stops at 0.10.1 on PHP 8.1/8.2, its pull request for
0.13.0 (#334) is unmerged, and an issue about a critical PHP vulnerability
(#331) is open there. So we build from the official release zip on the
official PHP image. Baïkal needs PHP ≥ 8.2 and the extensions ctype, dom,
iconv, mbstring, xmlreader/xmlwriter, curl and pdo_sqlite — the PHP image has
all of them; the build fails if `pdo_sqlite` is missing.

The price: **PHP security updates are our job.** See "Rebuild and update".

## What was verified against Baïkal 0.13.0 (local build, 2026-11-20)

- A wrong checksum fails the build; a fresh container with empty mounts
  starts, and the setup wizard completes.
- Digest auth (realm `BaikalDAV`): 401 without credentials, with a wrong
  password and with Basic; 207 with the netrc.
- `MKCALENDAR` and the extended `MKCOL` (address book) create collections with
  their display name.
- `PUT` stores calendar objects and vCards **byte for byte**: the etag the PUT
  returns and the one a `PROPFIND` lists are the md5 of the body sent. A
  changed object is updated with `If-Match` (204; a stale etag gets 412),
  `DELETE` answers 204.
- `?export` works for calendars (`text/calendar`) and address books
  (`text/directory`).
- Baïkal validates vCards: an `ENCODING` parameter in a vCard 4.0 gets 415.
  Such an object fails its import and is logged with its UID.
- **Scheduling changes stored data.** If an event's `ORGANIZER` is the
  principal's own e-mail address, sabre runs scheduling on the `PUT`: it adds
  `SCHEDULE-STATUS` to every `ATTENDEE`, so the stored object is no longer
  what was sent and every night's sync would send it again. With an
  `invite_from` address it would also mail the attendees. Hence the
  `.invalid` addresses below.
- Paths differ from Nextcloud: calendars under `calendars/<user>/`, address
  books under `addressbooks/<user>/` (no `users/`).

## Setup on ikaria

Done once, by hand. Steps 5 to 7 belong together: until the wizard is done,
**anyone in the LAN who opens the page can set the admin password.**

Baïkal is a stack like the others under `/volume1/docker`:

```
/volume1/docker/baikal/
  docker-compose.yml     from compose.example.yml; versioned in docker-nas
  data/                  root only; neither versioned nor synced (**/data/, */data)
    config/              → /var/www/baikal/config    (baikal.yaml, admin password hash)
    Specific/            → /var/www/baikal/Specific  (db/db.sqlite: all accounts' data)
    FROZEN               only in an emergency (STANDBY_FREEZE_FILE)
```

`/volume1/docker` is mirrored by mutagen from `~/Git/docker-nas` on the Mac
and versioned there. Everything Baïkal writes therefore goes below `data/`,
which both ignore lists already exclude: the database must reach neither the
Mac nor GitHub.

1. **Port check a)** (below): the port must be free.
2. **Compose file.** On the Mac, in `~/Git/docker-nas`:
   ```bash
   mkdir baikal
   cp ~/Work/backup-scripts-ikaria/backup-dav/baikal/compose.example.yml baikal/docker-compose.yml
   ```
   mutagen brings it to `/volume1/docker/baikal/`; commit it there like the
   other stacks. It builds from the module directory (`build:`), so there is
   no copy of the Dockerfile to drift.
3. **Data directory**, on ikaria as root, closed to everyone else:
   ```bash
   sudo install -d -m 0700 -o root -g root /volume1/docker/baikal/data
   sudo install -d -m 0700 /volume1/docker/baikal/data/config /volume1/docker/baikal/data/Specific
   ls -ld /volume1/docker/baikal/data      # expect: drwx------ root root, no "+" (no DSM ACL)
   ```
   The entrypoint hands `config/` and `Specific/` to `www-data` on start.
4. **Build:**
   ```bash
   cd /volume1/docker/baikal && sudo /usr/local/bin/docker compose build --pull
   ```
5. **Start:** `sudo /usr/local/bin/docker compose up -d`
6. **Port check b)** — before the wizard: if the binding is wrong, the wizard
   is open to more than the LAN.
7. **Setup wizard**, in the browser at `http://ikaria.fritz.box:9976/`:
   - Time zone: `Europe/Berlin`.
   - CalDAV and CardDAV: enabled.
   - **"Email invite sender address": empty.** The wizard pre-fills
     `noreply@…`; as long as it is set, Baïkal sends invitations to the
     attendees of every imported event. (`php-baikal.ini` blocks `mail()`
     as a second lock.)
   - WebDAV authentication type: **Digest**. Without TLS, Basic would send the
     password readable in every request.
   - Admin password: a new one, into the password manager.
   - Database: SQLite, the default path (`/var/www/baikal/Specific/db/db.sqlite`).
8. **Principals.** Admin UI (`http://ikaria.fritz.box:9976/admin/`) → Users
   and resources → Add user, three at the start:

   | User name | E-mail | Used by |
   |---|---|---|
   | `bbruecker` | `bbruecker@baikal.invalid` | the standby of the account `bbruecker` |
   | `restore-test` | `restore-test@baikal.invalid` | `--restore-test` (`RESTORE_TEST_PRINCIPAL`) |
   | `selftest` | `selftest@baikal.invalid` | `--self-test` (`SELFTEST_PRINCIPAL`) |

   - The user name is the Nextcloud account's name: one more principal per
     account added later (`STANDBY_USER` overrides it).
   - The e-mail address must never be a real one, see "Scheduling changes
     stored data" above. `.invalid` is reserved and never resolves.
   - Each gets its own password, into the password manager.
   - Baïkal creates a "Default calendar" and a "Default Address Book" for
     every new user. **Delete both** (the calendar and address book icons in
     the user's row). The standby never deletes a collection it does not
     know; it would report them every night.
9. **Credentials.** As root, each file `0600`:
   - add the Baïkal line to the account's netrc
     (`backup-dav/secrets/bbruecker.netrc`), with the host exactly as in
     `BAIKAL_URL`:
     ```
     machine 192.168.223.2 login bbruecker password <baikal-password>
     ```
   - one netrc each for the two test principals, `secrets/restore-test.netrc`
     and `secrets/selftest.netrc` (`RESTORE_TEST_NETRC`, `SELFTEST_NETRC`
     in `global.conf`), each with its one `machine 192.168.223.2` line.

   They are separate files because curl picks the netrc line by host alone,
   and all three principals share the host.
10. **Check the login.** Expect `207`:
    ```bash
    sudo curl -s --digest --netrc-file /volume1/scripts/backup-scripts/backup-dav/secrets/bbruecker.netrc \
      -X PROPFIND -H 'Depth: 0' -o /dev/null -w '%{http_code}\n' \
      http://192.168.223.2:9976/dav.php/principals/bbruecker/
    ```
11. **Port checks c) to e).**
12. **restic.** Nothing to do: the `backup-restic` instance `docker`
    (`BACKUP_PATH="/volume1/docker"`) already covers `baikal/data/` — its
    `EXCLUDES` must stay free of it. In an emergency Baïkal is the primary.
    The nightly standby sync runs before restic, so the SQLite file is at rest
    during the snapshot.

## Port checks

Each command says what it should show. If it shows something else, Baïkal is
not exposed the way it is meant to be, and it must not be used until that is
fixed. Run them **before the first start, after the first start, and again
after every Baïkal or DSM update, image rebuild and router change.**

**a) Before setup: is the port free?** On ikaria, as root, because without
sudo `docker ps` and `netstat -p` do not show everything:

```bash
sudo netstat -tlnp | grep ':9976 '                                 # expect: no output
sudo /usr/local/bin/docker ps --format '{{.Names}} {{.Ports}}' \
  | grep 9976                                                      # expect: no output
sudo grep -c 9976 /usr/syno/etc/www/ReverseProxy.json              # expect: 0
```

Also check in DSM that no package uses 9976.

**b) After starting: is the binding right?**

```bash
sudo netstat -tln | grep ':9976 '          # expect: 192.168.223.2:9976 only
sudo /usr/local/bin/docker port baikal     # expect: 80/tcp -> 192.168.223.2:9976
```

If it shows `0.0.0.0:9976` or `:::9976`, the IP is missing from the port
mapping in `docker-compose.yml`.

**c) Reachable from the LAN, under all three names?** From the Mac:

```bash
# expect "HTTP/1.1 401 Unauthorized" three times (after the wizard; before it, "302 Found")
for h in ikaria ikaria.fritz.box 192.168.223.2; do
  printf '%s: ' "$h"; curl -sI --max-time 5 "http://$h:9976/dav.php" | head -n1
done
```

A timeout means the binding is wrong. If only `ikaria` fails, the client is
missing the `fritz.box` search domain; that is a client setting, not a fault
of the setup.

**d) Not reachable from the host itself?** On ikaria:
`curl -sI --max-time 5 http://127.0.0.1:9976/` must **fail**. If it gets an
answer, Baïkal is bound to more than the LAN address.

**e) Not reachable from outside?** From outside the LAN, e.g. from milos or a
phone on mobile data:

```bash
curl -sI --max-time 10 http://<public-ip>:9976/    # expect: timeout or connection refused
nc -vz -w 10 <public-ip> 9976                      # expect: not "succeeded"/"open"
```

Also check that the router has no port forwarding for 9976 and that no
QuickConnect or DDNS entry of DSM points at Baïkal.

**What protects the port.** The binding to the LAN address and the absence of
any forwarding in the router. A DSM firewall rule (TCP 9976 only from
`192.168.223.0/24`) does no harm, but do not count on it: Docker publishes
ports through its own iptables rules, which DSM's firewall may not see. Checks
c) to e) are the proof, not the rule.

## Rebuild and update

Monthly, after the restore test, and straight away on a critical PHP CVE:

```bash
cd /volume1/docker/baikal
sudo /usr/local/bin/docker compose build --pull
sudo /usr/local/bin/docker compose up -d
sudo /volume1/scripts/backup-scripts/backup-dav/backup-dav-standby.sh --self-test
```

Then port checks b) to d). The data in `data/` is kept. Watchtower leaves the
container alone (label in `docker-compose.yml`): a local image has no registry
to update from.

**A new Baïkal version:** read the release notes first (0.13.0, for example,
asks for a backup before upgrading older SQLite installs). Then change
`BAIKAL_VERSION` and `BAIKAL_SHA256` in the Dockerfile — the sha256 GitHub
shows for the release asset — and the image tag in `docker-compose.yml`,
rebuild, and open the admin UI once: Baïkal may ask to upgrade its database.
If ckulka publishes a 0.13 image later (#334), switching back to an external
image is an option.

## Emergency use and failback

The danger of a warm standby is the nightly sync **overwriting** what clients
wrote into Baïkal during an emergency.

1. **Freeze first:** `sudo touch /volume1/docker/baikal/data/FROZEN` (`STANDBY_FREEZE_FILE`)
   before the first client is pointed at Baïkal. While the file exists the
   standby sync does nothing and reports `standby frozen since <time>` as an
   **error**, every night, until the emergency is closed. That is deliberate.
2. **Point the clients** at `http://ikaria.fritz.box:9976/dav.php` with the
   principal's Baïkal user name and password (macOS and iOS warn about the
   missing TLS). Scheduling stays off while the principal has its `.invalid`
   address — invitations from clients are not sent.
3. **Consistent backups while clients write:** before a restic run,
   `sudo /usr/local/bin/docker exec -u www-data baikal sqlite3 /var/www/baikal/Specific/db/db.sqlite ".backup /var/www/baikal/Specific/db/db-backup.sqlite"`.

**Failback, by hand:**

1. Export from Baïkal, per collection:
   `curl --digest --netrc-file … -o <uri>.ics 'http://192.168.223.2:9976/dav.php/calendars/<user>/<uri>/?export'`
   (address books: `addressbooks/<user>/<uri>/?export`). Verified to work.
2. Import into Nextcloud, through the web UI (Calendar → Settings → Import;
   Contacts → Import).
3. Repoint the clients to Nextcloud.
4. Let `backup-dav.sh` run, and check its log.
5. Delete `FROZEN`, so the standby follows Nextcloud again.
