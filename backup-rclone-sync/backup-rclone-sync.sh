#!/usr/bin/env bash
#
# backup-rclone-sync.sh — mirrors directory trees between this host and
# somewhere else with rclone, one mirror per configured instance.
#
# Either side of a mirror may be a local path or an rclone remote, so the same
# script covers the two jobs the collection was missing: pulling another host's
# tree (its tar archives, its database dumps, a share) into a local staging
# directory that backup-restic then backs up — and pushing a local tree (the
# tar archives, say) to a cloud that speaks no SSH. What a mirror is, follows
# from where its destination lies:
#
#   destination local   a PRODUCER, like backup-docker-db and backup-tar: after
#                       an error-free mirror it writes a completion marker into
#                       the destination, for whatever consumes the tree next;
#   destination remote  a CONSUMER, like backup-restic: it writes no marker.
#
# A mirror has NO retention of its own. "sync" makes the destination a mirror
# of the source, deletions included; what is kept for how long is decided
# where the data is produced (backup-tar's ARCHIVE_RETENTION_DAYS) or where its
# history lives (backup-restic's forget). The flip side — a source that is
# suddenly empty because a share was not mounted would empty the destination
# too — is what MAX_DELETE and SOURCE_MARKER are for; see instances.conf.example.
#
# Nothing is hard-coded here; every path, remote and switch comes from:
#   global.conf              run-wide switches (rclone, staging, Telegram, …)
#   instances/<name>.conf    one file per mirror — a new mirror needs no change
#                            to this script
#   lib/rclone-sync-lib.sh   the rclone helpers (log filter, marker fetch,
#                            statistics) — the domain library
#   ../lib/runlib/           the shared run skeleton (log file, error account,
#                            lock, configuration loader, summary, notification,
#                            marker), the git submodule shared with the other
#                            backup scripts
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

# Per-mirror records, index-parallel with runlib's INSTANCE_NAMES/INSTANCE_CONFS.
# They are appended by validate_mirror() exactly when it accepts a mirror, so
# the indices stay aligned; sync_one_mirror() and the marker step read them by
# index.
MIRROR_SOURCES=()
MIRROR_DESTS=()
MIRROR_MODES=()
MIRROR_DEST_LOCAL=()   # 1 if the destination is a local path (marker candidate)

# Whether any mirror touches a remote at all (set by validate_mirror, read by
# check_rclone_config) — a host that only mirrors volume to volume should not be
# nagged about an rclone.conf it does not need.
NEED_REMOTE=0

# ---------------------------------------------------------------------------
# 2. Command line
#
# Parsed before anything else so "--help" neither reads a configuration nor
# creates a log file.
# ---------------------------------------------------------------------------

SELECTED_MIRRORS=()
ACTION="run"
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: backup-rclone-sync.sh [options]

Mirrors every tree configured in instances/*.conf with rclone — a remote into a
local staging directory, or a local directory to a remote — and writes a
completion marker into every local destination that was mirrored without error.

Options:
  -i, --instance NAME  Mirror only this instance (repeatable). The other
                       mirrors, and their markers, are left untouched.
  -n, --dry-run        Let rclone list what it would copy and delete; nothing
                       is written and no marker is touched.
  -l, --list           List the configured mirrors and exit.
  -h, --help           Show this help and exit.

Exit code: 0 only if the run was completely error-free.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -l|--list) ACTION="list"; shift ;;
    -n|--dry-run) DRY_RUN=1; shift ;;
    -i|--instance)
      [[ $# -ge 2 ]] || { echo "FATAL: $1 requires a name" >&2; exit 2; }
      SELECTED_MIRRORS+=("$2"); shift 2 ;;
    --instance=*) SELECTED_MIRRORS+=("${1#*=}"); shift ;;
    *) echo "FATAL: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# 3. Libraries
#
# Order matters. runlib first: it provides log_info/log_error (stdout + log
# file) and everything the run skeleton needs. rclone-sync-lib.sh second,
# because it owns the bare log() that its own helpers use for their stderr-only
# diagnostics — see the header of runlib/log.sh for why the two channels must
# stay apart.
# ---------------------------------------------------------------------------

RUNLIB="$ROOT_DIR/lib/runlib/runlib.sh"
SYNC_LIB="$SCRIPT_DIR/lib/rclone-sync-lib.sh"
for lib_file in "$RUNLIB" "$SYNC_LIB"; do
  [[ -r "$lib_file" ]] || {
    echo "FATAL: library not readable: $lib_file" >&2
    echo "       (../lib/runlib is a git submodule — run 'git submodule update --init')" >&2
    exit 1
  }
done
# shellcheck source=../lib/runlib/runlib.sh
source "$RUNLIB"
# shellcheck source=lib/rclone-sync-lib.sh
source "$SYNC_LIB"

# ---------------------------------------------------------------------------
# 4. Log file
#
# Created BEFORE the configuration is read, so configuration errors also end up
# in a log file instead of vanishing on stderr. Depends only on SCRIPT_DIR.
# ---------------------------------------------------------------------------

LOG_DIR="$SCRIPT_DIR/logs"
run_init "$LOG_DIR" "rclone-sync" \
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
: "${RCLONE_BIN:=rclone}"
: "${RCLONE_CONFIG_FILE:=}"
: "${INSTANCES_DIR:=$SCRIPT_DIR/instances}"
: "${STAGING_BASE:=}"
: "${STAGING_MODE:=0750}"
: "${STAGING_GROUP:=}"
: "${STAGING_UMASK:=0027}"
: "${MARKER_NAME:=.complete}"
: "${MAX_DELETE:=100}"
: "${MARKER_MAX_AGE_HOURS:=26}"
: "${PROGRESS_INTERVAL:=30}"
: "${TRANSFERS:=}"
: "${CHECKERS:=}"
: "${BWLIMIT:=}"
: "${LOG_RETENTION_DAYS:=64}"
# shellcheck disable=SC2034  # read by fetch_source_marker in the library.
: "${RCLONE_PROBE_CONTIMEOUT:=20s}"
# shellcheck disable=SC2034
: "${RCLONE_PROBE_TIMEOUT:=45s}"
# An array cannot be defaulted with ":=" — an unset one is simply empty.
[[ "${RCLONE_GLOBAL_OPTS+x}" ]] || RCLONE_GLOBAL_OPTS=()

[[ "$MAX_DELETE" =~ ^[0-9]*$ ]] \
  || fatal "MAX_DELETE must be a number or empty (global.conf): '$MAX_DELETE'"
[[ "$MARKER_MAX_AGE_HOURS" =~ ^[0-9]+$ ]] \
  || fatal "MARKER_MAX_AGE_HOURS must be a number (global.conf): '$MARKER_MAX_AGE_HOURS'"

# The global values are the per-mirror defaults. Kept under their own names so
# an instances/<name>.conf can be reset to them before every file is sourced.
DEFAULT_MAX_DELETE="$MAX_DELETE"
DEFAULT_MARKER_MAX_AGE_HOURS="$MARKER_MAX_AGE_HOURS"

# Optional rclone configuration path. rclone does NOT reliably pick up the
# config from the RCLONE_CONFIG environment variable on every host — some builds
# fall back to /root/.config/rclone/rclone.conf regardless and fail. So the
# config is passed EXPLICITLY via "--config" on every rclone call (the library
# reads RCLONE_CONFIG_ARGS); RCLONE_CONFIG is exported as a harmless best-effort
# fallback. The same arrangement as in backup-restic.
RCLONE_CONFIG_ARGS=()
if [[ -n "$RCLONE_CONFIG_FILE" ]]; then
  if [[ -r "$RCLONE_CONFIG_FILE" ]]; then
    export RCLONE_CONFIG="$RCLONE_CONFIG_FILE"
    RCLONE_CONFIG_ARGS=(--config "$RCLONE_CONFIG_FILE")
  else
    log_error "RCLONE_CONFIG_FILE is set but not readable for user '$(id -un)': $RCLONE_CONFIG_FILE"
  fi
fi

# ---------------------------------------------------------------------------
# 5b. What this run calls things
#
# runlib runs the same skeleton for every script of the family; these are the
# words that keep THIS script's log and notification its own.
# ---------------------------------------------------------------------------

# shellcheck disable=SC2034  # every name here is read by lib/runlib, not below.
{
  RUN_WHAT="rclone sync"
  RUN_LOG_NAME="rclone sync run"
  RUN_UNIT="Mirrors"
  RUN_OK_VERB="mirror successful"
  RUN_ABORT_HINT="A mirror may be half-synced; no completion marker was written for it, an older one still applies."
  # Set for real after the instances are known: 1 if any destination is local
  # (then the run publishes markers), 0 for a push-only run.
  RUN_USES_MARKER=0
  # A mirror keeps the source's mtimes, so "files newer than the run" measures
  # nothing; the worker reports rclone's own byte count instead (mirror_bytes).
  RUN_BYTES_FN="mirror_bytes"
  INSTANCE_LABEL="Mirror"
  INSTANCE_LABEL_LC="mirror"
  INSTANCE_OPT="--instance"
  # Set by the marker step below and rendered by runlib's run_finish.
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
# cron. Nothing has to be rolled back at this level: rclone leaves no partial
# files behind (it copies to a temporary name and renames), and a mirror that
# was interrupted simply has no fresh marker.
# ---------------------------------------------------------------------------

run_traps

# ---------------------------------------------------------------------------
# 7. Helper functions
# ---------------------------------------------------------------------------

prepare_staging_dir() {
  # prepare_staging_dir <dir> — create a local destination and give it the
  # configured mode/group. Returns 1 on failure WITHOUT logging: it is called
  # from inside the per-mirror subshell, whose log channel is the library's
  # stderr log() — so the call site reports the failure.
  local dir="$1"
  mkdir -p "$dir" || return 1
  chmod "$STAGING_MODE" "$dir" || return 1
  if [[ -n "$STAGING_GROUP" ]]; then
    chgrp "$STAGING_GROUP" "$dir" || return 1
    # setgid: everything rclone creates below inherits the group, so a read-only
    # consumer can read it without this script chasing each new file.
    chmod g+s "$dir" || return 1
  fi
  return 0
}

# shellcheck disable=SC2034  # ENABLED is read by lib/runlib's loader; the rest
# by the mirror configurations sourced on top of them and by sync_one_mirror.
reset_mirror_vars() {
  # Every per-mirror variable, set to the global default. Called by runlib
  # before each instances/<name>.conf is sourced (and again inside the
  # subshell), so a value from one file never leaks into the next and every file
  # starts from the same documented state. DEST is pre-filled with the default
  # derived from the name, so the configuration can refer to it — or override
  # it outright.
  local name="${1:-}"
  SOURCE=""
  DEST="${STAGING_BASE:+${STAGING_BASE%/}/$name}"
  ENABLED="true"
  MODE="sync"
  EXCLUDES=()
  EXCLUDE_FROM=""
  SOURCE_MARKER=""
  MARKER_MAX_AGE_HOURS="$DEFAULT_MARKER_MAX_AGE_HOURS"
  MAX_DELETE="$DEFAULT_MAX_DELETE"
  RCLONE_OPTS=()
}

validate_mirror() {
  # validate_mirror <name> <conf> — runlib's per-object hook. The configuration
  # has been sourced at this point, so SOURCE/DEST carry what it said.
  #
  # A configuration that cannot be used is an ERROR, not a silent skip: it ends
  # up in ERRORS and thus in the exit code. Only an explicit ENABLED=false is a
  # deliberate skip (runlib handles that).
  local name="$1" conf="$2" skind dkind i other direction

  SOURCE="${SOURCE%/}"; DEST="${DEST%/}"
  if [[ -z "$SOURCE" ]]; then
    log_error "Mirror '$name' ($conf): SOURCE not set — skipped"
    return 1
  fi
  if [[ -z "$DEST" ]]; then
    log_error "Mirror '$name' ($conf): DEST not set and no STAGING_BASE to derive it from — skipped"
    return 1
  fi
  skind="$(spec_kind "$SOURCE")"; dkind="$(spec_kind "$DEST")"
  if [[ "$skind" == "invalid" ]]; then
    log_error "Mirror '$name': SOURCE must be an absolute path or remote:path, not '$SOURCE' — skipped"
    return 1
  fi
  if [[ "$dkind" == "invalid" ]]; then
    log_error "Mirror '$name': DEST must be an absolute path or remote:path, not '$DEST' — skipped"
    return 1
  fi
  case "$MODE" in
    sync|copy) ;;
    *) log_error "Mirror '$name': MODE must be sync or copy, not '$MODE' — skipped"; return 1 ;;
  esac
  if ! [[ "$MAX_DELETE" =~ ^[0-9]*$ ]]; then
    log_error "Mirror '$name': MAX_DELETE must be a number or empty, not '$MAX_DELETE' — skipped"
    return 1
  fi
  if ! [[ "$MARKER_MAX_AGE_HOURS" =~ ^[0-9]+$ ]]; then
    log_error "Mirror '$name': MARKER_MAX_AGE_HOURS must be a number, not '$MARKER_MAX_AGE_HOURS' — skipped"
    return 1
  fi
  if [[ -n "$EXCLUDE_FROM" && ! -r "$EXCLUDE_FROM" ]]; then
    log_error "Mirror '$name': EXCLUDE_FROM is not readable: $EXCLUDE_FROM — skipped"
    return 1
  fi

  if [[ "$skind" == "local" ]]; then
    if [[ ! -d "$SOURCE" ]]; then
      log_error "Mirror '$name': source directory does not exist: $SOURCE — skipped"
      return 1
    fi
    if [[ "$(abs_path "$SOURCE")" == "/" ]]; then
      log_error "Mirror '$name': SOURCE=\"/\" is not supported — configure the directories below it instead"
      return 1
    fi
  fi

  if [[ "$dkind" == "local" ]]; then
    if [[ "$(abs_path "$DEST")" == "/" ]]; then
      log_error "Mirror '$name': DEST=\"/\" is not supported"
      return 1
    fi
    # A mirror nested in its own source, or a source nested in its mirror, is
    # never what the configuration meant: the first copies its own copies
    # without end, the second SYNCS THE SOURCE AWAY (everything under DEST that
    # is not under SOURCE gets deleted — SOURCE included). Not a warning.
    if [[ "$skind" == "local" ]]; then
      if is_inside "$DEST" "$SOURCE"; then
        log_error "Mirror '$name': DEST lies inside SOURCE ($DEST in $SOURCE) — the mirror would mirror itself. Point DEST outside the source."
        return 1
      fi
      if is_inside "$SOURCE" "$DEST"; then
        log_error "Mirror '$name': SOURCE lies inside DEST ($SOURCE in $DEST) — a sync would delete the source. Point DEST elsewhere."
        return 1
      fi
    fi
    # Two mirrors into the same local tree, or one into a subdirectory of
    # another, would delete each other's files on every run.
    for i in "${!MIRROR_DESTS[@]}"; do
      [[ "${MIRROR_DEST_LOCAL[$i]}" -eq 1 ]] || continue
      other="${MIRROR_DESTS[$i]}"
      if is_inside "$DEST" "$other" || is_inside "$other" "$DEST"; then
        log_error "Mirror '$name': DEST $DEST overlaps the destination $other of mirror '${INSTANCE_NAMES[$i]}' — two mirrors must not share a tree. Skipped."
        return 1
      fi
    done
  fi

  [[ "$skind" == "remote" || "$dkind" == "remote" ]] && NEED_REMOTE=1

  MIRROR_SOURCES+=("$SOURCE")
  MIRROR_DESTS+=("$DEST")
  MIRROR_MODES+=("$MODE")
  if [[ "$dkind" == "local" ]]; then
    MIRROR_DEST_LOCAL+=(1)
    instances_record "$DEST" "$name"
    direction="pull (destination local, marker)"
    [[ "$skind" == "local" ]] && direction="local copy (marker)"
  else
    MIRROR_DEST_LOCAL+=(0)
    instances_record "" "$name"
    direction="push (destination remote, no marker)"
    [[ "$skind" == "remote" ]] && direction="remote to remote (no marker)"
  fi
  local guard=""
  [[ "$MODE" == "sync" && -n "$MAX_DELETE" ]] && guard=", at most $MAX_DELETE deletions"
  log_info "Mirror '$name': $SOURCE -> $DEST, $MODE, $direction${SOURCE_MARKER:+, requires source marker $SOURCE_MARKER (max ${MARKER_MAX_AGE_HOURS}h old)}$guard"
  return 0
}

check_binaries() {
  # Report the availability of the required programs at the very start, so a
  # missing or mislocated binary is obvious in the log instead of surfacing as a
  # cryptic failure halfway through.
  log_info "--- Checking programs ---"
  local p
  if p="$(command -v "$RCLONE_BIN" 2>/dev/null)"; then
    log_info "rclone found: $p ($("$RCLONE_BIN" version 2>/dev/null | head -n1))"
  else
    fatal "rclone not found: '$RCLONE_BIN'. Set RCLONE_BIN in global.conf to the absolute path (e.g. /usr/bin/rclone)."
  fi
  notify_check_binaries
}

check_rclone_config() {
  # Checks whether the user running this script (usually root) can read the
  # rclone configuration. Without a readable config, every remote is unknown to
  # rclone. Runs only if a remote is configured at all — a purely local mirror
  # needs no rclone.conf. Same check as in backup-restic.
  [[ "$NEED_REMOTE" -eq 1 ]] || return 0
  local conf_path
  conf_path="$("$RCLONE_BIN" "${RCLONE_CONFIG_ARGS[@]+"${RCLONE_CONFIG_ARGS[@]}"}" config file 2>/dev/null | tail -n 1)"
  if [[ -n "${RCLONE_CONFIG:-}" ]]; then
    log_info "rclone configuration: using RCLONE_CONFIG_FILE ($RCLONE_CONFIG)"
  fi
  if [[ -n "$conf_path" && -r "$conf_path" ]]; then
    log_info "rclone configuration readable for user '$(id -un)': $conf_path"
  else
    log_error "rclone configuration NOT readable for user '$(id -un)' (${conf_path:-no path determinable}). 'rclone config' was probably run as a different user. Set RCLONE_CONFIG_FILE in global.conf to the absolute path of the rclone.conf, or run 'rclone config' as this user. Every remote will fail."
  fi
}

mirror_bytes() {
  # mirror_bytes <name> <index> <outdir> — runlib's RUN_BYTES_FN: what the
  # worker reported for this mirror (rclone's transferred bytes), 0 if it never
  # got that far. The worker cannot set a variable across its subshell, so it
  # leaves a small key=value file that the marker parser reads back.
  local f="$STATS_DIR/$2.result"
  marker_value "$f" bytes 2>/dev/null || printf '0'
}

# --- per-mirror sync --------------------------------------------------------

sync_one_mirror() {
  # sync_one_mirror <name> <conf> <index> — runlib's worker.
  #
  # Called on the LEFT side of a pipeline, i.e. in a SUBSHELL — deliberately: a
  # failure here has to end THIS mirror and not the whole run, and the
  # per-mirror variables (including the arrays) cannot leak into the next one.
  #
  # Inside here, logging therefore goes through the library's log() (stderr,
  # captured by that pipe); log_info/log_error belong to the run level, would be
  # written to the log file a second time by the pipe, and could not report
  # anything back across the subshell boundary anyway. What the run level needs
  # to know afterwards (bytes, the source marker's values) goes into
  # $STATS_DIR/<index>.result.
  local name="$1" conf="$2" idx="$3" rc=0
  local src="${MIRROR_SOURCES[$idx]}" dest="${MIRROR_DESTS[$idx]}" mode="${MIRROR_MODES[$idx]}"
  local dest_local="${MIRROR_DEST_LOCAL[$idx]}"
  local result="$STATS_DIR/$idx.result" stats="$STATS_DIR/$idx.stats" mtmp="$STATS_DIR/$idx.marker"
  local opts=() pat age max_age src_at src_host src_gen bytes transfers deletes checks errors
  # shellcheck disable=SC2034  # read by runlib's cmd_run, which prefixes its log line with it.
  local CMD_PREFIX="${name}: "

  reset_mirror_vars "$name"
  # shellcheck source=/dev/null
  source "$conf" || { log ERROR "${name}: cannot read $conf"; exit 1; }
  # Re-pin what the run level already validated: a configuration may assign
  # SOURCE/DEST (that is where these values came from), but none of them may
  # end up different from what was checked for overlaps a moment ago.
  SOURCE="$src"; DEST="$dest"; MODE="$mode"

  : > "$result"

  # --- the source's own marker, if the configuration asks for it ---------
  # A producer (backup-tar, backup-docker-db, another mirror) leaves a marker at
  # the root of its tree only after an error-free run. Mirroring a tree whose
  # marker is missing or stale would copy a half-written state over yesterday's
  # good one — so the mirror fails instead, and the destination keeps what it
  # has.
  if [[ -n "$SOURCE_MARKER" ]]; then
    fetch_source_marker "$SOURCE" "$SOURCE_MARKER" "$mtmp" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      log ERROR "${name}: source marker ${SOURCE%/}/$SOURCE_MARKER could not be read (rclone exit $rc: $(rclone_rc_text "$rc")) — the source is unreachable or its last run did not complete; mirror refused"
      exit 1
    fi
    if ! age="$(marker_age "$mtmp")"; then
      log ERROR "${name}: source marker has no usable completed_epoch — mirror refused"
      exit 1
    fi
    max_age=$((MARKER_MAX_AGE_HOURS * 3600))
    src_at="$(marker_value "$mtmp" completed_at)" || src_at=""
    src_host="$(marker_value "$mtmp" host)" || src_host=""
    src_gen="$(marker_value "$mtmp" generator)" || src_gen=""
    if [[ "$age" -gt "$max_age" ]]; then
      log ERROR "${name}: source marker is $((age / 3600))h old (completed_at=$src_at, host=$src_host), older than MARKER_MAX_AGE_HOURS=$MARKER_MAX_AGE_HOURS — the producer did not complete; mirror refused"
      exit 1
    fi
    log INFO "${name}: source marker ok — completed_at=$src_at host=$src_host generator=$src_gen ($((age / 60)) min old)"
    printf 'source_completed_at=%s\nsource_host=%s\nsource_generator=%s\n' \
      "$src_at" "$src_host" "$src_gen" >> "$result"
  fi

  # --- the destination -----------------------------------------------------
  if [[ "$dest_local" -eq 1 ]]; then
    prepare_staging_dir "$DEST" \
      || { log ERROR "${name}: cannot prepare the destination directory $DEST"; exit 1; }
  fi

  # --- rclone's arguments --------------------------------------------------
  # sync mirrors, deletions included; copy only adds and updates. Empty source
  # directories are recreated (rclone drops them by default), so a restore gets
  # the tree back as it was, not only its files.
  opts+=(--create-empty-src-dirs)
  if [[ "$MODE" == "sync" && -n "$MAX_DELETE" ]]; then
    opts+=(--max-delete "$MAX_DELETE")
  fi
  # A local destination carries THIS script's marker at its root. rclone must
  # neither delete it (sync removes what the source lacks) nor overwrite it
  # with the source's own marker, which is read separately above and recorded
  # in ours. Patterns with a leading "/" are anchored to the root of the mirror.
  if [[ "$dest_local" -eq 1 && -n "$MARKER_NAME" ]]; then
    opts+=(--exclude "/$MARKER_NAME" --exclude "/$MARKER_NAME.tmp.*")
    if [[ -n "$SOURCE_MARKER" && "$SOURCE_MARKER" != "$MARKER_NAME" ]]; then
      opts+=(--exclude "/$SOURCE_MARKER" --exclude "/$SOURCE_MARKER.tmp.*")
    fi
  fi
  for pat in "${EXCLUDES[@]+"${EXCLUDES[@]}"}"; do
    [[ -n "$pat" ]] && opts+=(--exclude "$pat")
  done
  [[ -n "$EXCLUDE_FROM" ]] && opts+=(--exclude-from "$EXCLUDE_FROM")
  [[ -n "$TRANSFERS" ]] && opts+=(--transfers "$TRANSFERS")
  [[ -n "$CHECKERS" ]]  && opts+=(--checkers "$CHECKERS")
  [[ -n "$BWLIMIT" ]]   && opts+=(--bwlimit "$BWLIMIT")
  # Between two local paths rclone can carry mode, owner and mtime along; over
  # sftp or a cloud backend it cannot, and the flag is a no-op there.
  if [[ "$dest_local" -eq 1 && "$(spec_kind "$SOURCE")" == "local" ]]; then
    opts+=(--metadata)
  fi
  # Progress and the final counts come from rclone's JSON log: one stats object
  # per PROGRESS_INTERVAL seconds plus a final one, rendered by the library's
  # filter into one line each. 0 = only the final one.
  if [[ "$PROGRESS_INTERVAL" -gt 0 ]]; then
    opts+=(--stats "${PROGRESS_INTERVAL}s")
  else
    opts+=(--stats "24h")
  fi
  opts+=(--stats-log-level NOTICE --use-json-log)
  [[ "$DRY_RUN" -eq 1 ]] && opts+=(--dry-run)
  opts+=("${RCLONE_GLOBAL_OPTS[@]+"${RCLONE_GLOBAL_OPTS[@]}"}")
  opts+=("${RCLONE_OPTS[@]+"${RCLONE_OPTS[@]}"}")

  # --- the mirror ----------------------------------------------------------
  # rclone writes everything to stderr; the filter turns the JSON lines into log
  # lines and keeps the last stats object in $stats. PIPESTATUS[0] is rclone's
  # exit code (not the filter's) — read it on the very next line. Everything
  # ends on stderr again, which is this subshell's log channel.
  cmd_run "$RCLONE_BIN" "${RCLONE_CONFIG_ARGS[@]+"${RCLONE_CONFIG_ARGS[@]}"}" \
      "$MODE" "$SOURCE" "$DEST" "${opts[@]}" </dev/null 2>&1 \
    | rclone_log_filter "$name" "$stats" >&2
  rc="${PIPESTATUS[0]}"

  bytes="$(stats_num "$stats" bytes)"
  transfers="$(stats_num "$stats" transfers)"
  deletes="$(stats_num "$stats" deletes)"
  checks="$(stats_num "$stats" checks)"
  errors="$(stats_num "$stats" errors)"
  printf 'bytes=%s\ntransfers=%s\ndeletes=%s\nchecks=%s\n' \
    "$bytes" "$transfers" "$deletes" "$checks" >> "$result"

  if [[ "$rc" -ne 0 ]]; then
    log ERROR "${name}: rclone $MODE failed (exit $rc: $(rclone_rc_text "$rc")); $errors error(s), $transfers file(s) transferred, $deletes deleted before it stopped"
    exit "$rc"
  fi
  log INFO "${name}: $MODE ok — $transfers file(s) transferred ($(human_bytes "$bytes")), $checks unchanged, $deletes deleted"
  exit 0
}

# ---------------------------------------------------------------------------
# 8. Start
# ---------------------------------------------------------------------------

log_info "Starting rclone sync run on $HOSTNAME_SHORT"
log_rotate "$LOG_DIR" "rclone-sync" "$LOG_RETENTION_DAYS"

instances_load "$INSTANCES_DIR" reset_mirror_vars validate_mirror \
  "${SELECTED_MIRRORS[@]+"${SELECTED_MIRRORS[@]}"}"

# The run publishes markers exactly if some destination is local; a push-only
# run has nowhere to put one and says nothing about markers in its summary.
for idx in "${!INSTANCE_NAMES[@]}"; do
  [[ "${MIRROR_DEST_LOCAL[$idx]}" -eq 1 && -n "$MARKER_NAME" ]] && RUN_USES_MARKER=1
done

if [[ "$ACTION" == "list" ]]; then
  log_info "--- Configured mirrors (${#INSTANCE_NAMES[@]}) ---"
  for idx in "${!INSTANCE_NAMES[@]}"; do
    log_plain "  ${INSTANCE_NAMES[$idx]}  ${MIRROR_MODES[$idx]}  ${MIRROR_SOURCES[$idx]} -> ${MIRROR_DESTS[$idx]}"
  done
  run_end 0
fi

check_binaries
check_rclone_config

if [[ "$DRY_RUN" -eq 1 ]]; then
  log_warn "DRY RUN (--dry-run) — rclone lists what it would do; nothing is written and no marker is touched"
fi
if [[ "${#SELECTED_MIRRORS[@]}" -gt 0 ]]; then
  log_info "Partial run (--instance ${SELECTED_MIRRORS[*]}) — only these mirrors and their markers are touched"
fi

acquire_lock || run_end 1

# What rclone creates locally is written 0640 / directories 0750
# (STAGING_UMASK): a mirrored tree holds whatever the source held, so it must
# not become world-readable just because a consumer needs to read it — that
# consumer gets in via STAGING_GROUP. Set after the log file was created, which
# stays world-readable on purpose.
umask "$STAGING_UMASK"

# Where the workers leave their results for the run level. mktemp keeps it out
# of logs/, so a run that dies leaves no stray files next to the logs.
STATS_DIR="$(mktemp -d 2>/dev/null)" || STATS_DIR="$LOG_DIR/.stats.$$"
mkdir -p "$STATS_DIR" || fatal "Cannot create the working directory $STATS_DIR"

# ---------------------------------------------------------------------------
# 9. Mirrors
# ---------------------------------------------------------------------------

log_info "--- Mirrors ---"
run_worker_loop sync_one_mirror

# ---------------------------------------------------------------------------
# 10. Completion markers
#
# One per LOCAL destination that was mirrored without error — the marker vouches
# for that one tree, not for the run, so a failed mirror does not withhold the
# markers of the others, and a partial run (--instance) writes them for exactly
# the mirrors it touched. A failed mirror leaves its older marker untouched: a
# reader judges by age, and yesterday's tree is still yesterday's good tree.
#
# MARKER_NOTE is the one value this section produces: runlib's run_finish puts
# it into the closing log line and the notification.
# ---------------------------------------------------------------------------

marker_written=0
marker_failed=0
marker_candidates=0
for idx in "${!INSTANCE_NAMES[@]}"; do
  name="${INSTANCE_NAMES[$idx]}"
  [[ "${MIRROR_DEST_LOCAL[$idx]}" -eq 1 && -n "$MARKER_NAME" ]] || continue
  marker_candidates=$((marker_candidates + 1))
  contains "$name" "${OK_INSTANCES[@]+"${OK_INSTANCES[@]}"}" || continue
  [[ "$DRY_RUN" -eq 0 ]] || continue
  result="$STATS_DIR/$idx.result"
  extra=()
  for key in source_completed_at source_host source_generator; do
    if v="$(marker_value "$result" "$key")"; then extra+=("$key=$v"); fi
  done
  if write_marker "${MIRROR_DESTS[$idx]}/$MARKER_NAME" "$STAGING_GROUP" "rclone-sync" \
       "source=${MIRROR_SOURCES[$idx]}" \
       "mode=${MIRROR_MODES[$idx]}" \
       "sync_bytes=$(marker_value "$result" bytes || printf '0')" \
       "${extra[@]+"${extra[@]}"}"; then
    marker_written=$((marker_written + 1))
  else
    marker_failed=$((marker_failed + 1))
  fi
done

# shellcheck disable=SC2034  # MARKER_NOTE is read by lib/runlib's run_finish.
if [[ "$RUN_USES_MARKER" -eq 0 ]]; then
  MARKER_NOTE="none (no local destination)"
elif [[ "$DRY_RUN" -eq 1 ]]; then
  MARKER_NOTE="not written (dry run) — existing markers still apply"
elif [[ "$marker_failed" -gt 0 ]]; then
  MARKER_NOTE="written for $marker_written of $marker_candidates local mirrors, $marker_failed could NOT be written"
elif [[ "$marker_written" -lt "$marker_candidates" ]]; then
  MARKER_NOTE="written for $marker_written of $marker_candidates local mirrors — a failed mirror keeps its older marker"
else
  MARKER_NOTE="written for all $marker_candidates local mirrors"
fi

rm -rf "$STATS_DIR"

# ---------------------------------------------------------------------------
# 11. Completion
# ---------------------------------------------------------------------------

[[ "$DRY_RUN" -eq 1 ]] && RUN_WHAT="$RUN_WHAT [DRY RUN]"
run_finish
