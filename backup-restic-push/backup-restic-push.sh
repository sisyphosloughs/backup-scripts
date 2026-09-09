#!/usr/bin/env bash
#
# backup-restic-push.sh — pushes local directories into one or more restic repos.
#
# It backs up what it is pointed at and nothing else: no container is stopped,
# no database is dumped here. Database dumps are produced by backup-docker-db,
# which publishes them under its own staging directory; this script picks that
# directory up like any other. One job per script — see README.md.
#
# A single script, with host-specific configuration in separate files:
#   global.conf            global switches (binaries, repos, Telegram, …)
#   instances/<name>.conf  one file per backed-up object (BACKUP_PATH, EXCLUDES,
#                          TARGET_REPOS)
#   repos.conf             one restic repository URL per line
#   repo.password          restic password (chmod 600, owned by root)
#   lib/runlib/            the shared run skeleton (log file, error account,
#                          lock, configuration loader, summary, notification),
#                          a git submodule shared with the other backup scripts
# all in the same directory as this script. Must run with root privileges.
# See README.md.

set -uo pipefail

# ---------------------------------------------------------------------------
# 1. Initialisation
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Successfully backed-up targets
SUCCESS_TARGETS=()
# All reachable repos (for forget/prune/check)
REACHABLE_REPOS=()

# What the run actually moved, for the summary. restic reads the whole tree
# every night but only writes the deduplicated difference, so one number would
# be misleading: PROCESSED is the size of what was examined (the same tree for
# every repo, hence the maximum rather than a sum), ADDED is what really landed
# in the repositories (summed — each repo received its own copy).
TOTAL_PROCESSED=0
TOTAL_ADDED=0

# Repository list (parsed from repos.conf — see below). Two index-parallel
# arrays: REPOS[i] is the restic URL, REPO_NAMES[i] its name/alias (used by an
# instance's TARGET_REPOS to pick its destination; a bare-URL line gets the URL
# itself as its name).
REPOS=()
REPO_NAMES=()

# Aggregated from the instance configurations (see load_instances)
BACKUP_PATHS=()        # union of all BACKUP_PATHs (overview log only)
EXCLUDE_PATTERNS=()    # union of all anchored excludes (overview log only)

# Per-instance records (index-parallel) used to group backups by destination
# repo: each repo is backed up with exactly the paths/excludes of the instances
# that target it. INST_TARGETS[i] is a space-separated list of resolved repo
# names; INST_EXCLUDES[i] is a newline-separated list of anchored patterns
# (exclude patterns never contain newlines).
INST_NAME=()
INST_PATH=()
INST_TARGETS=()
INST_EXCLUDES=()

# ---------------------------------------------------------------------------
# 2. Command line
#
# Parsed before anything else so "--help" neither reads a configuration nor
# creates a log file.
# ---------------------------------------------------------------------------

SELECTED_INSTANCES=()
ACTION="run"

usage() {
  cat <<'EOF'
Usage: backup-restic-push.sh [options]

Backs up the paths configured in instances/*.conf into the repositories listed
in repos.conf — one snapshot per repository.

Options:
  -i, --instance NAME  Back up only this instance (repeatable).
  -l, --list           List the configured instances and exit.
  -h, --help           Show this help and exit.

Exit code: 0 only if the run was completely error-free.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -l|--list) ACTION="list"; shift ;;
    -i|--instance)
      [[ $# -ge 2 ]] || { echo "FATAL: --instance requires a name" >&2; exit 2; }
      SELECTED_INSTANCES+=("$2"); shift 2 ;;
    --instance=*) SELECTED_INSTANCES+=("${1#*=}"); shift ;;
    *) echo "FATAL: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Library
#
# runlib brings the log file, the error account (ERRORS -> exit code), the lock,
# the instances/*.conf loader, the summary and the Telegram notification. It is
# a git submodule, shared with the other backup scripts of this family, so a log
# line means the same thing no matter which one produced it.
# ---------------------------------------------------------------------------

RUNLIB="$SCRIPT_DIR/lib/runlib/runlib.sh"
[[ -r "$RUNLIB" ]] || {
  echo "FATAL: library not readable: $RUNLIB" >&2
  echo "       (lib/runlib is a git submodule — run 'git submodule update --init')" >&2
  exit 1
}
# shellcheck source=lib/runlib/runlib.sh
source "$RUNLIB"

# ---------------------------------------------------------------------------
# Log file
#
# Created BEFORE the configuration is read, so configuration errors also end up
# in a log file instead of vanishing on stderr. Depends only on SCRIPT_DIR.
# ---------------------------------------------------------------------------

LOG_DIR="$SCRIPT_DIR/logs"
run_init "$LOG_DIR" "backup" \
  || { echo "FATAL: cannot create the log file in $LOG_DIR" >&2; exit 1; }

dry_run_enabled() { is_truthy "${DRY_RUN:-false}"; }

has_rclone_targets() {
  # Returns 0 if at least one "rclone:" target is configured in REPOS_FILE.
  # Reads the file directly so it also works before REPOS has been parsed.
  [[ -n "${REPOS_FILE:-}" && -f "$REPOS_FILE" ]] || return 1
  grep -Eq '^[[:space:]]*rclone:' "$REPOS_FILE"
}

check_binaries() {
  # Check and log the availability of the required external programs at the very
  # start, so missing/mislocated binaries are obvious in the log instead of
  # surfacing as cryptic failures later. Honours the optional RESTIC_BIN /
  # RCLONE_BIN paths from global.conf.
  log_info "--- Checking programs ---"
  local p

  # restic (mandatory) — abort if not found.
  if p="$(command -v "$RESTIC_BIN" 2>/dev/null)"; then
    log_info "restic found: $p ($("$RESTIC_BIN" version 2>/dev/null | head -n1))"
  else
    fatal "restic not found: '$RESTIC_BIN'. Set RESTIC_BIN in global.conf to the absolute path (e.g. /usr/local/bin/restic)."
  fi

  # rclone (only if rclone targets are configured).
  if has_rclone_targets; then
    if p="$(command -v "$RCLONE_BIN" 2>/dev/null)"; then
      log_info "rclone found: $p ($("$RCLONE_BIN" version 2>/dev/null | head -n1)); restic uses it via -o rclone.program"
    else
      log_error "rclone targets configured, but rclone not found: '$RCLONE_BIN'. Set RCLONE_BIN in global.conf to the absolute path (e.g. /usr/local/bin/rclone)."
    fi
  fi

  notify_check_binaries

  # jq (optional — a grep fallback is used otherwise).
  if p="$(command -v jq 2>/dev/null)"; then
    log_info "jq found: $p"
  else
    log_info "jq not found — using grep fallback for restic JSON output"
  fi
}

# shellcheck disable=SC2034  # ENABLED is read by lib/runlib's loader.
reset_instance_vars() {
  # runlib's per-object hook, called before each instances/<name>.conf is
  # sourced, so a value from one file never leaks into the next.
  #
  # NOTE: the per-object path variable is BACKUP_PATH, NOT PATH — using the name
  # "PATH" would clobber the shell's executable search path and break the run.
  #
  # NOTE: the destination variable is TARGET_REPOS, NOT REPOS (that is the
  # global URL list parsed from repos.conf).
  BACKUP_PATH=""
  ENABLED="true"
  EXCLUDES=()
  TARGET_REPOS=()
}

validate_instance() {
  # validate_instance <name> <conf> — runlib's per-object hook, called after the
  # configuration was sourced. Returns non-zero to skip the instance.
  #
  # Fills the records the backup loop groups by:
  #   INST_NAME[] / INST_PATH[] / INST_TARGETS[] / INST_EXCLUDES[]
  #                      index-parallel; the loop picks an instance for a repo
  #                      via INST_TARGETS (resolved space-separated repo names)
  #                      so each repo is backed up with only the paths/excludes
  #                      of its own instances.
  #   BACKUP_PATHS[]     union of all valid BACKUP_PATHs — also the "Paths:"
  #                      line of the notification
  #   EXCLUDE_PATTERNS[] union of all anchored EXCLUDES (overview log only)
  local name="$1" conf="$2" pat base t targets inst_excl

  if [[ -z "$BACKUP_PATH" ]]; then
    log_error "Instance '$name' ($conf): BACKUP_PATH not set — instance skipped"
    return 1
  fi
  if [[ ! -d "$BACKUP_PATH" ]]; then
    log_error "Instance '$name': BACKUP_PATH does not exist, instance skipped: $BACKUP_PATH"
    return 1
  fi

  # Resolve this instance's destination repos. Empty TARGET_REPOS -> all repos.
  # Unknown names are dropped with an error; an instance left with no valid
  # target is skipped entirely, so its data is not silently dropped.
  if [[ "${#TARGET_REPOS[@]}" -eq 0 ]]; then
    targets="${REPO_NAMES[*]}"
  else
    targets=""
    for t in "${TARGET_REPOS[@]}"; do
      [[ -z "$t" ]] && continue
      if contains "$t" "${REPO_NAMES[@]+"${REPO_NAMES[@]}"}"; then
        targets+="${targets:+ }$t"
      else
        log_error "Instance '$name': unknown TARGET_REPOS entry '$t' (not in repos.conf) — ignored"
      fi
    done
  fi
  if [[ -z "$targets" ]]; then
    log_error "Instance '$name': no valid target repository, instance not backed up"
    return 1
  fi

  # Anchor this instance's excludes to its BACKUP_PATH so they apply ONLY under
  # that path. restic's --exclude is otherwise global across every path of a
  # backup call, so an unanchored basename pattern (e.g. @eaDir) would match
  # under all paths of that repo. A pattern that already starts with "/" is
  # taken verbatim (the user anchors it themselves — the escape hatch). A
  # relative / basename pattern <pat> is emitted in two anchored forms so it
  # matches at every depth under the base:
  #   <base>/<pat>     directly in the base directory
  #   <base>/**/<pat>  at any depth below it
  # The explicit <base>/<pat> is a safety net in case restic's ** does not
  # match zero directories. Patterns are deduplicated within the instance.
  base="${BACKUP_PATH%/}"
  inst_excl=()
  for pat in "${EXCLUDES[@]+"${EXCLUDES[@]}"}"; do
    [[ -z "$pat" ]] && continue
    if [[ "$pat" == /* ]]; then
      contains "$pat" "${inst_excl[@]+"${inst_excl[@]}"}" || inst_excl+=("$pat")
    else
      contains "$base/$pat" "${inst_excl[@]+"${inst_excl[@]}"}" \
        || inst_excl+=("$base/$pat")
      contains "$base/**/$pat" "${inst_excl[@]+"${inst_excl[@]}"}" \
        || inst_excl+=("$base/**/$pat")
    fi
  done
  # Mirror into the EXCLUDE_PATTERNS union (overview log only).
  for pat in "${inst_excl[@]+"${inst_excl[@]}"}"; do
    contains "$pat" "${EXCLUDE_PATTERNS[@]+"${EXCLUDE_PATTERNS[@]}"}" \
      || EXCLUDE_PATTERNS+=("$pat")
  done

  BACKUP_PATHS+=("$BACKUP_PATH")
  INST_NAME+=("$name")
  INST_PATH+=("$BACKUP_PATH")
  INST_TARGETS+=("$targets")
  if [[ "${#inst_excl[@]}" -gt 0 ]]; then
    INST_EXCLUDES+=("$(printf '%s\n' "${inst_excl[@]}")")
  else
    INST_EXCLUDES+=("")
  fi
  instances_record "" "$name"
  log_info "Instance '$name': target repos: $targets"
  log_info "Instance '$name': $BACKUP_PATH"
  return 0
}

# ---------------------------------------------------------------------------
# Load configuration (logging is now available)
# ---------------------------------------------------------------------------

GLOBAL_CONF="$SCRIPT_DIR/global.conf"
if [[ ! -f "$GLOBAL_CONF" ]]; then
  fatal "Global configuration file not found: $GLOBAL_CONF"
fi
# shellcheck source=/dev/null
source "$GLOBAL_CONF"

# Optional absolute paths to the restic / rclone binaries. Empty / unset = use
# whatever is found in PATH. On some hosts the binaries live in a non-standard
# location that the (cron) PATH does not contain — set the absolute path then;
# see the NAS section of README.md. restic launches rclone as a subprocess; it is
# told which binary to use via "-o rclone.program=$RCLONE_BIN" (see
# restic_repo), so rclone does NOT need to be in PATH either.
# Set before check_binaries so the availability check honours these paths.
: "${RESTIC_BIN:=restic}"
: "${RCLONE_BIN:=rclone}"

# Check mandatory global variables
[[ -n "${REPOS_FILE:-}" ]]           || fatal "REPOS_FILE not set (global.conf)"
[[ -n "${RESTIC_PASSWORD_FILE:-}" ]] || fatal "RESTIC_PASSWORD_FILE not set (global.conf)"
# Optional variables: take the value from global.conf if set there, otherwise
# fall back to the default. The ":=" only assigns when the variable is unset or
# empty, so a value defined in global.conf always wins.
: "${LOG_RETENTION_DAYS:=64}"
: "${DRY_RUN:=false}"
# Seconds between progress lines during a real (non-dry) backup. restic's --json
# "status" stream is throttled to one compact line (percent / bytes / files / ETA)
# per this many seconds, so an interactive (e.g. initial) run shows progress
# without the per-file flood of --dry-run --verbose=2. 0 disables progress lines.
: "${PROGRESS_INTERVAL:=30}"

# ---------------------------------------------------------------------------
# Read and validate the repository list — abort if missing or empty.
# Parsed BEFORE load_instances so the repo names are known when an instance's
# TARGET_REPOS is validated/resolved. Still before the trap is registered, so a
# config error here exits cleanly (without stack recovery).
#
# Line syntax (blank lines and "#" comments ignored):
#   <name> = <url>   named repo; an instance's TARGET_REPOS picks it by <name>.
#                    <name> must match ^[A-Za-z0-9_-]+$.
#   <url>            bare URL (no "=" prefix-name); its name defaults to the URL
#                    itself, so it can still be referenced verbatim.
# restic URLs (rclone:/sftp:/s3:/paths) contain no "=", so the name guard never
# misreads a URL as "name = url".
# ---------------------------------------------------------------------------

[[ -f "$REPOS_FILE" ]] || fatal "Repository list not found: $REPOS_FILE"
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%%#*}"                 # remove comments
  read -r line <<< "$line"           # trim leading/trailing whitespace (pure bash)
  [[ -z "$line" ]] && continue

  repo_name="" repo_url="$line"
  if [[ "$line" == *=* ]]; then
    candidate="${line%%=*}"
    read -r candidate <<< "$candidate"             # trim the part before "="
    if [[ "$candidate" =~ ^[A-Za-z0-9_-]+$ ]]; then
      repo_name="$candidate"
      repo_url="${line#*=}"
      read -r repo_url <<< "$repo_url"             # trim the URL
    fi
  fi
  [[ -z "$repo_url" ]] && continue
  [[ -z "$repo_name" ]] && repo_name="$repo_url"   # bare URL → name is the URL

  if contains "$repo_name" "${REPO_NAMES[@]+"${REPO_NAMES[@]}"}"; then
    fatal "Duplicate repository name '$repo_name' in $REPOS_FILE — names must be unique"
  fi
  REPOS+=("$repo_url")
  REPO_NAMES+=("$repo_name")
done < "$REPOS_FILE"

# Abort condition: no repositories defined
[[ "${#REPOS[@]}" -gt 0 ]] || fatal "No repositories configured in $REPOS_FILE"

# Collect all instance configurations (sets BACKUP_PATHS, EXCLUDE_PATTERNS and
# the per-instance INST_* records). Done after the repo list so TARGET_REPOS can
# be resolved against the known repo names.
INSTANCES_DIR="$SCRIPT_DIR/instances"
instances_load "$INSTANCES_DIR" reset_instance_vars validate_instance \
  "${SELECTED_INSTANCES[@]+"${SELECTED_INSTANCES[@]}"}"

if [[ "$ACTION" == "list" ]]; then
  log_info "--- Configured instances (${#INSTANCE_NAMES[@]}) ---"
  for idx in "${!INSTANCE_NAMES[@]}"; do
    log_plain "  ${INST_NAME[$idx]}  path=${INST_PATH[$idx]}  repos=${INST_TARGETS[$idx]}"
  done
  run_end 0
fi

# Check that the required programs are available (honours RESTIC_BIN/RCLONE_BIN).
# A missing restic aborts here.
check_binaries

# A second run started while the first is still pushing would have both of them
# talking to the same repositories. restic locks its own repo, but the second
# run would then simply fail — better to say so once, here.
acquire_lock || run_end 1

# Optional rclone configuration path. rclone does NOT reliably pick up the
# config from the RCLONE_CONFIG environment variable on every host — some builds
# fall back to /root/.config/rclone/rclone.conf regardless and fail. So the
# config is passed EXPLICITLY via "--config" everywhere it is used:
#   - direct rclone calls here (reachability check, "rclone config file") use
#     RCLONE_CONFIG_ARGS below;
#   - restic passes it to its rclone subprocess via rclone.args (see restic_repo).
# RCLONE_CONFIG is still exported as a harmless best-effort fallback for any
# rclone invocation not covered above.
RCLONE_CONFIG_ARGS=()
: "${RCLONE_CONFIG_FILE:=}"
if [[ -n "$RCLONE_CONFIG_FILE" ]]; then
  if [[ -r "$RCLONE_CONFIG_FILE" ]]; then
    export RCLONE_CONFIG="$RCLONE_CONFIG_FILE"
    RCLONE_CONFIG_ARGS=(--config "$RCLONE_CONFIG_FILE")
  else
    log_error "RCLONE_CONFIG_FILE is set but not readable for user '$(id -un)': $RCLONE_CONFIG_FILE"
  fi
fi

# Abort condition: the restic password file must exist
[[ -f "$RESTIC_PASSWORD_FILE" ]] \
  || fatal "restic password file not found: $RESTIC_PASSWORD_FILE"

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

json_num() {
  # json_num <json-line> <field> — extract a numeric field from a single-line
  # restic JSON object. Uses jq when available (have_jq, set in the backup
  # section), otherwise the same grep fallback as the summary parsing. Always
  # prints a number (0 if the field is absent), so callers can use it directly.
  local json="$1" field="$2" v
  if [[ "${have_jq:-0}" -eq 1 ]]; then
    v="$(printf '%s' "$json" | jq -r --arg f "$field" '.[$f] // 0' 2>/dev/null)"
  else
    v="$(printf '%s' "$json" | grep -o "\"$field\":[0-9]*" | grep -o '[0-9]*' | head -n1)"
  fi
  printf '%s' "${v:-0}"
}

progress_filter() {
  # progress_filter <repo-name> <summary-file>
  # Reads restic's "backup --json" stream on stdin. Emits ONE compact human
  # progress line on stdout per PROGRESS_INTERVAL seconds of restic's own elapsed
  # time (so no wall-clock call is needed inside awk — works under gawk/mawk/
  # busybox awk); the caller tees that to terminal + log. The JSON "summary"
  # message is written to <summary-file> for the caller to parse and is NOT
  # printed; every other message type (incl. per-file "verbose_status") is
  # dropped, so the log never gets the --verbose=2 per-file flood.
  local rname="$1" sfile="$2"
  # LC_ALL=C so awk parses restic's dot-decimal JSON (e.g. "percent_done":0.42)
  # and formats numbers with a dot, regardless of the host's locale — a
  # comma-decimal locale would otherwise read 0.42 as 0 and print "417,8 MB".
  LC_ALL=C awk -v RNAME="$rname" -v SFILE="$sfile" -v INTERVAL="${PROGRESS_INTERVAL:-30}" '
    function num(f,   s) {
      if (match($0, "\"" f "\":[0-9.]+")) {
        s = substr($0, RSTART, RLENGTH); sub("\"" f "\":", "", s); return s + 0
      }
      return -1
    }
    function hb(b,   u, i) {
      split("B KB MB GB TB PB", u, " "); i = 1
      while (b >= 1024 && i < 6) { b /= 1024; i++ }
      if (i == 1) return sprintf("%d %s", b, u[i])
      return sprintf("%.1f %s", b, u[i])
    }
    function dur(s) { if (s < 0) return "?"; return sprintf("%dm%02ds", int(s / 60), s % 60) }
    BEGIN { last = -1 }
    /"message_type":"summary"/ { print $0 > SFILE; close(SFILE); next }
    /"message_type":"status"/ {
      if (INTERVAL <= 0) next
      el = num("seconds_elapsed"); if (el < 0) el = 0
      bucket = int(el / INTERVAL)
      if (bucket <= last) next
      last = bucket
      pct = num("percent_done"); bd = num("bytes_done"); tb = num("total_bytes")
      fd = num("files_done"); tf = num("total_files"); rem = num("seconds_remaining")
      if (tb > 0) {
        printf "%s: %3d%%  %s/%s  %d/%d files  elapsed %s  ETA %s\n", \
          RNAME, int(pct * 100 + 0.5), hb(bd), hb(tb), fd, tf, dur(el), dur(rem)
      } else {
        printf "%s: scanning...  %d files  elapsed %s\n", RNAME, (fd < 0 ? 0 : fd), dur(el)
      }
      fflush()
      next
    }
    { next }
  '
}

# restic wrapper with password file
restic_repo() {
  # restic_repo <repo> <args...>
  # For rclone targets, tell restic which rclone binary to launch as its
  # subprocess (RCLONE_BIN); this allows a fixed/absolute path without rclone
  # being in PATH. For non-rclone repos these options are irrelevant and omitted.
  #
  # The rclone.program option carries NO arguments, and RCLONE_CONFIG from the
  # environment is not honoured reliably (see the RCLONE_CONFIG_ARGS block
  # above). So the config is passed EXPLICITLY via "--config" in rclone.args.
  # rclone.args REPLACES restic's built-in defaults, so they are reproduced
  # here verbatim:
  #   restic >= 0.12 default = "serve restic --stdio --b2-hard-delete"
  # Keep that in sync if restic ever changes it. (A config path with spaces is
  # not supported, since restic splits rclone.args on spaces.)
  local repo="$1"; shift
  local opts=()
  if [[ "$repo" == rclone:* ]]; then
    opts+=(-o "rclone.program=$RCLONE_BIN")
    if [[ -n "${RCLONE_CONFIG_FILE:-}" ]]; then
      opts+=(-o "rclone.args=serve restic --stdio --b2-hard-delete --config $RCLONE_CONFIG_FILE")
    fi
  fi
  # cmd_run logs the argument vector it then executes, so backup, forget, check
  # and unlock are all documented from this one place — including the -o
  # rclone.* options assembled above, which no call site even knows about.
  #
  # It writes to STDERR only, which is what makes this safe here: the backup
  # call is "restic … --json | progress_filter", and a log line on stdout would
  # land in the JSON parsing and destroy the snapshot id and byte counts. Every
  # call site routes stderr into the log file.
  cmd_run "$RESTIC_BIN" "${opts[@]+"${opts[@]}"}" --repo "$repo" \
    --password-file "$RESTIC_PASSWORD_FILE" "$@"
}

check_rclone_config() {
  # Checks whether the user running this script (usually root) can read the
  # rclone configuration. Without a readable config, every rclone target would
  # be classified as "not reachable". Runs only if an "rclone:" target exists
  # at all. See "Configure rclone" in README.md.
  has_rclone_targets || return 0

  # rclone presence is already reported by check_binaries; nothing to check here
  # if it is missing.
  command -v "$RCLONE_BIN" >/dev/null 2>&1 || return 0

  # Determine the configuration path actually used by rclone (takes the explicit
  # --config / exported RCLONE_CONFIG into account).
  local conf_path
  conf_path="$("$RCLONE_BIN" "${RCLONE_CONFIG_ARGS[@]+"${RCLONE_CONFIG_ARGS[@]}"}" config file 2>/dev/null | tail -n 1)"

  if [[ -n "${RCLONE_CONFIG:-}" ]]; then
    log_info "rclone configuration: using RCLONE_CONFIG_FILE ($RCLONE_CONFIG)"
  fi

  if [[ -n "$conf_path" && -r "$conf_path" ]]; then
    log_info "rclone configuration readable for user '$(id -un)': $conf_path"
  else
    log_error "rclone configuration NOT readable for user '$(id -un)' (${conf_path:-no path determinable}). 'rclone config' was probably run as a different user — as root the rclone.conf is then not visible. Set RCLONE_CONFIG_FILE in global.conf to the absolute path of the rclone.conf (e.g. /home/USER/.config/rclone/rclone.conf) or run 'rclone config' as root. Otherwise all rclone targets are skipped as 'not reachable'."
  fi
}

repo_reachable() {
  # Probes an rclone target via "rclone lsd". repos are in the form
  # rclone:<remote>:<path>. Sets two globals for the caller:
  #   REPO_PROBE_STATUS       -> "reachable" | "repo-missing" | "unreachable"
  #   REPO_UNREACHABLE_REASON -> rclone command + exit code + output on failure,
  #                              so the caller can log *why* instead of a bare
  #                              "not reachable".
  # Returns 0 only when the target is reachable AND the repo path is present.
  local repo="$1"
  REPO_PROBE_STATUS="reachable"
  REPO_UNREACHABLE_REASON=""
  if [[ "$repo" == rclone:* ]]; then
    local remote_path="${repo#rclone:}"   # <remote>:<path>
    local out rc
    # Fail-fast probe. WITHOUT explicit timeouts, "rclone lsd" against an
    # unreachable remote does NOT fail quickly: rclone's default --contimeout is
    # 1 minute (and it retries), and a connected-but-silent server is only given
    # up on after the 5-minute --timeout — the check would then block for
    # minutes at "--- Checking repository reachability ---". Short timeouts and
    # no retries let an unreachable target return in seconds. Reading stdin from
    # /dev/null keeps rclone from blocking on a prompt (e.g. an encrypted-config
    # password) under cron. Exit 3 ("directory not found" = repo-missing) is
    # unaffected by these.
    # Durations are env-overridable but the defaults suit a reachability probe.
    out="$("$RCLONE_BIN" "${RCLONE_CONFIG_ARGS[@]+"${RCLONE_CONFIG_ARGS[@]}"}" \
      --contimeout "${RCLONE_PROBE_CONTIMEOUT:-20s}" \
      --timeout "${RCLONE_PROBE_TIMEOUT:-45s}" \
      --retries 1 --low-level-retries 2 \
      lsd "${remote_path}" </dev/null 2>&1)"
    rc=$?
    [[ "$rc" -eq 0 ]] && return 0
    # rclone exit 3 = "directory not found": the remote was reached and answered,
    # the repository path simply does not exist yet (e.g. not "restic init"ed).
    # Flag that distinctly so it is not mislabelled as "target not reachable".
    if [[ "$rc" -eq 3 ]]; then
      REPO_PROBE_STATUS="repo-missing"
    else
      REPO_PROBE_STATUS="unreachable"
    fi
    REPO_UNREACHABLE_REASON="rclone lsd ${remote_path} (config: ${RCLONE_CONFIG_FILE:-rclone default}) exited $rc"
    [[ -n "$out" ]] && REPO_UNREACHABLE_REASON+=$'\n'"$out"
    return 1
  fi
  # Non-rclone repos: no advance check possible, treat as reachable
  return 0
}

# ---------------------------------------------------------------------------
# What this run calls things
#
# runlib runs the same skeleton for every script of the family; these are the
# words that keep THIS script's log and notification its own.
# ---------------------------------------------------------------------------

# shellcheck disable=SC2034  # every name here is read by lib/runlib, not below.
{
  RUN_WHAT="restic push"
  RUN_LOG_NAME="Backup run"
  RUN_UNIT="Repositories"
  RUN_ABORT_HINT="No snapshot was completed for this run; the repositories still hold the previous ones."
  # This script pushes to remote repositories — there is no local tree for
  # anyone to pull, so it publishes no completion marker.
  RUN_USES_MARKER=0
  INSTANCE_LABEL="Instance"
  INSTANCE_LABEL_LC="instance"
  INSTANCE_OPT="--instance"
}

# Telegram credentials: from TELEGRAM_CONF when global.conf points at one,
# otherwise from global.conf itself.
notify_init

# ---------------------------------------------------------------------------
# trap handler
#
# Registered as soon as the Telegram credentials are known, so a configuration
# error from here on also raises an alarm instead of failing silently under
# cron. runlib's handler guards against firing twice: a signal ends in "exit",
# which runs the EXIT trap on its way out, so both handlers would otherwise
# each send their own alarm.
# ---------------------------------------------------------------------------

run_traps

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------

log_info "Starting backup run on $HOSTNAME_SHORT"

# Delete old log files
find "$LOG_DIR" -maxdepth 1 -name 'backup-*.log' -type f \
  -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null \
  && log_info "Old logs (>${LOG_RETENTION_DAYS} days) removed"

# Check rclone configuration (only if rclone targets are configured)
check_rclone_config

# ---------------------------------------------------------------------------
# Repository reachability — evaluated up front for ALL repos, BEFORE the first
# restic call. repo_reachable already classifies each target
# (reachable / repo-missing / unreachable); only reachable repos go into
# REACHABLE_REPOS, and every restic step below (unlock, backup, forget, check)
# operates on that list. This keeps restic from being launched against an
# unreachable target, where it would hang indefinitely.
#
# Policy: an unreachable (or not-yet-initialised) repo is SKIPPED — the other
# repos are still backed up, and the skip is logged as an error so it surfaces
# in the completion notification. Only when NOT A SINGLE repo is reachable is the
# whole run aborted early with its own Telegram message (nothing stopped/backed
# up).
# ---------------------------------------------------------------------------
log_info "--- Checking repository reachability ---"
for idx in "${!REPOS[@]}"; do
  repo="${REPOS[$idx]}"
  rname="${REPO_NAMES[$idx]}"
  if repo_reachable "$repo"; then
    log_info "$rname ($repo): reachable"
    REACHABLE_REPOS+=("$repo")
  else
    if [[ "${REPO_PROBE_STATUS:-}" == "repo-missing" ]]; then
      log_error "$rname ($repo): target reachable, but the repository is not initialised yet — run 'restic ... init' once (see README), then re-run. Skipped."
    else
      log_error "$rname ($repo): not reachable — skipped"
    fi
    if [[ -n "${REPO_UNREACHABLE_REASON:-}" ]]; then
      # Surface the rclone diagnostics (command, exit code, error output) so the
      # user can see *why* — indented under the error, to both log and stdout.
      while IFS= read -r reason_line; do
        printf '        %s\n' "$reason_line" | tee -a "$LOG_FILE"
      done <<< "$REPO_UNREACHABLE_REASON"
    fi
  fi
done

# Abort the whole run only if not a single repo is reachable — there is nothing
# to back up to. Send a dedicated message; run_end suppresses the EXIT trap's
# generic "ABORTED" one.
if [[ "${#REACHABLE_REPOS[@]}" -eq 0 ]]; then
  log_error "No usable repository (all unreachable / not initialised) — aborting. Nothing was backed up."
  telegram_send "$(printf '⛔ [%s] Backup NOT started\n\nNone of the %d configured repositories is reachable.\nNothing was backed up.\n\n--- Log (last 50 lines) ---\n%s' \
    "$HOSTNAME_SHORT" "${#REPOS[@]}" "$(log_tail)")"
  run_end 1
fi

# Unlock all reachable repos (unreachable ones were skipped above, so restic is
# never launched against a dead target here).
for repo in "${REACHABLE_REPOS[@]+"${REACHABLE_REPOS[@]}"}"; do
  if restic_repo "$repo" unlock >>"$LOG_FILE" 2>&1; then
    log_info "$repo: unlock ok"
  else
    log_info "$repo: unlock not possible (maybe not reachable)"
  fi
done

# ---------------------------------------------------------------------------
# 4. Backup
# ---------------------------------------------------------------------------

log_info "--- Backup ---"
if dry_run_enabled; then
  log_info "DRY RUN enabled (DRY_RUN) — restic runs with --dry-run --verbose=2; nothing is written, forget/prune and the monthly check are skipped"
fi
have_jq=0
command -v jq >/dev/null 2>&1 && have_jq=1

# Each repo is backed up with exactly the paths (and their anchored excludes) of
# the instances that target it (one snapshot per repo). The paths/excludes are
# gathered per repo inside the loop from the INST_* records; the union lines
# below are just an overview. Relative excludes were anchored to their instance's
# BACKUP_PATH by load_instances; patterns with a leading "/" are verbatim.
log_info "All backup paths: ${BACKUP_PATHS[*]}"
if [[ "${#EXCLUDE_PATTERNS[@]}" -gt 0 ]]; then
  log_info "All excludes: ${EXCLUDE_PATTERNS[*]}"
fi

for idx in "${!REPOS[@]}"; do
  repo="${REPOS[$idx]}"
  rname="${REPO_NAMES[$idx]}"

  # Skip repos the up-front reachability check marked as unreachable (i.e. not in
  # REACHABLE_REPOS). The skip was already logged there; restic must not run
  # against them. It still gets a line in the summary: the count says "2/3", and
  # a reader must not have to work out which one is missing.
  if ! contains "$repo" "${REACHABLE_REPOS[@]+"${REACHABLE_REPOS[@]}"}"; then
    INSTANCE_RESULTS+=("$rname: SKIPPED (not reachable)")
    continue
  fi

  # Gather the paths and excludes of the instances targeting THIS repo.
  repo_paths=()
  repo_excludes=()
  for i in "${!INST_PATH[@]}"; do
    # INST_TARGETS[i] is a space-separated list of repo names — split without
    # globbing via read -ra, then test membership.
    read -ra inst_tgts <<< "${INST_TARGETS[$i]}"
    contains "$rname" "${inst_tgts[@]+"${inst_tgts[@]}"}" || continue
    repo_paths+=("${INST_PATH[$i]}")
    # INST_EXCLUDES[i] is newline-separated; split and dedup into repo_excludes.
    while IFS= read -r epat; do
      [[ -z "$epat" ]] && continue
      contains "$epat" "${repo_excludes[@]+"${repo_excludes[@]}"}" \
        || repo_excludes+=("$epat")
    done <<< "${INST_EXCLUDES[$i]}"
  done

  repo_start="$(date +%s)"

  if [[ "${#repo_paths[@]}" -eq 0 ]]; then
    log_info "$rname ($repo): no instance targets this repo — skipped"
    continue
  fi

  EXCLUDE_ARGS=()
  for pat in "${repo_excludes[@]+"${repo_excludes[@]}"}"; do
    EXCLUDE_ARGS+=(--exclude "$pat")
  done
  log_info "$rname: backup paths: ${repo_paths[*]}"

  if dry_run_enabled; then
    # Dry run: no snapshot is created. The human-readable per-file verbose output
    # (what restic *would* back up) is sent to BOTH the terminal and the log via
    # tee — so it is visible live on an interactive run, not only in the file.
    # PIPESTATUS[0] keeps restic's exit code (not tee's).
    log_info "$repo: dry-run — listing what would be backed up (output below + in log)"
    restic_repo "$repo" backup \
        "${repo_paths[@]}" \
        "${EXCLUDE_ARGS[@]+"${EXCLUDE_ARGS[@]}"}" \
        --tag "$HOSTNAME_SHORT" \
        --tag "$(date +%Y-%m-%d)" \
        --dry-run --verbose=2 2>&1 | tee -a "$LOG_FILE"
    rc="${PIPESTATUS[0]}"
    if [[ "$rc" -ne 0 ]]; then
      log_error "$repo: dry-run failed (exit $rc)"
      INSTANCE_RESULTS+=("$rname: FAILED (dry-run, exit $rc)")
    else
      log_info "$repo: dry-run ok"
      SUCCESS_TARGETS+=("$repo")
      OK_INSTANCES+=("$rname")
      INSTANCE_RESULTS+=("$rname: ok (dry run — nothing written)")
    fi
    continue
  fi

  # Real run. Stream restic's --json output through progress_filter so an
  # interactive (e.g. initial) run shows that something is happening and how far
  # along it is — one throttled progress line per PROGRESS_INTERVAL seconds — on
  # terminal AND in the log (via tee), without the per-file flood of --verbose=2.
  # The filter stashes the JSON summary line in a temp file for the parsing below;
  # restic's exit code is taken from PIPESTATUS[0] (the trailing awk/tee must not
  # mask it — read it on the very next line, as the dry-run branch does).
  summary_tmp="$(mktemp 2>/dev/null)" || summary_tmp="$LOG_DIR/.summary-$$-$idx"
  : > "$summary_tmp"
  restic_repo "$repo" backup \
      "${repo_paths[@]}" \
      "${EXCLUDE_ARGS[@]+"${EXCLUDE_ARGS[@]}"}" \
      --tag "$HOSTNAME_SHORT" \
      --tag "$(date +%Y-%m-%d)" \
      --json 2>>"$LOG_FILE" \
    | progress_filter "$rname" "$summary_tmp" \
    | tee -a "$LOG_FILE"
  rc="${PIPESTATUS[0]}"
  summary_line="$(cat "$summary_tmp" 2>/dev/null)"
  rm -f "$summary_tmp"

  bytes=0
  snapshot="?"
  if [[ -n "$summary_line" ]]; then
    if [[ "$have_jq" -eq 1 ]]; then
      bytes="$(printf '%s' "$summary_line" | jq -r '.total_bytes_processed // 0')"
      snapshot="$(printf '%s' "$summary_line" | jq -r '(.snapshot_id // "?")[0:8]')"
    else
      bytes="$(printf '%s' "$summary_line" | grep -o '"total_bytes_processed":[0-9]*' | grep -o '[0-9]*')"
      snapshot="$(printf '%s' "$summary_line" | grep -o '"snapshot_id":"[a-f0-9]*"' | grep -o '[a-f0-9]\{8\}' | head -n1)"
      bytes="${bytes:-0}"
      snapshot="${snapshot:-?}"
    fi
  fi

  added="$(json_num "$summary_line" data_added)"
  repo_dur="$(human_duration "$(( $(date +%s) - repo_start ))")"

  if [[ "$rc" -ne 0 ]]; then
    log_error "$repo: backup failed (exit $rc)"
    INSTANCE_RESULTS+=("$rname: FAILED (exit $rc)")
  elif [[ "${bytes:-0}" -eq 0 ]]; then
    log_error "$repo: 0 bytes backed up"
    INSTANCE_RESULTS+=("$rname: FAILED (0 bytes backed up)")
  else
    log_info "$repo: backup successful ($(human_bytes "$bytes"), snapshot $snapshot)"
    # Counts from the summary (overview of what actually changed this run) plus
    # data_added — the deduplicated new data really written to the repo, so it
    # stays small even when many files show up as "new" (e.g. after a path-set
    # change makes restic find no parent snapshot and re-read everything).
    log_info "$repo: files $(json_num "$summary_line" files_new) new, $(json_num "$summary_line" files_changed) changed, $(json_num "$summary_line" files_unmodified) unmodified; $(human_bytes "$added") added"
    SUCCESS_TARGETS+=("$repo")
    OK_INSTANCES+=("$rname")
    INSTANCE_RESULTS+=("$rname: ok — $(human_bytes "$added") added, snapshot $snapshot in $repo_dur")
    # PROCESSED is the same tree for every repo, so take the largest rather than
    # a sum; ADDED really happened once per repo, so it is summed.
    [[ "${bytes:-0}" -gt "$TOTAL_PROCESSED" ]] && TOTAL_PROCESSED="$bytes"
    TOTAL_ADDED=$((TOTAL_ADDED + added))
  fi
done

# ---------------------------------------------------------------------------
# 6. Forget & Prune
# ---------------------------------------------------------------------------

log_info "--- Forget & Prune ---"
if dry_run_enabled; then
  log_info "Skipped (dry run) — no snapshots are removed"
else
  for repo in "${REACHABLE_REPOS[@]+"${REACHABLE_REPOS[@]}"}"; do
    [[ -z "$repo" ]] && continue
    if restic_repo "$repo" forget \
        --tag "$HOSTNAME_SHORT" \
        --keep-daily 31 \
        --keep-monthly 99 \
        --prune >>"$LOG_FILE" 2>&1; then
      log_info "$repo: forget/prune ok"
    else
      log_error "$repo: forget/prune failed"
    fi
  done
fi

# ---------------------------------------------------------------------------
# 7. Repository check (monthly, on the 1st)
# ---------------------------------------------------------------------------

if [[ "$(date +%d)" == "01" ]]; then
  if dry_run_enabled; then
    log_info "--- Repository check (monthly) --- skipped (dry run)"
  else
    log_info "--- Repository check (monthly) ---"
    for repo in "${REACHABLE_REPOS[@]+"${REACHABLE_REPOS[@]}"}"; do
      [[ -z "$repo" ]] && continue
      if restic_repo "$repo" check >>"$LOG_FILE" 2>&1; then
        log_info "$repo: check ok"
      else
        log_error "$repo: repository check failed"
      fi
    done
  fi
fi

# ---------------------------------------------------------------------------
# 8. Completion
# ---------------------------------------------------------------------------

# The three knobs runlib's run_finish reads for a summary that does not fit the
# common "one byte count, one marker" shape:
#   RUN_TOTAL      repositories attempted — this script loops over repos, not
#                  over the loaded instances
#   RUN_DATA_TEXT  restic reads the whole tree every night but writes only the
#                  deduplicated difference; one number would mislead
#   RUN_EXTRA      WHAT was covered — naming the directories makes an instance
#                  that points at a missing path visible, instead of it dropping
#                  out of the run unnoticed.
# shellcheck disable=SC2034  # read by lib/runlib's run_finish.
RUN_TOTAL="${#REPOS[@]}"
# shellcheck disable=SC2034
RUN_DATA_TEXT="$(human_bytes "$TOTAL_PROCESSED") processed, $(human_bytes "$TOTAL_ADDED") added"
# shellcheck disable=SC2034
RUN_EXTRA="Paths: ${BACKUP_PATHS[*]}"$'\n'
dry_run_enabled && RUN_WHAT="$RUN_WHAT [DRY RUN]"

run_finish
