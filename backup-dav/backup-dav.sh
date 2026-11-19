#!/usr/bin/env bash
#
# backup-dav.sh — exports the calendars, tasks and address books of Nextcloud
# accounts over CalDAV/CardDAV into a local staging directory, one account per
# configured instance.
#
# Nextcloud as a managed service (Hetzner Storage Share) offers no shell, no
# database and no schedulable occ, so what is left is HTTP: per collection one
# PROPFIND to count the objects on the server and one "GET <collection>?export"
# for all of them in one file. Every export is checked — transport, structure,
# completeness against the server's count, and a trend guard against the
# previous run — and only an account whose every collection passed replaces
# its previous export. Like backup-docker-db and backup-tar this is a PRODUCER:
# after an error-free account it writes a completion marker into the account's
# staging directory, for backup-dav-standby.sh and backup-restic.
#
# Staging keeps the server's exports unchanged:
#
#   $STAGING_BASE/<account>/
#     .complete            marker, generator=dav-export
#     manifest.tsv         one line per collection (see lib/dav-lib.sh)
#     calendars/<uri>.ics
#     addressbooks/<uri>.vcf
#
# Nothing is hard-coded here; every path, URL and switch comes from:
#   global.conf               run-wide switches (curl, staging, Telegram, …)
#   instances/<account>.conf  one file per Nextcloud account — a new account
#                             needs no change to this script
#   lib/dav-lib.sh            the DAV helpers (requests, multistatus, iCalendar
#                             and vCard checks, manifest) — the domain library
#   ../lib/runlib/            the shared run skeleton (log file, error account,
#                             lock, configuration loader, summary,
#                             notification, marker)
# all relative to this script's directory, except runlib, which lives once at
# the root of the collection. See README.md.

set -uo pipefail

# ---------------------------------------------------------------------------
# 1. Initialisation
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# runlib is bound once, at the root of the collection. That makes this directory
# not standalone-deployable: it needs its sibling lib/.
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Per-account records, index-parallel with runlib's INSTANCE_NAMES/INSTANCE_CONFS.
# Appended by validate_account() exactly when it accepts an account, so the
# indices stay aligned; export_one_account() and the marker step read them.
ACCOUNT_USERS=()
ACCOUNT_URLS=()
ACCOUNT_NETRCS=()

# ---------------------------------------------------------------------------
# 2. Command line
#
# Parsed before anything else so "--help" neither reads a configuration nor
# creates a log file.
# ---------------------------------------------------------------------------

SELECTED_ACCOUNTS=()
ACTION="run"
# --dry-run on the command line. DRY_RUN in global.conf is the other way to
# switch it on; the two are merged after the configuration is read (section 5).
CLI_DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: backup-dav.sh [options]

Exports the calendars, tasks and address books of every Nextcloud account
configured in instances/*.conf into the staging directory, checks every export
against the server, and writes a completion marker for every account that was
exported without error.

Options:
  -i, --instance NAME  Export only this account (repeatable). The other
                       accounts, and their markers, are left untouched.
  -n, --dry-run        Discover the collections and count their objects on the
                       server; download nothing, touch no marker. The same as
                       DRY_RUN=true in global.conf.
  -l, --list           List the configured accounts and exit (no network).
  -h, --help           Show this help and exit.

Exit code: 0 only if the run was completely error-free.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -l|--list) ACTION="list"; shift ;;
    -n|--dry-run) CLI_DRY_RUN=1; shift ;;
    -i|--instance)
      [[ $# -ge 2 ]] || { echo "FATAL: $1 requires a name" >&2; exit 2; }
      SELECTED_ACCOUNTS+=("$2"); shift 2 ;;
    --instance=*) SELECTED_ACCOUNTS+=("${1#*=}"); shift ;;
    *) echo "FATAL: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# 3. Libraries
#
# Order matters. runlib first: it provides log_info/log_error (stdout + log
# file) and everything the run skeleton needs. dav-lib.sh second, because it
# owns the bare log() that its own helpers use for their stderr-only
# diagnostics — see the header of runlib/log.sh for why the two channels must
# stay apart.
# ---------------------------------------------------------------------------

RUNLIB="$ROOT_DIR/lib/runlib/runlib.sh"
DAV_LIB="$SCRIPT_DIR/lib/dav-lib.sh"
for lib_file in "$RUNLIB" "$DAV_LIB"; do
  [[ -r "$lib_file" ]] || {
    echo "FATAL: library not readable: $lib_file" >&2
    echo "       (../lib/runlib is a git submodule — run 'git submodule update --init')" >&2
    exit 1
  }
done
# shellcheck source=../lib/runlib/runlib.sh
source "$RUNLIB"
# shellcheck source=lib/dav-lib.sh
source "$DAV_LIB"

# ---------------------------------------------------------------------------
# 4. Log file
#
# Created BEFORE the configuration is read, so configuration errors also end up
# in a log file instead of vanishing on stderr. Depends only on SCRIPT_DIR.
# The directory, and with it logs/.lock, is shared with backup-dav-standby.sh:
# an export and a standby sync never run at the same time.
# ---------------------------------------------------------------------------

LOG_DIR="$SCRIPT_DIR/logs"
run_init "$LOG_DIR" "dav-export" \
  || { echo "FATAL: cannot create the log file in $LOG_DIR" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 5. Configuration
# ---------------------------------------------------------------------------

GLOBAL_CONF="$SCRIPT_DIR/global.conf"
[[ -f "$GLOBAL_CONF" ]] \
  || fatal "Global configuration not found: $GLOBAL_CONF (copy global.conf.example and adjust it)"
# shellcheck source=/dev/null
source "$GLOBAL_CONF"

# Optional values: ":=" only assigns when unset or empty, so anything set in
# global.conf always wins.
: "${CURL_BIN:=curl}"
: "${INSTANCES_DIR:=$SCRIPT_DIR/instances}"
: "${STAGING_BASE:=}"
: "${STAGING_MODE:=0750}"
: "${STAGING_GROUP:=}"
: "${STAGING_UMASK:=0027}"
: "${MARKER_NAME:=.complete}"
: "${CURL_CONNECT_TIMEOUT:=20}"
: "${CURL_MAX_TIME:=600}"
: "${MAX_SHRINK_PERCENT:=20}"
: "${LOG_RETENTION_DAYS:=64}"
: "${DRY_RUN:=false}"

# Dry run: on if global.conf says so (like backup-restic) OR the command line
# asks for it — the command line can switch it on, never off. From here on
# DRY_RUN is 0 or 1. DRY_RUN_SOURCE names where it came from, for the log.
DRY_RUN_SOURCE=""
if [[ "$CLI_DRY_RUN" -eq 1 ]]; then
  DRY_RUN_SOURCE="--dry-run"
elif is_truthy "$DRY_RUN"; then
  DRY_RUN_SOURCE="DRY_RUN in global.conf"
fi
if [[ -n "$DRY_RUN_SOURCE" ]]; then DRY_RUN=1; else DRY_RUN=0; fi

[[ -n "$STAGING_BASE" ]] \
  || fatal "STAGING_BASE is not set (global.conf) — the exports need a staging directory"
[[ "$STAGING_BASE" == /* ]] \
  || fatal "STAGING_BASE must be an absolute path (global.conf): '$STAGING_BASE'"
STAGING_BASE="${STAGING_BASE%/}"
[[ "$(abs_path "$STAGING_BASE")" != "/" ]] \
  || fatal "STAGING_BASE=\"/\" is not supported (global.conf)"
for v in CURL_CONNECT_TIMEOUT CURL_MAX_TIME MAX_SHRINK_PERCENT; do
  [[ "${!v}" =~ ^[0-9]+$ ]] || fatal "$v must be a number (global.conf): '${!v}'"
done
[[ "$MAX_SHRINK_PERCENT" -le 100 ]] \
  || fatal "MAX_SHRINK_PERCENT must be between 0 and 100 (global.conf): '$MAX_SHRINK_PERCENT'"

# The global value is the per-account default, kept under its own name so an
# instances/<account>.conf can be reset to it before every file is sourced.
DEFAULT_MAX_SHRINK_PERCENT="$MAX_SHRINK_PERCENT"

# The export talks to Nextcloud with Basic auth over TLS (an app password).
# shellcheck disable=SC2034  # read by dav_request in the library.
DAV_AUTH="basic"

# ---------------------------------------------------------------------------
# 5b. What this run calls things
#
# runlib runs the same skeleton for every script of the family; these are the
# words that keep THIS script's log and notification its own.
# ---------------------------------------------------------------------------

# shellcheck disable=SC2034  # every name here is read by lib/runlib, not below.
{
  RUN_WHAT="DAV export"
  RUN_LOG_NAME="DAV export run"
  RUN_UNIT="Accounts"
  RUN_OK_VERB="export successful"
  # A dry run downloads nothing; "export successful" would claim otherwise.
  [[ "$DRY_RUN" -eq 1 ]] && RUN_OK_VERB="dry run ok, nothing exported"
  RUN_ABORT_HINT="An account may be half-exported; its previous export and completion marker are still in place."
  RUN_USES_MARKER=1
  # The exports land in sub-directories (calendars/, addressbooks/), which
  # runlib's default measure does not look into; the worker reports its own
  # byte count instead (export_bytes).
  RUN_BYTES_FN="export_bytes"
  INSTANCE_LABEL="Account"
  INSTANCE_LABEL_LC="account"
  INSTANCE_OPT="--instance"
  MARKER_NOTE="not written"
}

# Telegram credentials: from TELEGRAM_CONF when global.conf points at one,
# otherwise from global.conf itself.
notify_init

# ---------------------------------------------------------------------------
# 6. trap handler
#
# Registered as soon as the Telegram credentials are known, so a configuration
# error from here on also raises an alarm instead of failing silently under
# cron. Nothing has to be rolled back at this level: an account is built in
# "<account>.new" and only swapped in when complete, so an interruption leaves
# the previous export and its marker as they were. The leftover ".new" is
# removed by the next run.
# ---------------------------------------------------------------------------

run_traps

# ---------------------------------------------------------------------------
# 7. Helper functions
# ---------------------------------------------------------------------------

prepare_staging_dir() {
  # prepare_staging_dir <dir> — create a directory and give it the configured
  # mode/group. Returns 1 on failure WITHOUT logging: it is called from inside
  # the per-account subshell, whose log channel is the library's stderr log()
  # — so the call site reports the failure.
  local dir="$1"
  mkdir -p "$dir" || return 1
  chmod "$STAGING_MODE" "$dir" || return 1
  if [[ -n "$STAGING_GROUP" ]]; then
    chgrp "$STAGING_GROUP" "$dir" || return 1
    # setgid: everything created below inherits the group, so a read-only
    # consumer can read it without this script chasing each new file.
    chmod g+s "$dir" || return 1
  fi
  return 0
}

# shellcheck disable=SC2034  # ENABLED is read by lib/runlib's loader; the rest
# by the account configurations sourced on top of them and by the worker.
reset_account_vars() {
  # Every per-account variable, set to its default. Called by runlib before
  # each instances/<account>.conf is sourced (and again inside the subshell),
  # so a value from one file never leaks into the next. DAV_USER defaults to
  # the file name, so the usual configuration does not repeat it.
  local name="${1:-}"
  DAV_URL=""
  DAV_USER="$name"
  NETRC_FILE=""
  ENABLED="true"
  INCLUDE_SHARED="false"
  EXCLUDE_COLLECTIONS=()
  MAX_SHRINK_PERCENT="$DEFAULT_MAX_SHRINK_PERCENT"
  ACCEPT_SHRINK="false"
  # Read by backup-dav-standby.sh, not here; reset so they cannot leak either.
  STANDBY="true"
  STANDBY_USER=""
}

validate_account() {
  # validate_account <name> <conf> — runlib's per-object hook. The configuration
  # has been sourced at this point.
  #
  # A configuration that cannot be used is an ERROR, not a silent skip: it ends
  # up in ERRORS and thus in the exit code. Only an explicit ENABLED=false is a
  # deliberate skip (runlib handles that).
  local name="$1" conf="$2" host shared="excluded" guard

  DAV_URL="${DAV_URL%/}"
  if [[ -z "$DAV_URL" ]]; then
    log_error "Account '$name' ($conf): DAV_URL not set — skipped"
    return 1
  fi
  case "$DAV_URL" in
    https://*) ;;
    http://*) log_warn "Account '$name': DAV_URL is plain http — the app password crosses the network readable" ;;
    *) log_error "Account '$name': DAV_URL must start with https://, not '$DAV_URL' — skipped"; return 1 ;;
  esac
  if [[ -z "$DAV_USER" ]]; then
    log_error "Account '$name': DAV_USER is empty — skipped"
    return 1
  fi
  case "$DAV_USER" in
    */*|*' '*) log_error "Account '$name': DAV_USER '$DAV_USER' contains '/' or a space — skipped"; return 1 ;;
  esac
  host="$(dav_url_host "$DAV_URL")"

  # The credentials: a netrc, never an argument. Refused when anyone but the
  # owner could read it — the strictness ssh applies to a private key.
  if [[ -z "$NETRC_FILE" ]]; then
    log_error "Account '$name': NETRC_FILE not set — skipped"
    return 1
  fi
  if [[ ! -r "$NETRC_FILE" ]]; then
    log_error "Account '$name': NETRC_FILE not readable for user '$(id -un)': $NETRC_FILE — skipped"
    return 1
  fi
  if ! file_private "$NETRC_FILE"; then
    log_error "Account '$name': NETRC_FILE must be a regular file that only its owner can read (chmod 600): $NETRC_FILE — skipped"
    return 1
  fi
  # Without a matching entry curl would ask without credentials: a 401 that
  # says nothing about the password and still counts against this host.
  if ! netrc_has_machine "$NETRC_FILE" "$host"; then
    # The usual slip: the URL pasted in as it is. curl compares the bare host
    # name and would not find it.
    if netrc_has_machine "$NETRC_FILE" "https://$host" || netrc_has_machine "$NETRC_FILE" "http://$host"; then
      log_error "Account '$name': NETRC_FILE names the machine with its scheme ('machine https://$host') — write the bare host name: 'machine $host login … password …' ($NETRC_FILE) — skipped"
    else
      log_error "Account '$name': NETRC_FILE has no 'machine $host' entry (the bare host name of DAV_URL, without https://): $NETRC_FILE — skipped"
    fi
    return 1
  fi

  if ! [[ "$MAX_SHRINK_PERCENT" =~ ^[0-9]+$ ]] || [[ "$MAX_SHRINK_PERCENT" -gt 100 ]]; then
    log_error "Account '$name': MAX_SHRINK_PERCENT must be a number between 0 and 100, not '$MAX_SHRINK_PERCENT' — skipped"
    return 1
  fi
  is_truthy "$INCLUDE_SHARED" && shared="included"

  ACCOUNT_USERS+=("$DAV_USER")
  ACCOUNT_URLS+=("$DAV_URL")
  ACCOUNT_NETRCS+=("$NETRC_FILE")
  instances_record "$STAGING_BASE/$name" "$name"

  guard="trend guard ${MAX_SHRINK_PERCENT}%"
  if is_truthy "$ACCEPT_SHRINK"; then
    guard="trend guard OFF (ACCEPT_SHRINK)"
    # Every run, on purpose: the switch is meant for one deliberate cleanup and
    # must not be forgotten in the configuration.
    log_warn "Account '$name': ACCEPT_SHRINK=true — a shrunk or vanished collection is accepted. Remove it from $conf after this run."
  fi
  log_info "Account '$name': $DAV_USER @ $host -> $STAGING_BASE/$name, shared collections $shared, $guard${EXCLUDE_COLLECTIONS[0]:+, excluding ${EXCLUDE_COLLECTIONS[*]}}"
  return 0
}

check_binaries() {
  # Report the availability of the required programs at the very start, so a
  # missing or mislocated binary is obvious in the log instead of surfacing as a
  # cryptic failure halfway through.
  log_info "--- Checking programs ---"
  local p
  if p="$(command -v "$CURL_BIN" 2>/dev/null)"; then
    log_info "curl found: $p ($("$CURL_BIN" --version 2>/dev/null | head -n1 | cut -d' ' -f1-2))"
  else
    fatal "curl not found: '$CURL_BIN'. Set CURL_BIN in global.conf to the absolute path (e.g. /usr/bin/curl)."
  fi
  notify_check_binaries
}

export_bytes() {
  # export_bytes <name> <index> <outdir> — runlib's RUN_BYTES_FN: what the
  # worker reported for this account, 0 if it never got that far. The worker
  # cannot set a variable across its subshell, so it leaves a small key=value
  # file that the marker parser reads back.
  marker_value "$STATS_DIR/$2.result" bytes 2>/dev/null || printf '0'
}

# --- per-account export -----------------------------------------------------

export_one_account() {
  # export_one_account <name> <conf> <index> — runlib's worker.
  #
  # Called on the LEFT side of a pipeline, i.e. in a SUBSHELL — deliberately: a
  # failure here has to end THIS account and not the whole run, and the
  # per-account variables (including the arrays) cannot leak into the next one.
  # Logging therefore goes through the library's log() (stderr, captured by
  # that pipe). What the run level needs afterwards (counts, bytes) goes into
  # $STATS_DIR/<index>.result.
  local name="$1" conf="$2" idx="$3"
  local user="${ACCOUNT_USERS[$idx]}" url="${ACCOUNT_URLS[$idx]}" netrc="${ACCOUNT_NETRCS[$idx]}"
  local P="Account '$name': "
  # shellcheck disable=SC2034  # read by runlib's cmd_run, which prefixes its log line with it.
  local CMD_PREFIX="$P"
  local work="$STATS_DIR/$idx" result="$STATS_DIR/$idx.result"
  local final="$STAGING_BASE/$name" new="$STAGING_BASE/$name.new" old="$STAGING_BASE/$name.old"
  local origin kind kw home homepath resp rc code ctype href types dn uri reason subdir ext file
  local count bytes stats bad ev td objs cards failed=0 n=0 shared=0
  local hrefs=() kinds=() uris=() names=()
  local t_coll=0 t_obj=0 t_ev=0 t_td=0 t_cards=0 t_bytes=0

  reset_account_vars "$name"
  # shellcheck source=/dev/null
  source "$conf" || { log ERROR "${P}cannot read $conf"; exit 1; }
  is_truthy "$INCLUDE_SHARED" && shared=1

  : > "$result"
  mkdir -p "$work" || { log ERROR "${P}cannot create the working directory $work"; exit 1; }
  origin="$(dav_url_origin "$url")"

  # --- 1. discover ---------------------------------------------------------
  # One PROPFIND per home. 401/403/429 stop the account at once: Nextcloud
  # throttles failed logins per source IP, and a retry with the same wrong
  # password would slow down or lock out every account asked from this host.
  for kind in calendar addressbook; do
    if [[ "$kind" == calendar ]]; then home="$url/calendars/$user/"; kw="calendar"
    else home="$url/addressbooks/users/$user/"; kw="address book"
    fi
    homepath="$(dav_url_path "$home")"
    rc=0
    resp="$(dav_propfind "$home" "$netrc" 1 "$DAV_PROPFIND_COLLECTIONS" "$work/home.$kind.xml")" || rc=$?
    code="${resp%% *}"
    if [[ "$rc" -ne 0 ]]; then
      log ERROR "${P}$kw home $home unreachable (curl exit $rc: $(curl_rc_text "$rc")) — account stopped"
      exit 1
    fi
    if http_auth_refused "$code"; then
      log ERROR "${P}$kw home answered HTTP $code ($(http_text "$code")) — account stopped at once, no retry (failed logins are throttled per IP). Check the app password in $netrc."
      exit 1
    fi
    if [[ "$code" != 207 ]]; then
      log ERROR "${P}$kw home $home answered HTTP $code ($(http_text "$code")), expected 207 — account stopped"
      exit 1
    fi
    while IFS="$(printf '\t')" read -r href types dn _; do
      [[ -n "$href" ]] || continue
      [[ "${href%/}/" == "${homepath%/}/" ]] && continue     # the home itself
      uri="$(dav_href_uri "$href")"
      if reason="$(dav_skip_reason "$kind" "$uri" "$types" "$shared" \
                     "${EXCLUDE_COLLECTIONS[@]+"${EXCLUDE_COLLECTIONS[@]}"}")"; then
        log INFO "${P}$kw '$uri' skipped — $reason"
        continue
      fi
      hrefs+=("$href"); kinds+=("$kind"); uris+=("$uri"); names+=("$dn")
    done < <(ms_responses "$work/home.$kind.xml")
  done

  if [[ "${#hrefs[@]}" -eq 0 ]]; then
    log WARN "${P}no calendar and no address book to export"
  else
    log INFO "${P}${#hrefs[@]} collection(s) to export"
  fi

  # --- 2.-4. count, download, check ---------------------------------------
  if [[ "$DRY_RUN" -eq 0 ]]; then
    # Leftovers of an interrupted run: ".new" never became the export, ".old"
    # is the export before the last completed swap.
    rm -rf "$new" "$old" || { log ERROR "${P}cannot remove the leftovers $new / $old"; exit 1; }
    prepare_staging_dir "$STAGING_BASE" \
      || { log ERROR "${P}cannot prepare the staging directory $STAGING_BASE"; exit 1; }
    for subdir in "" /calendars /addressbooks; do
      prepare_staging_dir "$new$subdir" || { log ERROR "${P}cannot create $new$subdir"; exit 1; }
    done
    manifest_header > "$new/manifest.tsv" || { log ERROR "${P}cannot write $new/manifest.tsv"; exit 1; }
  fi

  for n in "${!hrefs[@]}"; do
    href="${hrefs[$n]}"; kind="${kinds[$n]}"; uri="${uris[$n]}"; dn="${names[$n]}"
    kw="calendar"; [[ "$kind" == addressbook ]] && kw="address book"

    # Count on the server: a Depth-1 PROPFIND lists every object once.
    rc=0
    resp="$(dav_propfind "$origin$href" "$netrc" 1 "$DAV_PROPFIND_ETAGS" "$work/count.xml")" || rc=$?
    code="${resp%% *}"
    if [[ "$rc" -ne 0 ]]; then
      log ERROR "${P}$kw '$uri': counting failed (curl exit $rc: $(curl_rc_text "$rc"))"
      failed=1; continue
    fi
    if http_auth_refused "$code"; then
      log ERROR "${P}$kw '$uri': HTTP $code ($(http_text "$code")) — account stopped at once, no retry"
      rm -rf "$new"; exit 1
    fi
    if [[ "$code" != 207 ]]; then
      log ERROR "${P}$kw '$uri': counting answered HTTP $code ($(http_text "$code")), expected 207"
      failed=1; continue
    fi
    count="$(ms_member_count "$work/count.xml")"

    if [[ "$DRY_RUN" -eq 1 ]]; then
      log INFO "${P}$kw '$uri' ($dn): $count objects on the server"
      continue
    fi

    # Download: everything in one file.
    if [[ "$kind" == calendar ]]; then subdir="calendars"; ext="ics"
    else subdir="addressbooks"; ext="vcf"
    fi
    file="$new/$subdir/$uri.$ext"
    rc=0
    resp="$(dav_request GET "$origin$href?export" "$netrc" "$file")" || rc=$?
    code="${resp%% *}"; ctype="${resp#* }"
    if [[ "$rc" -ne 0 ]]; then
      log ERROR "${P}$kw '$uri': download failed (curl exit $rc: $(curl_rc_text "$rc"))"
      failed=1; continue
    fi
    if http_auth_refused "$code"; then
      log ERROR "${P}$kw '$uri': HTTP $code ($(http_text "$code")) — account stopped at once, no retry"
      rm -rf "$new"; exit 1
    fi
    if [[ "$code" != 200 ]]; then
      log ERROR "${P}$kw '$uri': download answered HTTP $code ($(http_text "$code"))"
      failed=1; continue
    fi
    # The content type separates an export from an error page that arrived
    # with status 200. sabre's VCF export says text/directory, newer
    # servers text/vcard.
    case "$kind:$ctype" in
      calendar:text/calendar*|addressbook:text/vcard*|addressbook:text/x-vcard*|addressbook:text/directory*) ;;
      *) log ERROR "${P}$kw '$uri': unexpected content type '${ctype:-none}'"; failed=1; continue ;;
    esac
    bytes="$(wc -c < "$file" | tr -d ' ')"

    # Check structure and completeness.
    ev=0; td=0; cards=0
    if [[ "$kind" == calendar ]]; then
      stats="$(ics_stats "$file")"
      read -r bad ev td objs <<< "$stats"
    else
      stats="$(vcf_stats "$file")"
      read -r bad cards <<< "$stats"
      objs="$cards"
      # An empty address book exports as an empty body; that is an export, not
      # a fault — but only while the server also counts nothing.
      [[ "$bad" == empty && "$count" -eq 0 ]] && bad="-"
    fi
    if [[ "$bad" != "-" ]]; then
      log ERROR "${P}$kw '$uri': the export is not sound — $(dav_bad_text "$bad")"
      failed=1; continue
    fi
    if [[ "$objs" -ne "$count" ]]; then
      log ERROR "${P}$kw '$uri': the export holds $objs objects, the server counts $count — incomplete"
      failed=1; continue
    fi

    manifest_row "$kind" "$uri" "$dn" "$count" "$objs" "$ev" "$td" "$cards" "$bytes" >> "$new/manifest.tsv"
    if [[ "$kind" == calendar ]]; then
      log INFO "${P}calendar '$uri' — $objs objects ($ev VEVENT, $td VTODO), $(human_bytes "$bytes")"
    else
      log INFO "${P}address book '$uri' — $objs cards, $(human_bytes "$bytes")"
    fi
    t_coll=$((t_coll + 1)); t_obj=$((t_obj + objs)); t_ev=$((t_ev + ev)); t_td=$((t_td + td))
    t_cards=$((t_cards + cards)); t_bytes=$((t_bytes + bytes))
  done

  if [[ "$DRY_RUN" -eq 1 ]]; then
    [[ "$failed" -eq 0 ]] || exit 1
    exit 0
  fi

  if [[ "$failed" -ne 0 ]]; then
    rm -rf "$new"
    log ERROR "${P}not every collection passed — the previous export stays in place"
    exit 1
  fi

  # --- trend guard ---------------------------------------------------------
  # The analogue of backup-rclone-sync's MAX_DELETE: a collection that lost
  # more than MAX_SHRINK_PERCENT of its objects since the previous export, or
  # vanished, is far more often an accident than a cleanup.
  if [[ -r "$final/manifest.tsv" ]]; then
    local problems="" kindw what o nw
    problems="$(manifest_compare "$final/manifest.tsv" "$new/manifest.tsv" "$MAX_SHRINK_PERCENT")"
    if [[ -n "$problems" ]]; then
      while IFS="$(printf '\t')" read -r what kindw uri o nw; do
        [[ "$kindw" == addressbook ]] && kindw="address book"
        if [[ "$what" == gone ]]; then
          what="$kindw '$uri' is gone (it held $o objects)"
        else
          what="$kindw '$uri' shrank from $o to $nw objects (more than ${MAX_SHRINK_PERCENT}%)"
        fi
        if is_truthy "$ACCEPT_SHRINK"; then
          log WARN "${P}$what — accepted (ACCEPT_SHRINK=true)"
        else
          log ERROR "${P}$what — trend guard"
        fi
      done <<< "$problems"
      if ! is_truthy "$ACCEPT_SHRINK"; then
        rm -rf "$new"
        log ERROR "${P}the previous export stays in place. If the cleanup was deliberate, set ACCEPT_SHRINK=true in $conf for one run."
        exit 1
      fi
    fi
  fi

  # --- 5. swap -------------------------------------------------------------
  # Two renames inside STAGING_BASE. Between them no export exists under the
  # account's name for a moment, and a reader that comes then finds no marker
  # and waits for the next night — which is the safe side.
  if [[ -e "$final" ]]; then
    mv "$final" "$old" || { rm -rf "$new"; log ERROR "${P}cannot move the previous export aside ($final -> $old)"; exit 1; }
  fi
  if ! mv "$new" "$final"; then
    log ERROR "${P}cannot move the new export into place ($new -> $final)"
    [[ -e "$old" ]] && mv "$old" "$final" && log ERROR "${P}the previous export was put back"
    exit 1
  fi
  rm -rf "$old"

  printf 'collections=%d\nobjects=%d\nvevents=%d\nvtodos=%d\ncards=%d\nbytes=%d\n' \
    "$t_coll" "$t_obj" "$t_ev" "$t_td" "$t_cards" "$t_bytes" >> "$result"
  exit 0
}

# ---------------------------------------------------------------------------
# 8. Start
# ---------------------------------------------------------------------------

log_info "Starting DAV export run on $HOSTNAME_SHORT"
log_rotate "$LOG_DIR" "dav-export" "$LOG_RETENTION_DAYS"

instances_load "$INSTANCES_DIR" reset_account_vars validate_account \
  "${SELECTED_ACCOUNTS[@]+"${SELECTED_ACCOUNTS[@]}"}"

if [[ "$ACTION" == "list" ]]; then
  log_info "--- Configured accounts (${#INSTANCE_NAMES[@]}) ---"
  for idx in "${!INSTANCE_NAMES[@]}"; do
    log_plain "  ${INSTANCE_NAMES[$idx]}  ${ACCOUNT_USERS[$idx]} @ ${ACCOUNT_URLS[$idx]} -> ${INSTANCE_OUTDIRS[$idx]}"
  done
  run_end 0
fi

check_binaries

if [[ "$DRY_RUN" -eq 1 ]]; then
  log_warn "DRY RUN ($DRY_RUN_SOURCE) — collections are discovered and counted on the server; nothing is downloaded and no marker is touched"
fi
if [[ "${#SELECTED_ACCOUNTS[@]}" -gt 0 ]]; then
  log_info "Partial run (--instance ${SELECTED_ACCOUNTS[*]}) — only these accounts and their markers are touched"
fi

acquire_lock || run_end 1

# What the export writes is 0640 / directories 0750 (STAGING_UMASK): it holds
# private appointments and contacts. A consumer gets in via STAGING_GROUP. Set
# after the log file was created, which stays world-readable on purpose.
umask "$STAGING_UMASK"

# Where the workers keep their downloads of the PROPFINDs and leave their
# results for the run level. mktemp keeps it out of logs/, so a run that dies
# leaves no stray files next to the logs.
STATS_DIR="$(mktemp -d 2>/dev/null)" || STATS_DIR="$LOG_DIR/.stats.$$"
mkdir -p "$STATS_DIR" || fatal "Cannot create the working directory $STATS_DIR"

# ---------------------------------------------------------------------------
# 9. Accounts
# ---------------------------------------------------------------------------

log_info "--- Accounts ---"
run_worker_loop export_one_account

# ---------------------------------------------------------------------------
# 10. Completion markers
#
# One per account that was exported without error — the marker vouches for that
# one account, not for the run, so a failed account does not withhold the
# markers of the others, and a partial run (--instance) writes them for exactly
# the accounts it touched. A failed account keeps its older export and marker: a
# reader judges by age, and yesterday's export is still yesterday's good export.
# ---------------------------------------------------------------------------

r() {
  # r <key> — a value the worker left in $result, 0 if it left none.
  marker_value "$result" "$1" || printf '0'
}

marker_written=0
marker_failed=0
sum_coll=0
sum_obj=0
for idx in "${!INSTANCE_NAMES[@]}"; do
  name="${INSTANCE_NAMES[$idx]}"
  contains "$name" "${OK_INSTANCES[@]+"${OK_INSTANCES[@]}"}" || continue
  [[ "$DRY_RUN" -eq 0 ]] || continue
  result="$STATS_DIR/$idx.result"
  sum_coll=$((sum_coll + $(r collections)))
  sum_obj=$((sum_obj + $(r objects)))
  if [[ -z "$MARKER_NAME" ]]; then
    continue
  fi
  if write_marker "$STAGING_BASE/$name/$MARKER_NAME" "$STAGING_GROUP" "dav-export" \
       "account=${ACCOUNT_USERS[$idx]}" \
       "server=$(dav_url_host "${ACCOUNT_URLS[$idx]}")" \
       "collections=$(r collections)" \
       "objects=$(r objects)" \
       "vevents=$(r vevents)" \
       "vtodos=$(r vtodos)" \
       "cards=$(r cards)" \
       "bytes=$(r bytes)"; then
    marker_written=$((marker_written + 1))
  else
    marker_failed=$((marker_failed + 1))
  fi
done

# shellcheck disable=SC2034  # MARKER_NOTE and RUN_EXTRA are read by lib/runlib's run_finish.
{
  total="${#INSTANCE_NAMES[@]}"
  if [[ -z "$MARKER_NAME" ]]; then
    MARKER_NOTE="disabled (MARKER_NAME is empty)"
  elif [[ "$DRY_RUN" -eq 1 ]]; then
    MARKER_NOTE="not written (dry run) — existing markers still apply"
  elif [[ "$marker_failed" -gt 0 ]]; then
    MARKER_NOTE="written for $marker_written of $total accounts, $marker_failed could NOT be written"
  elif [[ "$marker_written" -lt "$total" ]]; then
    MARKER_NOTE="written for $marker_written of $total accounts — a failed account keeps its older marker"
  else
    MARKER_NOTE="written for all $total accounts"
  fi
  # State the scope: a summary that never names it cannot show that something
  # fell out of it.
  [[ "$DRY_RUN" -eq 0 ]] && RUN_EXTRA="Collections: $sum_coll, objects: $sum_obj"$'\n'
}

rm -rf "$STATS_DIR"

# ---------------------------------------------------------------------------
# 11. Completion
# ---------------------------------------------------------------------------

[[ "$DRY_RUN" -eq 1 ]] && RUN_WHAT="$RUN_WHAT [DRY RUN]"
run_finish
