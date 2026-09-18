#!/usr/bin/env bash

# This script is a wrapper for backup-restic.sh that ensures it runs within a tmux session.
# tmux must be installed and available in the PATH for this script to work.

set -uo pipefail

SESSION="restic-backup"

# Not in tmux yet? -> start session and re-execute this script within it
if [[ -z "${TMUX:-}" ]]; then
    exec tmux new-session -A -s "$SESSION" -c "$PWD" "$0"
fi

# From here on, we run within the tmux session
trap 'unset RCLONE_CONFIG_PASS' EXIT

IFS= read -rs -p "Enter password: " RCLONE_CONFIG_PASS
echo
export RCLONE_CONFIG_PASS

"$(dirname "$0")/backup-restic.sh"
status=$?

echo
read -rp "Backup completed (exit code: $status). Press Enter to close…"
exit "$status"