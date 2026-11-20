# Baïkal on the official PHP Apache image — the warm standby of backup-dav.
#
# Our own build, because no maintained image ships Baïkal 0.13 (see
# README.md). That makes PHP security updates our job: rebuild monthly with
#   docker compose build --pull && docker compose up -d
# and straight away on a critical PHP CVE, then run
#   backup-dav-standby.sh --self-test
#
# Updating Baïkal: read the release notes first, then change BAIKAL_VERSION and
# BAIKAL_SHA256 together (the sha256 GitHub shows for the release asset) and
# the image tag in docker-compose.yml. A file that does not match the checksum
# fails the build.
#
# The base tag pins the PHP minor version AND the Debian release, so neither
# moves under a rebuild; never "latest".
FROM php:8.4-apache-trixie

ARG BAIKAL_VERSION=0.13.0
ARG BAIKAL_SHA256=81e74df123230e863f608d228fdd7b9a1a788f60b04d37e6973c302192e83f32

COPY apache-baikal.vhost /etc/apache2/sites-available/000-default.conf
COPY php-baikal.ini /usr/local/etc/php/conf.d/zz-baikal.ini
COPY baikal-entrypoint.sh /usr/local/bin/baikal-entrypoint

# sqlite3 stays in the image: "sqlite3 db.sqlite .backup …" is the consistent
# copy of the database while clients write to it (emergency, README.md).
# The COPYs above keep the mode the files have in the build context, which
# mutagen sets to 0600 — hence the chmod.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends sqlite3 unzip; \
    curl -fsSL -o /tmp/baikal.zip \
      "https://github.com/sabre-io/Baikal/releases/download/${BAIKAL_VERSION}/baikal-${BAIKAL_VERSION}.zip"; \
    echo "${BAIKAL_SHA256}  /tmp/baikal.zip" | sha256sum -c -; \
    unzip -q /tmp/baikal.zip -d /var/www; \
    rm /tmp/baikal.zip; \
    apt-get purge -y --auto-remove unzip; \
    rm -rf /var/lib/apt/lists/*; \
    cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"; \
    chmod 0644 /etc/apache2/sites-available/000-default.conf /usr/local/etc/php/conf.d/zz-baikal.ini; \
    chmod 0755 /usr/local/bin/baikal-entrypoint; \
    sed -i 's/^ServerTokens .*/ServerTokens Prod/; s/^ServerSignature .*/ServerSignature Off/' \
      /etc/apache2/conf-available/security.conf; \
    a2enmod rewrite; \
    php -m | grep -qix pdo_sqlite; \
    apache2ctl -t

# Setting ENTRYPOINT clears the CMD inherited from the base image: repeat it.
ENTRYPOINT ["baikal-entrypoint"]
CMD ["apache2-foreground"]
