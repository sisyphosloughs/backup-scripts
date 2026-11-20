#!/bin/sh
#
# baikal-entrypoint — prepares the two bind mounts, then starts Apache the way
# the base image does.
#
# The host directories arrive empty on the first start and hide what the
# release zip has there. Baïkal's setup wizard does not create Specific/db/
# itself (it stops with "the FOLDER containing the DB file is not writable"),
# and both trees must belong to www-data. The database holds every account's
# appointments and contacts, config/ the admin password hash: no access for
# others.
set -eu

B=/var/www/baikal
mkdir -p "$B/config" "$B/Specific/db"
chown -R www-data:www-data "$B/config" "$B/Specific"
chmod 0750 "$B/config" "$B/Specific" "$B/Specific/db"

exec docker-php-entrypoint "$@"
