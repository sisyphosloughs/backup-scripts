#!/usr/bin/env bash
#
# backup-wrapper.example.sh — template for the scheduler's single entry point.
#
# Copy it to backup-wrapper.sh next to it (gitignored and not synced: the
# stages and their paths are the host's own), keep the lines this host needs,
# and point root's crontab or the task scheduler at the copy. No logic on
# purpose: each script locks, logs and reports for itself, and a failed stage
# must not keep the next one from running — backup-restic still backs up what
# the producers left, under their previous markers.

# --- a source host (milos): producers first, then the restic stage ----------
/home/shanty/backup-scripts/backup-docker-db/backup-docker-db.sh
/home/shanty/backup-scripts/backup-tar/backup-tar.sh
/home/shanty/backup-scripts/backup-restic/backup-restic.sh

# --- a backup host (ikaria): pull the remote trees, then back staging up -----
# /volume1/scripts/backup-scripts/backup-rclone-sync/backup-rclone-sync.sh
# /volume1/scripts/backup-scripts/backup-restic/backup-restic.sh
