#!/usr/bin/env bash

# Datenbank sichern
/home/shanty/backup-scripts/backup-docker-db/backup-docker-db.sh

# Tar-Backups erzeugen
/home/shanty/backup-scripts/backup-tar/backup-tar.sh

# Daten remote sichern
/home/shanty/backup-scripts/backup-restic-push/backup-restic-push.sh
