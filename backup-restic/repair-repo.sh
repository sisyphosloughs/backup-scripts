#!/usr/bin/env bash
# repair-repo.sh — check and repair a restic repository from repos.conf
#
# For MANUAL use as root, when backup-restic reports a damaged repository
# (e.g. "pack size does not match calculated size from index" during prune).
# Uses the same global.conf as backup-restic.sh (RESTIC_BIN, RCLONE_BIN,
# RCLONE_CONFIG_FILE, RESTIC_PASSWORD_FILE, REPOS_FILE), so it opens the
# repository exactly the way the nightly run does.
#
# Usage:
#   repair-repo.sh <repo>                 guided repair (asks before each change)
#   repair-repo.sh <repo> <step> [arg]    run a single step
#
#   <repo>   a name from repos.conf (e.g. "pcloud") or a repository URL
#
# Steps:
#   check              structure check (read-only)
#   verify [subset]    check plus reading pack data, default subset 5%
#   unlock             remove stale locks
#   repair-index       rebuild the index from the packs actually present
#   repair-snapshots   rewrite snapshots that reference missing data (--forget)
#   prune              remove unreferenced data
#   backup             run backup-restic.sh (re-uploads blobs still on disk)
#
# Guided sequence: unlock → check → repair-index → backup → check
#   → (only if still broken) repair-snapshots → prune → check → verify
#
# Output goes to the terminal and to logs/repair-<timestamp>.log. The prefix
# "repair" deliberately differs from "backup", so log_rotate of backup-restic
# leaves these files alone.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ROOT_DIR is read by global.conf (TELEGRAM_CONF="$ROOT_DIR/telegram.conf").
# shellcheck disable=SC2034
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GLOBAL_CONF="$SCRIPT_DIR/global.conf"
LOG_DIR="$SCRIPT_DIR/logs"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

[[ $# -ge 1 ]] || usage 1
case "$1" in -h|--help) usage 0 ;; esac
[[ $EUID -eq 0 ]] || die "must be run as root (the repository password and rclone.conf are root-readable only)"

[[ -r "$GLOBAL_CONF" ]] || die "global.conf not readable: $GLOBAL_CONF"
# shellcheck source=/dev/null
source "$GLOBAL_CONF"
: "${RESTIC_BIN:=restic}"
: "${RCLONE_BIN:=rclone}"
[[ -n "${REPOS_FILE:-}" ]]           || die "REPOS_FILE not set (global.conf)"
[[ -n "${RESTIC_PASSWORD_FILE:-}" ]] || die "RESTIC_PASSWORD_FILE not set (global.conf)"
command -v "$RESTIC_BIN" >/dev/null 2>&1 || die "restic not found: '$RESTIC_BIN'"

# Progress: restic draws its progress bar only on a terminal, and our output
# goes through tee. RESTIC_PROGRESS_FPS makes it print a plain line per frame
# even then — one every PROGRESS_INTERVAL seconds (same knob as backup-restic.sh,
# default 30; 0 = no progress lines). An FPS already set in the environment wins.
: "${PROGRESS_INTERVAL:=30}"
if [[ -z "${RESTIC_PROGRESS_FPS:-}" && "$PROGRESS_INTERVAL" =~ ^[0-9]+$ && "$PROGRESS_INTERVAL" -gt 0 ]]; then
  RESTIC_PROGRESS_FPS="$(awk -v s="$PROGRESS_INTERVAL" 'BEGIN { printf "%.6f", 1 / s }')"
  export RESTIC_PROGRESS_FPS
fi

# --- resolve <repo> -----------------------------------------------------------
# Same two line forms as backup-restic.sh: "<name> = <url>" or a bare URL.
resolve_repo() {
  local want="$1" line name url
  [[ -r "$REPOS_FILE" ]] || { printf '%s\n' "$want"; return; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ -n "$line" ]] || continue
    if [[ "$line" == *=* ]]; then
      name="$(printf '%s' "${line%%=*}" | sed 's/[[:space:]]*$//')"
      url="$(printf '%s' "${line#*=}" | sed 's/^[[:space:]]*//')"
    else
      name="$line"; url="$line"
    fi
    if [[ "$name" == "$want" || "$url" == "$want" ]]; then
      printf '%s\n' "$url"; return
    fi
  done < "$REPOS_FILE"
  # Not in repos.conf: accept it only if it looks like a URL or path.
  case "$want" in
    */*|*:*) printf '%s\n' "$want" ;;
    *) return 1 ;;
  esac
}

REPO="$(resolve_repo "$1")" || die "'$1' is neither a name in $REPOS_FILE nor a repository URL"
shift
STEP="${1:-guided}"
STEP_ARG="${2:-}"

# --- logging ------------------------------------------------------------------
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/repair-$(date +%Y-%m-%dT%H-%M-%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
chmod 644 "$LOG_FILE" 2>/dev/null || true

say() { printf '\n%s ==> %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# --- lock ---------------------------------------------------------------------
# The same lock file as backup-restic.sh, so a repair never runs alongside the
# nightly backup (restic would refuse anyway, but with a less clear message).
LOCK_FILE="$LOG_DIR/.lock"
lock() {
  command -v flock >/dev/null 2>&1 || return 0
  exec 9>>"$LOCK_FILE"
  flock -n 9 || die "backup-restic is running (lock: $LOCK_FILE) — try again later"
}
unlock_fd() {
  command -v flock >/dev/null 2>&1 || return 0
  flock -u 9 2>/dev/null; exec 9>&-
}

# --- restic -------------------------------------------------------------------
# Mirrors restic_repo() in backup-restic.sh, including the rclone.args default.
restic_repo() {
  local opts=()
  if [[ "$REPO" == rclone:* ]]; then
    opts+=(-o "rclone.program=$RCLONE_BIN")
    if [[ -n "${RCLONE_CONFIG_FILE:-}" ]]; then
      opts+=(-o "rclone.args=serve restic --stdio --b2-hard-delete --config $RCLONE_CONFIG_FILE")
    fi
  fi
  printf '$ %s' "$RESTIC_BIN"; printf ' %s' "${opts[@]+"${opts[@]}"}" --repo "$REPO" "$@"; printf '\n'
  "$RESTIC_BIN" "${opts[@]+"${opts[@]}"}" --repo "$REPO" \
    --password-file "$RESTIC_PASSWORD_FILE" "$@"
}

confirm() {
  local answer
  read -r -p "$* [y/N] " answer < /dev/tty
  [[ "$answer" == [yYjJ]* ]]
}

step_unlock()           { say "unlock (stale locks only)"; restic_repo unlock; }
step_check()            { say "check (structure)"; restic_repo check; }
step_verify()           { local s="${1:-5%}"; say "check --read-data-subset=$s"; restic_repo check --read-data-subset="$s"; }
step_repair_index()     { say "repair index"; restic_repo repair index; }
step_repair_snapshots() { say "repair snapshots --forget"; restic_repo repair snapshots --forget; }
step_prune()            { say "prune"; restic_repo prune; }
step_backup() {
  say "backup-restic.sh (re-uploads blobs that are still on disk)"
  # backup-restic.sh takes the same lock — release ours for the duration.
  unlock_fd
  "$SCRIPT_DIR/backup-restic.sh"
  local rc=$?
  lock
  return "$rc"
}

guided() {
  echo "Repository: $REPO"
  echo "Log:        $LOG_FILE"

  step_unlock
  if step_check; then
    echo
    echo "check reports no errors."
    if confirm "Read a 5% data subset as well (finds truncated packs check misses)?"; then
      step_verify 5%
    fi
    return
  fi

  echo
  echo "check found errors (see above)."
  confirm "Rebuild the index from the packs actually present (repair index)?" || return 1
  step_repair_index || die "repair index failed"

  echo
  echo "Data from damaged packs is now marked missing. A backup run re-uploads"
  echo "every missing blob whose source file still exists on disk."
  if confirm "Run backup-restic.sh now?"; then
    step_backup || echo "backup-restic.sh reported errors — continuing with check"
  fi

  if step_check; then
    echo
    echo "Repository is consistent again."
  else
    echo
    echo "Snapshots still reference data that no longer exists anywhere."
    echo "repair snapshots --forget removes the affected FILES from those snapshots"
    echo "(the snapshots themselves stay; the originals are kept as backup until prune)."
    confirm "Run repair snapshots --forget?" || return 1
    step_repair_snapshots || die "repair snapshots failed"
    step_check || die "check still fails after repair snapshots — inspect manually"
  fi

  if confirm "Run prune now (frees the space of removed snapshots)?"; then
    step_prune || die "prune failed"
  fi
  if confirm "Read a 5% data subset to look for further damaged packs?"; then
    step_verify 5%
  fi
}

lock
rc=0
case "$STEP" in
  guided)           guided || rc=$? ;;
  check)            step_check || rc=$? ;;
  verify)           step_verify "$STEP_ARG" || rc=$? ;;
  unlock)           step_unlock || rc=$? ;;
  repair-index)     step_repair_index || rc=$? ;;
  repair-snapshots) step_repair_snapshots || rc=$? ;;
  prune)            step_prune || rc=$? ;;
  backup)           step_backup || rc=$? ;;
  *) die "unknown step '$STEP' (see --help)" ;;
esac
say "done (exit $rc) — log: $LOG_FILE"
exit "$rc"
