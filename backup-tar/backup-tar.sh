#!/usr/bin/env bash
#
# backup-tar.sh — one compressed tar archive per configured path.
#
# Takes any number of paths and writes each of them into its OWN archive
# (<name>-<timestamp>.tar.gz) under a target directory that is configurable
# globally and per path. One archive per path, deliberately: a single archive
# over everything has to be unpacked as a whole to get one directory back, and
# one unreadable byte in it costs all of them at once.
#
# Nothing is hard-coded here; every path, target and switch comes from:
#   global.conf         run-wide switches (target, retention, Telegram, …)
#   instances/<name>.conf   one file per path to archive — a new path needs no
#                       change to this script
#   lib/tar-lib.sh      archive helpers (compressor, tar call, verification,
#                       retention) — the domain library
#   ../lib/runlib/      the shared run skeleton (log file, error account, lock,
#                       configuration loader, summary, notification, marker),
#                       the git submodule shared with the other backup scripts
# all relative to this script's directory, except runlib, which lives once at
# the root of the collection. See README.md.
#
# The run publishes a completion marker (BACKUP_BASE/.complete), written
# atomically and ONLY when every configured path was archived without a single
# error. That is the contract for anything downstream — a backup host pulling
# this tree, a monitoring check: a missing or stale marker means "do not use
# this directory". A partial run (--path/--source) never writes it.

set -uo pipefail

# ---------------------------------------------------------------------------
# 1. Initialisation
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# runlib is bound once, at the root of the collection. That makes this directory
# not standalone-deployable: it needs its sibling lib/.
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Per-path records, index-parallel with runlib's INSTANCE_NAMES/INSTANCE_CONFS.
# They are appended by validate_path() exactly when it accepts a path, so the
# indices stay aligned; archive_one_path() reads them by index.
PATH_SOURCES=()
PATH_DESTS=()

# What the configured paths actually need (set by check_path, evaluated by
# check_binaries) — a host that only writes .tar.gz should not be nagged about a
# missing zstd.
NEED_COMPRESSORS=()
NEED_CHECKSUM=0

# ---------------------------------------------------------------------------
# 2. Command line
#
# Parsed before anything else so "--help" neither reads a configuration nor
# creates a log file.
# ---------------------------------------------------------------------------

SELECTED_PATHS=()
ADHOC_SOURCES=()
CLI_DEST=""
ACTION="run"
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: backup-tar.sh [options]

Archives every path configured in instances/*.conf into its own compressed tar
archive under BACKUP_BASE and writes the completion marker when all of them
succeeded.

Options:
  -i, --instance NAME Archive only this configured path (repeatable). A partial
                      run NEVER writes the completion marker — use it for
                      testing a new instances/<name>.conf, not for scheduled runs.
  -s, --source DIR    Archive DIR without a configuration file (repeatable).
                      Ad-hoc mode: instances/*.conf is ignored entirely and no
                      completion marker is written. The archive is named after
                      the directory.
  -d, --dest DIR      Target directory for this run, overrides BACKUP_BASE (and
                      any per-path DEST_DIR).
  -n, --dry-run       Show what would be archived where, write nothing.
  -l, --list          List the configured paths and exit.
  -h, --help          Show this help and exit.

Exit code: 0 only if the run was completely error-free.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -l|--list) ACTION="list"; shift ;;
    -n|--dry-run) DRY_RUN=1; shift ;;
    # "--path" stays as an undocumented alias: it is what every note and
    # muscle memory on the host still says.
    -i|--instance|-p|--path)
      [[ $# -ge 2 ]] || { echo "FATAL: $1 requires a name" >&2; exit 2; }
      SELECTED_PATHS+=("$2"); shift 2 ;;
    --instance=*|--path=*) SELECTED_PATHS+=("${1#*=}"); shift ;;
    -s|--source)
      [[ $# -ge 2 ]] || { echo "FATAL: --source requires a directory" >&2; exit 2; }
      ADHOC_SOURCES+=("$2"); shift 2 ;;
    --source=*) ADHOC_SOURCES+=("${1#*=}"); shift ;;
    -d|--dest)
      [[ $# -ge 2 ]] || { echo "FATAL: --dest requires a directory" >&2; exit 2; }
      CLI_DEST="$2"; shift 2 ;;
    --dest=*) CLI_DEST="${1#*=}"; shift ;;
    *) echo "FATAL: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ "${#ADHOC_SOURCES[@]}" -gt 0 && "${#SELECTED_PATHS[@]}" -gt 0 ]]; then
  echo "FATAL: --source (ad-hoc) and --instance (configured) cannot be combined" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# 3. Libraries
#
# Order matters. runlib first: it provides log_info/log_error (stdout + log
# file) and everything the run skeleton needs. tar-lib.sh second, because it
# owns the bare log() that its own helpers use for their stderr-only
# diagnostics — see the header of runlib/log.sh for why the two channels must
# stay apart.
# ---------------------------------------------------------------------------

RUNLIB="$ROOT_DIR/lib/runlib/runlib.sh"
TAR_LIB="$SCRIPT_DIR/lib/tar-lib.sh"
for lib_file in "$RUNLIB" "$TAR_LIB"; do
  [[ -r "$lib_file" ]] || {
    echo "FATAL: library not readable: $lib_file" >&2
    echo "       (../lib/runlib is a git submodule — run 'git submodule update --init')" >&2
    exit 1
  }
done
# shellcheck source=../lib/runlib/runlib.sh
source "$RUNLIB"
# shellcheck source=lib/tar-lib.sh
source "$TAR_LIB"

# ---------------------------------------------------------------------------
# 4. Log file
#
# Created BEFORE the configuration is read, so configuration errors also end up
# in a log file instead of vanishing on stderr. Depends only on SCRIPT_DIR.
# ---------------------------------------------------------------------------

LOG_DIR="$SCRIPT_DIR/logs"
run_init "$LOG_DIR" "tar-backup" \
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
: "${INSTANCES_DIR:=$SCRIPT_DIR/instances}"
: "${MARKER_NAME:=.complete}"
: "${ARCHIVE_RETENTION_DAYS:=30}"
: "${KEEP_MIN:=2}"
: "${LOG_RETENTION_DAYS:=64}"
: "${BACKUP_MODE:=0750}"
: "${BACKUP_GROUP:=}"
: "${BACKUP_UMASK:=0027}"
: "${COMPRESSION:=gz}"
: "${COMPRESSION_LEVEL:=}"
: "${COMPRESSION_THREADS:=0}"
: "${ONE_FILE_SYSTEM:=false}"
: "${SPARSE:=false}"
: "${EXCLUDE_CACHES:=true}"
: "${EXCLUDE_VCS:=false}"
: "${VERIFY_ARCHIVE:=true}"
: "${WRITE_CHECKSUM:=true}"
: "${MIN_FREE_MB:=0}"
: "${NICE_LEVEL:=0}"
: "${IONICE_CLASS:=}"
: "${TAR_BIN:=}"
: "${EXTRA_PATH:=}"

# gtar first: on a host where "tar" is the BSD one (macOS, some NAS firmware)
# GNU tar is usually installed next to it under that name.
if [[ -z "$TAR_BIN" ]]; then
  if command -v gtar >/dev/null 2>&1; then TAR_BIN="gtar"; else TAR_BIN="tar"; fi
fi

# --dest overrides the configured target for the whole run.
[[ -n "$CLI_DEST" ]] && BACKUP_BASE="$CLI_DEST"
[[ -n "${BACKUP_BASE:-}" ]] \
  || fatal "BACKUP_BASE not set (global.conf) and no --dest given"

MARKER_PATH=""
[[ -n "$MARKER_NAME" ]] && MARKER_PATH="${BACKUP_BASE%/}/${MARKER_NAME}"

# The global values are the per-path defaults. Kept under their own names so a
# instances/<name>.conf can be reset to them before every file is sourced.
DEFAULT_RETENTION_DAYS="$ARCHIVE_RETENTION_DAYS"
DEFAULT_KEEP_MIN="$KEEP_MIN"
DEFAULT_COMPRESSION="$COMPRESSION"
DEFAULT_COMPRESSION_LEVEL="$COMPRESSION_LEVEL"
DEFAULT_COMPRESSION_THREADS="$COMPRESSION_THREADS"
DEFAULT_ONE_FILE_SYSTEM="$ONE_FILE_SYSTEM"
DEFAULT_SPARSE="$SPARSE"
DEFAULT_EXCLUDE_CACHES="$EXCLUDE_CACHES"
DEFAULT_EXCLUDE_VCS="$EXCLUDE_VCS"
DEFAULT_VERIFY_ARCHIVE="$VERIFY_ARCHIVE"
DEFAULT_WRITE_CHECKSUM="$WRITE_CHECKSUM"
DEFAULT_MIN_FREE_MB="$MIN_FREE_MB"
DEFAULT_NICE_LEVEL="$NICE_LEVEL"
DEFAULT_IONICE_CLASS="$IONICE_CLASS"

# ---------------------------------------------------------------------------
# 5b. What this run calls things
#
# runlib runs the same skeleton for every script of the family; these are the
# words that keep THIS script's log and notification its own.
# ---------------------------------------------------------------------------

# shellcheck disable=SC2034  # every name here is read by lib/runlib, not below.
{
  RUN_WHAT="tar backup"
  RUN_LOG_NAME="tar backup run"
  RUN_UNIT="Paths"
  RUN_OK_VERB="archive successful"
  RUN_ABORT_HINT="The target directory is not consistent; do not rely on this run."
  RUN_USES_MARKER=1
  INSTANCE_LABEL="Path"
  INSTANCE_LABEL_LC="path"
  INSTANCE_OPT="--instance"
}

# Telegram credentials: from TELEGRAM_CONF when global.conf points at one,
# otherwise from global.conf itself.
notify_init

# ---------------------------------------------------------------------------
# 6. trap handler
#
# Registered as soon as the Telegram credentials are known, so a configuration
# error from here on also raises an alarm instead of failing silently under
# cron. Nothing has to be rolled back at this level: a path whose POST_CMD has
# to run does so in its own EXIT trap (see archive_one_path).
#
# On a signal, stop for real instead of resuming where the run was interrupted:
# a half-written target directory must not continue towards a completion
# marker. The archive being written at that moment is a ".part" file and is
# cleaned up by the next run's rotation, so an interrupted run leaves nothing
# that could be mistaken for a backup.
# ---------------------------------------------------------------------------

run_traps

# ---------------------------------------------------------------------------
# 7. Helper functions
# ---------------------------------------------------------------------------

prepare_target_dir() {
  # prepare_target_dir <dir> — create a target directory and give it the
  # configured mode/group. Returns 1 on failure WITHOUT logging: it is called
  # both from the run level and from inside the per-path subshell, and those two
  # log through different channels — so the call site reports the failure.
  local dir="$1"
  mkdir -p "$dir" || return 1
  chmod "$BACKUP_MODE" "$dir" || return 1
  if [[ -n "$BACKUP_GROUP" ]]; then
    chgrp "$BACKUP_GROUP" "$dir" || return 1
    # setgid: every archive created later inherits the group, so a read-only
    # pull user can read it without this script chasing each new file with a
    # chgrp.
    chmod g+s "$dir" || return 1
  fi
  return 0
}

# shellcheck disable=SC2034  # ENABLED is read by lib/runlib's loader; the rest
# by tar-lib.sh and by the path configurations sourced on top of them.
reset_path_vars() {
  # Every per-path variable, set to the global default. Called by runlib before
  # each instances/<name>.conf is sourced (and again inside the subshell), so a
  # value from one file never leaks into the next and every file starts from the
  # same documented state. The argument is the path's name, unused here — the
  # target is derived in validate_path, after the configuration had its say.
  SOURCE=""
  DEST_DIR=""
  ENABLED="true"
  RETENTION_DAYS="$DEFAULT_RETENTION_DAYS"
  KEEP_MIN="$DEFAULT_KEEP_MIN"
  COMPRESSION="$DEFAULT_COMPRESSION"
  COMPRESSION_LEVEL="$DEFAULT_COMPRESSION_LEVEL"
  COMPRESSION_THREADS="$DEFAULT_COMPRESSION_THREADS"
  ONE_FILE_SYSTEM="$DEFAULT_ONE_FILE_SYSTEM"
  SPARSE="$DEFAULT_SPARSE"
  EXCLUDE_CACHES="$DEFAULT_EXCLUDE_CACHES"
  EXCLUDE_VCS="$DEFAULT_EXCLUDE_VCS"
  VERIFY_ARCHIVE="$DEFAULT_VERIFY_ARCHIVE"
  WRITE_CHECKSUM="$DEFAULT_WRITE_CHECKSUM"
  MIN_FREE_MB="$DEFAULT_MIN_FREE_MB"
  NICE_LEVEL="$DEFAULT_NICE_LEVEL"
  IONICE_CLASS="$DEFAULT_IONICE_CLASS"
  EXCLUDES=()
  EXCLUDE_FROM=""
  TAR_EXTRA_OPTS=()
  PRE_CMD=""
  POST_CMD=""
}

adhoc_name() {
  # adhoc_name <path> — archive name for "--source <path>": the directory name,
  # reduced to characters that are unambiguous in a file name. The name has to
  # survive being pattern-matched by the retention (<name>-*.tar*), so anything
  # exotic is replaced rather than quoted.
  local n
  n="$(basename "${1%/}")"
  n="$(printf '%s' "$n" | tr -c 'A-Za-z0-9._-' '_')"
  n="${n#_}"; n="${n#.}"
  [[ -n "$n" ]] || n="backup"
  printf '%s' "$n"
}

check_path() {
  # check_path <name> <conf> <source> <dest> — validate one entry. <conf> is
  # empty for an ad-hoc --source entry. Returns 0 if the entry is usable.
  #
  # A configuration that cannot be used is an ERROR, not a silent skip: it ends
  # up in ERRORS and thus suppresses the completion marker. Only an explicit
  # ENABLED=false is a deliberate skip.
  local name="$1" conf="$2" src="$3" dest="$4" other

  if [[ -z "$src" ]]; then
    log_error "Path '$name': SOURCE not set${conf:+ ($conf)} — skipped"
    return 1
  fi
  if [[ ! -e "$src" ]]; then
    log_error "Path '$name': source does not exist: $src — skipped"
    return 1
  fi
  if [[ "$(abs_path "$src")" == "/" ]]; then
    log_error "Path '$name': SOURCE=\"/\" is not supported — configure the directories below it instead"
    return 1
  fi
  if [[ -z "$dest" ]]; then
    log_error "Path '$name': no target directory (neither DEST_DIR nor BACKUP_BASE) — skipped"
    return 1
  fi
  # The archive would end up inside the tree it archives: the run would back up
  # its own (and every older) archive, growing without bound. Not a warning —
  # there is no reading of this configuration under which it does what it says.
  if is_inside "$dest" "$src"; then
    log_error "Path '$name': target directory lies inside the source ($dest in $src) — the archives would archive themselves. Point DEST_DIR outside the source."
    return 1
  fi

  # The same trap across two entries: this path's target sits inside ANOTHER
  # path's source, so those archives end up inside that other archive. Only a
  # warning — with small archives it can be deliberate.
  for other in "${PATH_SOURCES[@]+"${PATH_SOURCES[@]}"}"; do
    if is_inside "$dest" "$other"; then
      log_warn "Path '$name': target $dest lies inside the source $other of another path — its archives will end up in that path's archive"
    fi
  done

  contains "$COMPRESSION" "${NEED_COMPRESSORS[@]+"${NEED_COMPRESSORS[@]}"}" \
    || NEED_COMPRESSORS+=("$COMPRESSION")
  is_truthy "$WRITE_CHECKSUM" && NEED_CHECKSUM=1
  return 0
}

validate_path() {
  # validate_path <name> <conf> — runlib's per-object hook. The configuration
  # has been sourced at this point, so SOURCE/DEST_DIR carry what it said.
  local name="$1" conf="$2"

  # Default target: one sub-directory per path under BACKUP_BASE. A DEST_DIR in
  # the configuration may point anywhere — that is the point of the setting.
  # "--dest" overrides both, for the whole run.
  if [[ -n "$CLI_DEST" ]]; then
    DEST_DIR="${CLI_DEST%/}/$name"
  elif [[ -z "$DEST_DIR" ]]; then
    DEST_DIR="${BACKUP_BASE%/}/$name"
  fi

  check_path "$name" "$conf" "${SOURCE%/}" "${DEST_DIR%/}" || return 1

  PATH_SOURCES+=("${SOURCE%/}")
  PATH_DESTS+=("${DEST_DIR%/}")
  instances_record "${DEST_DIR%/}" "$name"
  log_info "Path '$name': source ${SOURCE%/}, target ${DEST_DIR%/}, compression $COMPRESSION, retention ${RETENTION_DAYS} days (keep at least ${KEEP_MIN})"
  return 0
}

load_adhoc_paths() {
  # Ad-hoc mode: the paths come from the command line, instances/*.conf is not read
  # at all. Everything else (target, compression, retention) is the global
  # default, so a quick "--source X --dest Y" behaves exactly like a configured
  # path with nothing but SOURCE set. runlib's loader is bypassed, so the
  # index-parallel records are filled here.
  local src name i=0
  log_warn "Ad-hoc run (--source) — instances/*.conf is ignored and no completion marker will be written"
  for src in "${ADHOC_SOURCES[@]}"; do
    src="${src%/}"
    name="$(adhoc_name "$src")"
    # Two --source arguments with the same basename would otherwise write into
    # the same archive name and rotate each other away.
    if contains "$name" "${INSTANCE_NAMES[@]+"${INSTANCE_NAMES[@]}"}"; then
      i=$((i + 1)); name="${name}-${i}"
    fi
    reset_path_vars "$name"
    SOURCE="$src"
    DEST_DIR="${BACKUP_BASE%/}/$name"
    check_path "$name" "" "$SOURCE" "$DEST_DIR" || continue
    INSTANCE_NAMES+=("$name")
    INSTANCE_CONFS+=("")
    INSTANCE_OUTDIRS+=("$DEST_DIR")
    INSTANCE_TITLES+=("$name")
    PATH_SOURCES+=("$SOURCE")
    PATH_DESTS+=("$DEST_DIR")
    log_info "Path '$name': source $SOURCE, target $DEST_DIR (ad-hoc)"
  done
  [[ "${#INSTANCE_NAMES[@]}" -gt 0 ]] || fatal "No usable --source path"
}

check_binaries() {
  # Report the availability of the required programs at the very start, so a
  # missing or mislocated binary is obvious in the log instead of surfacing as a
  # cryptic failure halfway through. Which ones are required follows from the
  # configured compression modes (see check_path).
  log_info "--- Checking programs ---"
  local p ver major minor c

  if p="$(command -v "$TAR_BIN" 2>/dev/null)"; then
    ver="$("$TAR_BIN" --version 2>/dev/null | head -1)"
    if [[ "$ver" == *"GNU tar"* ]]; then
      log_info "tar found: $p ($ver)"
      # --use-compress-program with ARGUMENTS ("pigz -6 -p 4") needs tar >= 1.27;
      # older versions treat the whole string as one program name.
      major="$(printf '%s' "$ver" | grep -oE '[0-9]+\.[0-9]+' | head -1 | cut -d. -f1)"
      minor="$(printf '%s' "$ver" | grep -oE '[0-9]+\.[0-9]+' | head -1 | cut -d. -f2)"
      if [[ -n "$major" && -n "$minor" ]] \
         && { [[ "$major" -lt 1 ]] || { [[ "$major" -eq 1 ]] && [[ "$minor" -lt 27 ]]; }; }; then
        log_warn "tar $major.$minor is older than 1.27 — COMPRESSION_LEVEL/COMPRESSION_THREADS cannot be passed to the compressor; leave both at their defaults"
      fi
    else
      log_error "'$TAR_BIN' is not GNU tar (${ver:-unknown}) — this script uses GNU options (--exclude-caches, --one-file-system, --use-compress-program). Install GNU tar and set TAR_BIN in global.conf."
    fi
  else
    log_error "tar not found ('$TAR_BIN') — nothing can be archived. Set EXTRA_PATH or TAR_BIN in global.conf."
  fi

  for c in "${NEED_COMPRESSORS[@]+"${NEED_COMPRESSORS[@]}"}"; do
    case "$c" in
      none|tar) continue ;;
      gz|gzip)
        if p="$(command -v pigz 2>/dev/null)"; then log_info "gz: pigz found: $p (parallel)"
        elif p="$(command -v gzip 2>/dev/null)"; then log_info "gz: gzip found: $p (single-core — install pigz for parallel compression)"
        else log_error "COMPRESSION=gz is configured, but neither pigz nor gzip was found"; fi ;;
      zst|zstd)
        if p="$(command -v zstd 2>/dev/null)"; then log_info "zst: zstd found: $p"
        else log_error "COMPRESSION=zst is configured, but zstd was not found"; fi ;;
      xz)
        if p="$(command -v xz 2>/dev/null)"; then log_info "xz: xz found: $p"
        else log_error "COMPRESSION=xz is configured, but xz was not found"; fi ;;
      bz2|bzip2)
        if p="$(command -v pbzip2 2>/dev/null)"; then log_info "bz2: pbzip2 found: $p (parallel)"
        elif p="$(command -v bzip2 2>/dev/null)"; then log_info "bz2: bzip2 found: $p (single-core)"
        else log_error "COMPRESSION=bz2 is configured, but neither pbzip2 nor bzip2 was found"; fi ;;
    esac
  done

  if [[ "$NEED_CHECKSUM" -eq 1 ]] && ! command -v sha256sum >/dev/null 2>&1; then
    log_warn "sha256sum not found — archives are written without a checksum"
  fi

  notify_check_binaries
}

# --- per-path archive -------------------------------------------------------

run_pre_cmd() {
  # Optional per-path hook, run BEFORE the archive: stop the container that
  # writes into the source, flush an application cache, dump a database next to
  # the files. Default empty — for a plain directory backup there is nothing to
  # quiesce.
  #
  # A failing PRE_CMD means the state it was supposed to establish does not
  # exist, so no archive is taken at all — an archive of a running database's
  # files that pretends to be consistent is worse than a missing one.
  [[ -n "$PRE_CMD" ]] || return 0
  log INFO "${PATH_NAME}: PRE_CMD: $PRE_CMD"
  if PATH_NAME="$PATH_NAME" SOURCE="$SOURCE" DEST_DIR="$DEST_DIR" \
     bash -c "$PRE_CMD"; then
    PRE_CMD_OK=1
    return 0
  fi
  log ERROR "${PATH_NAME}: PRE_CMD failed — no archive taken"
  return 1
}

run_post_cmd() {
  # Counterpart of PRE_CMD, called from the subshell's EXIT trap so it runs on
  # every path out — including the "return 1" of a failed archive. This is what
  # gets the container started again.
  #
  # Skipped only if a PRE_CMD was configured and did NOT succeed: then the state
  # PRE_CMD was to establish never existed, and undoing it blindly is guesswork.
  [[ -n "$POST_CMD" ]] || return 0
  [[ "$POST_CMD_DONE" -eq 1 ]] && return 0
  POST_CMD_DONE=1
  if [[ -n "$PRE_CMD" && "$PRE_CMD_OK" -ne 1 ]]; then
    log WARN "${PATH_NAME}: PRE_CMD did not succeed — POST_CMD skipped"
    return 0
  fi
  log INFO "${PATH_NAME}: POST_CMD: $POST_CMD"
  if PATH_NAME="$PATH_NAME" SOURCE="$SOURCE" DEST_DIR="$DEST_DIR" \
     bash -c "$POST_CMD"; then
    return 0
  fi
  # A path whose POST_CMD failed counts as failed even if its archive is fine:
  # the run must not report success — and above all must not write the
  # completion marker — while a container it stopped stays down.
  log ERROR "${PATH_NAME}: POST_CMD failed — manual intervention needed"
  return 1
}

_path_exit_trap() {
  local rc=$?
  run_post_cmd || rc=1
  exit "$rc"
}

archive_one_path() {
  # archive_one_path <name> <conf> <index> — runlib's worker.
  #
  # Called on the LEFT side of a pipeline, i.e. in a SUBSHELL — deliberately: a
  # failure here has to end THIS path and not the whole run, and the per-path
  # variables (including the arrays) cannot leak into the next path.
  #
  # Inside here, logging therefore goes through tar-lib.sh's log() (stderr,
  # captured by that pipe); log_info/log_error belong to the run level, would be
  # written to the log file a second time by the pipe, and could not report
  # anything back across the subshell boundary anyway.
  local name="$1" conf="$2" idx="$3" rc=0
  local src="${PATH_SOURCES[$idx]}" dest="${PATH_DESTS[$idx]}"

  reset_path_vars "$name"
  PATH_NAME="$name"
  PRE_CMD_OK=0
  POST_CMD_DONE=0

  if [[ -n "$conf" ]]; then
    # shellcheck source=/dev/null
    source "$conf" || { log ERROR "${name}: cannot read $conf"; exit 1; }
  fi

  # Re-pin what the run level already resolved: a configuration may legitimately
  # assign SOURCE/DEST_DIR (that is where these values came from), but none of
  # them may end up different from what the run level validated — a path writing
  # somewhere else would be missing from the summary, from the retention and
  # from the marker's promise.
  SOURCE="$src"
  DEST_DIR="$dest"

  prepare_target_dir "$DEST_DIR" \
    || { log ERROR "${name}: cannot prepare the target directory $DEST_DIR"; exit 1; }

  trap _path_exit_trap EXIT
  run_pre_cmd || exit 1

  # Rotate BEFORE writing: on a target that is nearly full, deleting the expired
  # archives first is what makes room for the new one. KEEP_MIN still protects
  # the newest ones, so this never trades a good archive for a failed run.
  archive_rotate "$DEST_DIR" "$name" "$RETENTION_DAYS" "$KEEP_MIN"

  if create_archive "$name"; then
    if is_truthy "$VERIFY_ARCHIVE"; then
      verify_archive "$name" "$ARCHIVE_PATH" || rc=1
    fi
    if [[ "$rc" -eq 0 ]] && is_truthy "$WRITE_CHECKSUM"; then
      write_checksum "$name" "$ARCHIVE_PATH" || rc=1
    fi
  else
    rc=1
  fi

  # Exit EXPLICITLY, do not just fall off the end. This function runs in a
  # PIPELINE subshell, and there an EXIT trap is not reliably executed when the
  # body simply ends (bash 3.2 skips it) — POST_CMD would then never run.
  exit "$rc"
}

# ---------------------------------------------------------------------------
# 8. Start
# ---------------------------------------------------------------------------

log_info "Starting tar backup run on $HOSTNAME_SHORT"
log_rotate "$LOG_DIR" "tar-backup" "$LOG_RETENTION_DAYS"

# Cron starts with a minimal PATH, and on some hosts (e.g. a NAS) tar, zstd or
# pigz live somewhere like /volume1/opt/bin. EXTRA_PATH puts them in reach — for
# this script and for tar-lib.sh, which calls them by name.
if [[ -n "$EXTRA_PATH" ]]; then
  PATH="$EXTRA_PATH:$PATH"
  export PATH
  log_info "PATH extended by EXTRA_PATH: $EXTRA_PATH"
fi

if [[ "${#ADHOC_SOURCES[@]}" -gt 0 ]]; then
  load_adhoc_paths
else
  instances_load "$INSTANCES_DIR" reset_path_vars validate_path \
    "${SELECTED_PATHS[@]+"${SELECTED_PATHS[@]}"}"
fi

if [[ "$ACTION" == "list" ]]; then
  log_info "--- Configured paths (${#INSTANCE_NAMES[@]}) ---"
  for idx in "${!INSTANCE_NAMES[@]}"; do
    log_plain "  ${INSTANCE_NAMES[$idx]}  source=${PATH_SOURCES[$idx]}  target=${PATH_DESTS[$idx]}"
  done
  run_end 0
fi

check_binaries

if [[ "$DRY_RUN" -eq 1 ]]; then
  log_info "--- Dry run: nothing is written ---"
  for idx in "${!INSTANCE_NAMES[@]}"; do
    log_plain "  ${INSTANCE_NAMES[$idx]}: ${PATH_SOURCES[$idx]} -> ${PATH_DESTS[$idx]}/${INSTANCE_NAMES[$idx]}-<timestamp>.tar.*"
  done
  log_info "Dry run finished (${#ERRORS[@]} error(s) in the configuration)"
  [[ "${#ERRORS[@]}" -gt 0 ]] && run_end 1
  run_end 0
fi

acquire_lock || run_end 1

# Archives are written 0640 / directories 0750 (BACKUP_UMASK): a tar of an
# arbitrary directory contains everything that was in it, including files only
# root could read, so it must not become world-readable. Set after the log file
# was created, which stays world-readable on purpose.
umask "$BACKUP_UMASK"

prepare_target_dir "$BACKUP_BASE" \
  || fatal "Cannot prepare the target directory: $BACKUP_BASE"
log_info "Target directory: $BACKUP_BASE (mode $BACKUP_MODE${BACKUP_GROUP:+, group $BACKUP_GROUP})"

if [[ "${#SELECTED_PATHS[@]}" -gt 0 ]]; then
  log_warn "Partial run (--instance ${SELECTED_PATHS[*]}) — the completion marker will NOT be written"
fi

# ---------------------------------------------------------------------------
# 9. Archives
# ---------------------------------------------------------------------------

log_info "--- Archives ---"
run_worker_loop archive_one_path

# ---------------------------------------------------------------------------
# 10. Completion marker
#
# MARKER_NOTE is the one value this section produces: runlib's run_finish puts
# it into the closing log line and the notification.
# ---------------------------------------------------------------------------

# shellcheck disable=SC2034  # MARKER_NOTE is read by lib/runlib's run_finish.
if [[ -z "$MARKER_PATH" ]]; then
  MARKER_NOTE="disabled (MARKER_NAME empty)"
elif [[ "${#ERRORS[@]}" -gt 0 ]]; then
  # _log_emit, not log_error: every one of those errors is already recorded —
  # this line only states the consequence and must not inflate the count.
  _log_emit "ERROR" "Run had ${#ERRORS[@]} error(s) — completion marker NOT written; do not rely on this target directory"
  MARKER_NOTE="NOT written — do not rely on this target directory"
elif [[ "${#SELECTED_PATHS[@]}" -gt 0 || "${#ADHOC_SOURCES[@]}" -gt 0 ]]; then
  log_info "Partial run — completion marker deliberately not written (an existing one is left untouched)"
  MARKER_NOTE="not written (partial run) — an existing marker still applies"
else
  if write_marker "$MARKER_PATH" "$BACKUP_GROUP" "tar-backup" \
       "paths_ok=${#OK_INSTANCES[@]}" \
       "paths_total=${#INSTANCE_NAMES[@]}" \
       "archive_bytes=$TOTAL_BYTES"; then
    MARKER_NOTE="written ($MARKER_PATH)"
  else
    MARKER_NOTE="NOT written — writing it failed"
  fi
fi

# ---------------------------------------------------------------------------
# 11. Completion
# ---------------------------------------------------------------------------

run_finish
