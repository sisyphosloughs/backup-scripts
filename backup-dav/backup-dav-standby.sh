#!/usr/bin/env bash
#
# backup-dav-standby.sh — mirrors the exports of backup-dav.sh into Baïkal on
# this host, one Baïkal principal per account: the warm standby that clients
# can be pointed at when Nextcloud is gone.
#
# This is a CONSUMER, like a backup-rclone-sync mirror with SOURCE_MARKER: it
# reads what the export left in staging and touches the standby only when the
# export's completion marker is there and fresh. A failed export therefore
# never reaches the standby — it keeps yesterday's state, and the error shows
# up here as well once the marker is too old.
#
# Per account and collection:
#   - a collection the export holds and Baïkal does not is created (with its
#     display name); one Baïkal holds and the export does not is only
#     reported, never deleted;
#   - the export is split into one object per UID, and only what differs is
#     sent: Baïkal's etag is the md5 of what it stored, so an unchanged object
#     costs nothing. Objects gone from the export are deleted — more than
#     MAX_DELETE in one collection, and that collection fails before anything
#     is deleted;
#   - afterwards the collection must hold exactly as many objects as the
#     export.
#
# The standby follows deletions within a night: it is NOT a backup. The
# history is in restic.
#
# In an emergency, while clients write into Baïkal, STANDBY_FREEZE_FILE stops
# every sync (and reports that as an error every night) — see baikal/README.md.
#
# Nothing is hard-coded here; every path, URL and switch comes from:
#   global.conf               run-wide switches (Baïkal URL, staging, guards, …)
#   instances/<account>.conf  one file per account, shared with backup-dav.sh
#   lib/dav-lib.sh            the DAV helpers — the domain library
#   ../lib/runlib/            the shared run skeleton
# The log directory, and with it logs/.lock, is shared with backup-dav.sh: an
# export and a standby sync never run at the same time.

set -uo pipefail

# ---------------------------------------------------------------------------
# 1. Initialisation
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Per-account records, index-parallel with runlib's INSTANCE_NAMES; appended by
# validate_account() exactly when it accepts an account.
ACCOUNT_PRINCIPALS=()
ACCOUNT_NETRCS=()

# ---------------------------------------------------------------------------
# 2. Command line
# ---------------------------------------------------------------------------

SELECTED_ACCOUNTS=()
ACTION="sync"
CLI_DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: backup-dav-standby.sh [options]

Mirrors the latest export of every account configured in instances/*.conf
(STANDBY=true) into its Baïkal principal: creates missing collections, sends
new and changed objects, deletes objects gone from the export, and checks the
count afterwards. Refuses an account whose export marker is missing or stale,
and does nothing at all while the standby is frozen (STANDBY_FREEZE_FILE).

Options:
  -i, --instance NAME  Mirror only this account (repeatable).
  -n, --dry-run        Compare with Baïkal and log what would be created, sent
                       and deleted; change nothing.
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
# 3. Libraries — runlib first, then the domain library (see backup-dav.sh)
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
# 4. Log file — before the configuration, so its errors are logged too
# ---------------------------------------------------------------------------

LOG_DIR="$SCRIPT_DIR/logs"
run_init "$LOG_DIR" "dav-standby" \
  || { echo "FATAL: cannot create the log file in $LOG_DIR" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 5. Configuration
# ---------------------------------------------------------------------------

GLOBAL_CONF="$SCRIPT_DIR/global.conf"
[[ -f "$GLOBAL_CONF" ]] \
  || fatal "Global configuration not found: $GLOBAL_CONF (copy global.conf.example and adjust it)"
# shellcheck source=/dev/null
source "$GLOBAL_CONF"

: "${CURL_BIN:=curl}"
: "${INSTANCES_DIR:=$SCRIPT_DIR/instances}"
: "${STAGING_BASE:=}"
: "${MARKER_NAME:=.complete}"
: "${CURL_CONNECT_TIMEOUT:=20}"
: "${CURL_MAX_TIME:=600}"
: "${MAX_SHRINK_PERCENT:=20}"
: "${LOG_RETENTION_DAYS:=64}"
: "${BAIKAL_URL:=}"
: "${BAIKAL_AUTH:=digest}"
: "${MARKER_MAX_AGE_HOURS:=26}"
: "${MAX_DELETE:=50}"
: "${STANDBY_FREEZE_FILE:=}"

DRY_RUN=0
[[ "$CLI_DRY_RUN" -eq 1 ]] && DRY_RUN=1

[[ -n "$STAGING_BASE" ]] || fatal "STAGING_BASE is not set (global.conf) — the standby reads the exports from there"
[[ "$STAGING_BASE" == /* ]] || fatal "STAGING_BASE must be an absolute path (global.conf): '$STAGING_BASE'"
STAGING_BASE="${STAGING_BASE%/}"
# The marker is the only proof that an export is complete; without it the
# standby could mirror a failed or half-written export.
[[ -n "$MARKER_NAME" ]] \
  || fatal "MARKER_NAME is empty (global.conf) — the standby needs the export's completion marker to know an export is complete"
BAIKAL_URL="${BAIKAL_URL%/}"
case "$BAIKAL_URL" in
  http://*|https://*) ;;
  "") fatal "BAIKAL_URL is not set (global.conf)" ;;
  *) fatal "BAIKAL_URL must start with http:// or https:// (global.conf): '$BAIKAL_URL'" ;;
esac
case "$BAIKAL_AUTH" in
  digest|basic) ;;
  *) fatal "BAIKAL_AUTH must be 'digest' or 'basic' (global.conf): '$BAIKAL_AUTH'" ;;
esac
for v in CURL_CONNECT_TIMEOUT CURL_MAX_TIME MARKER_MAX_AGE_HOURS MAX_DELETE MAX_SHRINK_PERCENT; do
  [[ "${!v}" =~ ^[0-9]+$ ]] || fatal "$v must be a number (global.conf): '${!v}'"
done

# The global value is the per-account default (dav_account_reset).
# shellcheck disable=SC2034  # read by dav_account_reset in the library.
DEFAULT_MAX_SHRINK_PERCENT="$MAX_SHRINK_PERCENT"
# shellcheck disable=SC2034  # read by dav_request / dav_sync_collection.
{
  DAV_AUTH="$BAIKAL_AUTH"
  DAV_DRY_RUN="$DRY_RUN"
}
BAIKAL_HOST="$(dav_url_host "$BAIKAL_URL")"

# ---------------------------------------------------------------------------
# 5b. What this run calls things
# ---------------------------------------------------------------------------

# shellcheck disable=SC2034  # every name here is read by lib/runlib, not below.
{
  RUN_WHAT="DAV standby"
  RUN_LOG_NAME="DAV standby run"
  RUN_UNIT="Accounts"
  RUN_OK_VERB="standby in sync"
  [[ "$DRY_RUN" -eq 1 ]] && RUN_OK_VERB="dry run ok, nothing changed"
  RUN_ABORT_HINT="A standby principal may be half-synced; the next run completes it."
  RUN_USES_MARKER=0
  RUN_BYTES_FN="standby_bytes"
  INSTANCE_LABEL="Account"
  INSTANCE_LABEL_LC="account"
  INSTANCE_OPT="--instance"
}

notify_init

# ---------------------------------------------------------------------------
# 6. trap handler — nothing to roll back: every object is sent on its own,
# and the next run sends whatever an interrupted one did not
# ---------------------------------------------------------------------------

run_traps

# ---------------------------------------------------------------------------
# 7. Helper functions
# ---------------------------------------------------------------------------

reset_account_vars() {
  # The same per-account variables and defaults as backup-dav.sh.
  dav_account_reset "$@"
}

validate_account() {
  # validate_account <name> <conf> — runlib's per-object hook. Only what the
  # standby needs is checked here; the export checks the Nextcloud side.
  local name="$1" conf="$2" principal

  if ! is_truthy "$STANDBY"; then
    log_info "Account '$name': STANDBY is not true — not mirrored"
    return 1
  fi
  principal="${STANDBY_USER:-${DAV_USER:-$name}}"
  case "$principal" in
    */*|*' '*) log_error "Account '$name': Baïkal principal '$principal' contains '/' or a space — skipped"; return 1 ;;
  esac
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
  if ! netrc_has_machine "$NETRC_FILE" "$BAIKAL_HOST"; then
    log_error "Account '$name': NETRC_FILE has no 'machine $BAIKAL_HOST' entry (the bare host of BAIKAL_URL) for the Baïkal password: $NETRC_FILE — skipped"
    return 1
  fi

  ACCOUNT_PRINCIPALS+=("$principal")
  ACCOUNT_NETRCS+=("$NETRC_FILE")
  instances_record "$STAGING_BASE/$name" "$name"
  log_info "Account '$name': $STAGING_BASE/$name -> Baïkal principal '$principal'"
  return 0
}

check_binaries() {
  log_info "--- Checking programs ---"
  local p
  if p="$(command -v "$CURL_BIN" 2>/dev/null)"; then
    log_info "curl found: $p ($("$CURL_BIN" --version 2>/dev/null | head -n1 | cut -d' ' -f1-2))"
  else
    fatal "curl not found: '$CURL_BIN'. Set CURL_BIN in global.conf to the absolute path (e.g. /usr/bin/curl)."
  fi
  notify_check_binaries
}

check_frozen() {
  # Ends the run with an error while STANDBY_FREEZE_FILE exists: clients are
  # writing into Baïkal, and a sync would overwrite their work with the
  # export. Red every night on purpose, so the emergency cannot be forgotten.
  # A dry run changes nothing and may go on.
  local f="$STANDBY_FREEZE_FILE" dir since
  if [[ -z "$f" ]]; then
    log_warn "STANDBY_FREEZE_FILE is empty (global.conf) — the standby cannot be frozen for an emergency"
    return 0
  fi
  dir="$(dirname "$f")"
  if [[ ! -d "$dir" ]]; then
    log_warn "The directory of STANDBY_FREEZE_FILE does not exist ($dir) — the standby cannot be frozen for an emergency"
    return 0
  fi
  if [[ ! -x "$dir" ]]; then
    # Cannot look — and a freeze that cannot be seen must not be ignored.
    log_error "Cannot check the freeze file: $dir is not accessible for user '$(id -un)' — nothing is synced"
    run_finish
  fi
  [[ -e "$f" ]] || return 0
  since="$(date -r "$f" '+%Y-%m-%d %H:%M' 2>/dev/null)" || since="?"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_warn "Standby frozen since $since ($f) — dry run only, nothing would be changed anyway"
    return 0
  fi
  log_error "Standby frozen since $since ($f exists) — nothing is synced, so what clients wrote into Baïkal stays. Delete the file after the failback (baikal/README.md)."
  # shellcheck disable=SC2034  # read by lib/runlib's run_finish.
  RUN_EXTRA="Standby FROZEN since $since"$'\n'
  run_finish
}

check_baikal() {
  # Baïkal must answer at BAIKAL_URL and must ask for credentials: without
  # them, 401. Anything else — no answer, the setup wizard's redirect, or an
  # answer without asking — and no account is touched.
  local tmp resp rc=0 code
  tmp="$STATS_DIR/baikal-check.xml"
  resp="$(DAV_LOG_REQUESTS=0 dav_request PROPFIND "$BAIKAL_URL/" /dev/null "$tmp" --header "Depth: 0")" || rc=$?
  code="${resp%% *}"
  if [[ "$rc" -ne 0 ]]; then
    log_error "Baïkal does not answer at $BAIKAL_URL (curl exit $rc: $(curl_rc_text "$rc")) — is the container running? Nothing synced."
    return 1
  fi
  case "$code" in
    401)
      log_info "Baïkal answers at $BAIKAL_URL and asks for credentials"
      return 0 ;;
    2*)
      log_error "Baïkal answers WITHOUT credentials (HTTP $code) at $BAIKAL_URL — refusing to write private data into it. Nothing synced."
      return 1 ;;
    30*)
      log_error "Baïkal answers HTTP $code at $BAIKAL_URL instead of 401 — is the setup wizard not completed? Nothing synced."
      return 1 ;;
    *)
      log_error "Baïkal answers HTTP $code ($(http_text "$code")) at $BAIKAL_URL, expected 401 — nothing synced"
      return 1 ;;
  esac
}

standby_bytes() {
  # standby_bytes <name> <index> <outdir> — runlib's RUN_BYTES_FN: what the
  # worker sent to Baïkal.
  marker_value "$STATS_DIR/$2.result" bytes 2>/dev/null || printf '0'
}

# --- per-account sync -------------------------------------------------------

sync_one_account() {
  # sync_one_account <name> <conf> <index> — runlib's worker, in a SUBSHELL
  # (see backup-dav.sh). Logs through the library's log(); what the run level
  # needs goes into $STATS_DIR/<index>.result.
  local name="$1" conf="$2" idx="$3"
  local principal="${ACCOUNT_PRINCIPALS[$idx]}" netrc="${ACCOUNT_NETRCS[$idx]}"
  local P="Account '$name': "
  # shellcheck disable=SC2034  # read by runlib's cmd_run.
  local CMD_PREFIX="$P"
  local staging="$STAGING_BASE/$name" work="$STATS_DIR/$idx" result="$STATS_DIR/$idx.result"
  local marker manifest age at gen resp rc code kind kw seg home homepath href types dn uri
  local url file stats objs new chg del same sent rewr n i msg failed=0 found
  local t_coll=0 t_obj=0 t_new=0 t_chg=0 t_del=0 t_bytes=0
  local m_kinds=() m_uris=() m_names=() m_objs=()
  local e_kinds=() e_uris=() e_names=()
  local would=""
  [[ "$DRY_RUN" -eq 1 ]] && would="would be "

  reset_account_vars "$name"
  # shellcheck source=/dev/null
  source "$conf" || { log ERROR "${P}cannot read $conf"; exit 1; }

  : > "$result"
  mkdir -p "$work" || { log ERROR "${P}cannot create the working directory $work"; exit 1; }

  # --- 1. the export: complete and fresh? ----------------------------------
  marker="$staging/$MARKER_NAME"
  if [[ ! -r "$marker" ]]; then
    log ERROR "${P}no completion marker $marker — no complete export yet (or not readable for '$(id -un)'); standby left as it is"
    exit 1
  fi
  gen="$(marker_value "$marker" generator)" || gen=""
  if [[ "$gen" != "dav-export" ]]; then
    log ERROR "${P}the marker $marker says generator='$gen', expected 'dav-export' — standby left as it is"
    exit 1
  fi
  if ! age="$(marker_age "$marker")"; then
    log ERROR "${P}the marker $marker has no usable completed_epoch — standby left as it is"
    exit 1
  fi
  at="$(marker_value "$marker" completed_at)" || at="?"
  if [[ "$age" -gt $((MARKER_MAX_AGE_HOURS * 3600)) ]]; then
    log ERROR "${P}the last complete export is $((age / 3600))h old (completed_at=$at), older than MARKER_MAX_AGE_HOURS=$MARKER_MAX_AGE_HOURS — the export is failing; standby left as it is"
    exit 1
  fi
  manifest="$staging/manifest.tsv"
  if [[ ! -r "$manifest" ]]; then
    log ERROR "${P}$manifest missing although the marker is there — standby left as it is"
    exit 1
  fi
  log INFO "${P}export of $at ($((age / 60)) min old)"
  while IFS="$(printf '\t')" read -r kind uri dn _ objs _; do
    m_kinds+=("$kind"); m_uris+=("$uri"); m_names+=("$dn"); m_objs+=("$objs")
  done < <(manifest_rows "$manifest")

  # --- 2. the principal ----------------------------------------------------
  rc=0
  resp="$(dav_propfind "$BAIKAL_URL/principals/$principal/" "$netrc" 0 "$DAV_PROPFIND_COLLECTIONS" "$work/principal.xml")" || rc=$?
  code="${resp%% *}"
  if [[ "$rc" -ne 0 ]]; then
    log ERROR "${P}Baïkal unreachable (curl exit $rc: $(curl_rc_text "$rc"))"; exit 1
  fi
  case "$code" in
    207) ;;
    401) log ERROR "${P}Baïkal refused the login of '$principal' (HTTP 401) — check the 'machine $BAIKAL_HOST' line in $netrc"; exit 1 ;;
    404) log ERROR "${P}Baïkal has no principal '$principal' — create it in the admin UI (baikal/README.md, setup step 8)"; exit 1 ;;
    *)   log ERROR "${P}the principal '$principal' answered HTTP $code ($(http_text "$code")), expected 207"; exit 1 ;;
  esac

  # --- 3. what Baïkal holds --------------------------------------------------
  for kind in calendar addressbook; do
    if [[ "$kind" == calendar ]]; then seg="calendars"; kw="calendar"; else seg="addressbooks"; kw="address book"; fi
    home="$BAIKAL_URL/$seg/$principal/"
    homepath="$(dav_url_path "$home")"
    rc=0
    resp="$(dav_propfind "$home" "$netrc" 1 "$DAV_PROPFIND_COLLECTIONS" "$work/home.$kind.xml")" || rc=$?
    code="${resp%% *}"
    if [[ "$rc" -ne 0 || "$code" != 207 ]]; then
      log ERROR "${P}listing the $kw home failed (curl exit $rc, HTTP $code)"; exit 1
    fi
    while IFS="$(printf '\t')" read -r href types dn _; do
      [[ -n "$href" ]] || continue
      [[ "${href%/}/" == "${homepath%/}/" ]] && continue
      uri="$(dav_href_uri "$href")"
      # inbox, outbox and anything that is not a calendar/address book.
      dav_skip_reason "$kind" "$uri" "$types" 1 >/dev/null && continue
      e_kinds+=("$kind"); e_uris+=("$uri"); e_names+=("$dn")
    done < <(ms_responses "$work/home.$kind.xml")
  done

  # --- 4. each collection of the export ------------------------------------
  for i in "${!m_uris[@]}"; do
    kind="${m_kinds[$i]}"; uri="${m_uris[$i]}"; dn="${m_names[$i]}"
    if [[ "$kind" == calendar ]]; then seg="calendars"; kw="calendar"; file="$staging/calendars/$uri.ics"
    else seg="addressbooks"; kw="address book"; file="$staging/addressbooks/$uri.vcf"
    fi
    url="$BAIKAL_URL/$seg/$principal/$uri/"
    if [[ ! -r "$file" ]]; then
      log ERROR "${P}$kw '$uri': $file missing although the manifest lists it"
      failed=1; continue
    fi

    found=""
    for n in "${!e_uris[@]}"; do
      if [[ "${e_kinds[$n]}" == "$kind" && "${e_uris[$n]}" == "$uri" ]]; then found="$n"; break; fi
    done
    if [[ -z "$found" ]]; then
      if [[ "$DRY_RUN" -eq 1 ]]; then
        log INFO "${P}$kw '$uri' would be created in Baïkal"
      else
        rc=0
        resp="$(dav_mkcollection "$kind" "$url" "$netrc" "$dn" "$work/mk.out")" || rc=$?
        code="${resp%% *}"
        if [[ "$rc" -ne 0 || "$code" != 201 ]]; then
          msg="$(dav_error_text "$work/mk.out")"
          log ERROR "${P}$kw '$uri' could not be created (curl exit $rc, HTTP $code $(http_text "$code"))${msg:+: $msg}"
          failed=1; continue
        fi
        log INFO "${P}$kw '$uri' created in Baïkal"
      fi
    elif [[ "$dn" != "-" && "${e_names[$found]}" != "$dn" ]]; then
      # Renamed in Nextcloud: follow the display name.
      if [[ "$DRY_RUN" -eq 1 ]]; then
        log INFO "${P}$kw '$uri' would be renamed to '$dn'"
      else
        rc=0
        resp="$(dav_set_displayname "$url" "$netrc" "$dn" "$work/pp.out")" || rc=$?
        code="${resp%% *}"
        if [[ "$rc" -ne 0 || "$code" != 207 ]]; then
          log WARN "${P}$kw '$uri': display name not updated (curl exit $rc, HTTP $code)"
        else
          log INFO "${P}$kw '$uri' renamed to '$dn'"
        fi
      fi
    fi

    rc=0
    stats="$(dav_sync_collection "${P}$kw '$uri'" "$url" "$netrc" "$kind" "$file" \
               "${m_objs[$i]}" "$MAX_DELETE" "$work/c")" || rc=$?
    rm -rf "$work/c"
    # Nothing to report beyond the error: no stats at all, or refused by
    # MAX_DELETE before anything was changed.
    if [[ -z "$stats" || "$rc" -eq 2 ]]; then
      failed=1; continue
    fi
    read -r objs new chg del same sent rewr <<< "$stats"
    log INFO "${P}$kw '$uri' — $objs objects: ${would}$new new, $chg changed, $del deleted; $same unchanged"
    if [[ "$rewr" -gt 0 ]]; then
      log WARN "${P}$kw '$uri': Baïkal stored $rewr object(s) differently from what was sent (it repaired them) — they are sent again every night"
    fi
    [[ "$rc" -eq 0 ]] || failed=1
    t_coll=$((t_coll + 1)); t_obj=$((t_obj + objs)); t_new=$((t_new + new))
    t_chg=$((t_chg + chg)); t_del=$((t_del + del)); t_bytes=$((t_bytes + sent))
  done

  # --- 5. what Baïkal holds beyond the export -------------------------------
  for n in "${!e_uris[@]}"; do
    found=""
    for i in "${!m_uris[@]}"; do
      if [[ "${m_kinds[$i]}" == "${e_kinds[$n]}" && "${m_uris[$i]}" == "${e_uris[$n]}" ]]; then found=1; break; fi
    done
    [[ -n "$found" ]] && continue
    kw="calendar"; [[ "${e_kinds[$n]}" == addressbook ]] && kw="address book"
    log WARN "${P}$kw '${e_uris[$n]}' is in Baïkal but not in the export — left as it is (the standby never deletes a collection; delete it in the admin UI if it is not needed)"
  done

  printf 'collections=%d\nobjects=%d\nnew=%d\nchanged=%d\ndeleted=%d\nbytes=%d\n' \
    "$t_coll" "$t_obj" "$t_new" "$t_chg" "$t_del" "$t_bytes" >> "$result"
  if [[ "$failed" -ne 0 ]]; then
    log ERROR "${P}not every collection is in sync"
    exit 1
  fi
  exit 0
}

# ---------------------------------------------------------------------------
# 8. Start
# ---------------------------------------------------------------------------

log_info "Starting DAV standby run on $HOSTNAME_SHORT"
log_rotate "$LOG_DIR" "dav-standby" "$LOG_RETENTION_DAYS"

instances_load "$INSTANCES_DIR" reset_account_vars validate_account \
  "${SELECTED_ACCOUNTS[@]+"${SELECTED_ACCOUNTS[@]}"}"

if [[ "$ACTION" == "list" ]]; then
  log_info "--- Configured accounts (${#INSTANCE_NAMES[@]}) ---"
  for idx in "${!INSTANCE_NAMES[@]}"; do
    log_plain "  ${INSTANCE_NAMES[$idx]}  ${INSTANCE_OUTDIRS[$idx]} -> $BAIKAL_URL/ principal ${ACCOUNT_PRINCIPALS[$idx]}"
  done
  run_end 0
fi

check_binaries

if [[ "$DRY_RUN" -eq 1 ]]; then
  log_warn "DRY RUN (--dry-run) — Baïkal is compared with the exports; nothing is created, sent or deleted"
fi
if [[ "${#SELECTED_ACCOUNTS[@]}" -gt 0 ]]; then
  log_info "Partial run (--instance ${SELECTED_ACCOUNTS[*]})"
fi

acquire_lock || run_end 1

# The split objects are private appointments and contacts.
umask 0077
STATS_DIR="$(mktemp -d 2>/dev/null)" || STATS_DIR="$LOG_DIR/.stats.$$"
mkdir -p "$STATS_DIR" || fatal "Cannot create the working directory $STATS_DIR"

check_frozen
if ! check_baikal; then
  rm -rf "$STATS_DIR"
  run_finish
fi

# ---------------------------------------------------------------------------
# 9. Accounts
# ---------------------------------------------------------------------------

log_info "--- Accounts ---"
run_worker_loop sync_one_account

r() { marker_value "$result" "$1" || printf '0'; }
sum_coll=0; sum_obj=0; sum_new=0; sum_chg=0; sum_del=0
for idx in "${!INSTANCE_NAMES[@]}"; do
  result="$STATS_DIR/$idx.result"
  [[ -r "$result" ]] || continue
  sum_coll=$((sum_coll + $(r collections))); sum_obj=$((sum_obj + $(r objects)))
  sum_new=$((sum_new + $(r new))); sum_chg=$((sum_chg + $(r changed))); sum_del=$((sum_del + $(r deleted)))
done
# shellcheck disable=SC2034  # read by lib/runlib's run_finish.
{
  if [[ "$DRY_RUN" -eq 1 ]]; then
    RUN_EXTRA="Collections: $sum_coll, objects: $sum_obj — would be $sum_new new, $sum_chg changed, $sum_del deleted"$'\n'
    RUN_WHAT="$RUN_WHAT [DRY RUN]"
  else
    RUN_EXTRA="Collections: $sum_coll, objects: $sum_obj — $sum_new new, $sum_chg changed, $sum_del deleted"$'\n'
  fi
}

rm -rf "$STATS_DIR"

# ---------------------------------------------------------------------------
# 10. Completion
# ---------------------------------------------------------------------------

run_finish
