# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# Build arguments
#
# NEXTCLOUD_VERSION   : version to download from the community CDN
# ENTERPRISE_ARCHIVE_URL : if set, download the enterprise zip from this URL instead of the community tarball.
# ---------------------------------------------------------------------------
ARG NEXTCLOUD_VERSION=
ARG ENTERPRISE_ARCHIVE_URL=""

# ---------------------------------------------------------------------------
# Stage: source
# Downloads and extracts the Nextcloud source once, at build time.
# No rsync, no runtime downloads.
# ---------------------------------------------------------------------------
FROM alpine:3.23 AS source

ARG NEXTCLOUD_VERSION
ARG ENTERPRISE_ARCHIVE_URL

RUN apk add --no-cache \
    curl \
    gnupg \
    bzip2 \
    unzip

# Community: download + GPG verify + extract
# Enterprise: download zip (URL already embeds the customer token) + extract
RUN set -ex; \
    mkdir -p /var/www/html; \
    if [ -n "${ENTERPRISE_ARCHIVE_URL}" ]; then \
    echo "==> Downloading Nextcloud Enterprise from ${ENTERPRISE_ARCHIVE_URL}"; \
    curl -fsSL -o /tmp/nextcloud.zip "${ENTERPRISE_ARCHIVE_URL}"; \
    unzip -q /tmp/nextcloud.zip -d /tmp/src/; \
    cp -a /tmp/src/nextcloud/. /var/www/html/; \
    rm /tmp/nextcloud.zip; \
    else \
    echo "==> Downloading Nextcloud Community ${NEXTCLOUD_VERSION}"; \
    curl -fsSL -o /tmp/nextcloud.tar.bz2 \
    "https://github.com/nextcloud-releases/server/releases/download/v${NEXTCLOUD_VERSION}/nextcloud-${NEXTCLOUD_VERSION}.tar.bz2"; \
    curl -fsSL -o /tmp/nextcloud.tar.bz2.asc \
    "https://github.com/nextcloud-releases/server/releases/download/v${NEXTCLOUD_VERSION}/nextcloud-${NEXTCLOUD_VERSION}.tar.bz2.asc"; \
    export GNUPGHOME="$(mktemp -d)"; \
    gpg --batch --keyserver keyserver.ubuntu.com \
    --recv-keys 28806A878AE423A28372792ED75899B9A724937A; \
    gpg --batch --verify /tmp/nextcloud.tar.bz2.asc /tmp/nextcloud.tar.bz2; \
    gpgconf --kill all; \
    rm -rf "${GNUPGHOME}"; \
    tar -xjf /tmp/nextcloud.tar.bz2 -C /tmp/src/; \
    mv /tmp/src/nextcloud /var/www/html; \
    rm /tmp/nextcloud.tar.bz2 /tmp/nextcloud.tar.bz2.asc; \
    fi; \
    # Remove the built-in web updater — updates happen via image rebuild
    rm -rf /var/www/html/updater; \
    # Ensure these dirs exist for first-run volume mount detection
    mkdir -p \
    /var/www/html/data \
    /var/www/html/custom_apps \
    /var/www/html/config \
    /var/www/html/themes; \
    chmod +x /var/www/html/occ

# Copy default config files into the source tree so they land in the image
COPY config/ /var/www/html/config/

# ---------------------------------------------------------------------------
# Stage: final
# ---------------------------------------------------------------------------
FROM php:8.4-apache-trixie

ENV PHP_MEMORY_LIMIT=512M \
    PHP_UPLOAD_LIMIT=512M \
    PHP_OPCACHE_MEMORY_CONSUMPTION=128 \
    APACHE_BODY_LIMIT=1073741824

RUN set -ex; \
    savedAptMark="$(apt-mark showmanual)"; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
    # entrypoint.sh and cron.sh dependencies
    busybox-static \
    bzip2 \
    libldap-common \
    libmagickcore-7.q16-10-extra \
    # install the PHP extensions we need
    # see https://docs.nextcloud.com/server/stable/admin_manual/installation/source_installation.html
    libcurl4-openssl-dev \
    libevent-dev \
    libfreetype6-dev \
    libgmp-dev \
    libicu-dev \
    libjpeg-dev \
    libldap2-dev \
    liblz4-dev \
    libmagickwand-dev \
    libmemcached-dev \
    libpng-dev \
    libpq-dev \
    libwebp-dev \
    libxml2-dev \
    libzip-dev \
    ; \
    debMultiarch="$(dpkg-architecture --query DEB_BUILD_MULTIARCH)"; \
    docker-php-ext-configure ftp --with-ftp-ssl; \
    docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp; \
    docker-php-ext-configure ldap --with-libdir="lib/${debMultiarch}"; \
    docker-php-ext-install -j "$(nproc)" \
    bcmath \
    exif \
    ftp \
    gd \
    gmp \
    intl \
    ldap \
    opcache \
    pcntl \
    pdo_mysql \
    pdo_pgsql \
    sysvsem \
    zip \
    ; \
    # pecl will claim success even if one install fails, so we need to perform each install separately
    pecl install APCu-5.1.28; \
    pecl install igbinary-3.2.16; \
    pecl install imagick-3.8.1; \
    pecl install --configureoptions 'enable-memcached-igbinary="yes"' \
    memcached-3.4.0; \
    pecl install --configureoptions 'enable-redis-igbinary="yes" enable-redis-zstd="yes" enable-redis-lz4="yes"' \
    redis-6.3.0; \
    docker-php-ext-enable \
    apcu \
    igbinary \
    imagick \
    memcached \
    opcache \
    redis \
    ; \
    rm -r /tmp/pear; \
    # reset apt-mark's "manual" list so that "purge --auto-remove" will remove all build dependencies
    apt-mark auto '.*' > /dev/null; \
    apt-mark manual $savedAptMark; \
    ldd "$(php -r 'echo ini_get("extension_dir");')"/*.so \
    | awk '/=>/ { so = $(NF-1); if (index(so, "/usr/local/") == 1) { next }; gsub("^/(usr/)?", "", so); print so }' \
    | sort -u \
    | xargs -rt dpkg-query --search \
    # https://manpages.debian.org/trixie/dpkg/dpkg-query.1.en.html#S (we ignore diversions and it'll be really unusual for more than one package to provide any given .so file)
    | awk 'sub(":$", "", $1) { print $1 }' \
    | sort -u \
    | xargs -rt apt-mark manual; \
    apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# set recommended PHP.ini settings
# see https://docs.nextcloud.com/server/latest/admin_manual/installation/server_tuning.html#enable-php-opcache
RUN { \
    echo 'opcache.enable=1'; \
    echo 'opcache.interned_strings_buffer=32'; \
    echo 'opcache.max_accelerated_files=10000'; \
    echo 'opcache.memory_consumption=${PHP_OPCACHE_MEMORY_CONSUMPTION}'; \
    echo 'opcache.save_comments=1'; \
    echo 'opcache.revalidate_freq=60'; \
    echo 'opcache.jit=1255'; \
    echo 'opcache.jit_buffer_size=8M'; \
    } > "${PHP_INI_DIR}/conf.d/opcache-recommended.ini"; \
    \
    echo 'apc.enable_cli=1' >> "${PHP_INI_DIR}/conf.d/docker-php-ext-apcu.ini"; \
    \
    { \
    echo 'apc.serializer=igbinary'; \
    echo 'session.serialize_handler=igbinary'; \
    } >> "${PHP_INI_DIR}/conf.d/docker-php-ext-igbinary.ini"; \
    \
    { \
    echo 'memory_limit=${PHP_MEMORY_LIMIT}'; \
    echo 'upload_max_filesize=${PHP_UPLOAD_LIMIT}'; \
    echo 'post_max_size=${PHP_UPLOAD_LIMIT}'; \
    } > "${PHP_INI_DIR}/conf.d/nextcloud.ini";

# ---- Apache ----------------------------------------------------------------
RUN a2enmod headers rewrite remoteip; \
    { \
    echo 'RemoteIPHeader X-Real-IP'; \
    echo 'RemoteIPInternalProxy 10.0.0.0/8'; \
    echo 'RemoteIPInternalProxy 172.16.0.0/12'; \
    echo 'RemoteIPInternalProxy 192.168.0.0/16'; \
    } > /etc/apache2/conf-available/remoteip.conf; \
    a2enconf remoteip; \
    { \
    echo 'LimitRequestBody ${APACHE_BODY_LIMIT}'; \
    } > /etc/apache2/conf-available/apache-limits.conf; \
    a2enconf apache-limits

# ---- cron ------------------------------------------------------------------
RUN mkdir -p /var/spool/cron/crontabs; \
    echo '*/5 * * * * php -f /var/www/html/cron.php' > /var/spool/cron/crontabs/www-data

# ---- hook directories ------------------------------------------------------
RUN mkdir -p \
    /docker-entrypoint-hooks.d/pre-installation \
    /docker-entrypoint-hooks.d/post-installation \
    /docker-entrypoint-hooks.d/pre-upgrade \
    /docker-entrypoint-hooks.d/post-upgrade \
    /docker-entrypoint-hooks.d/before-starting

# ---- Nextcloud source (from build stage) -----------------------------------
# The code is baked into the image — no VOLUME on /var/www/html.
# Only user-data directories are declared as volumes so they persist across
# image updates without touching the application code.
COPY --from=source --chown=www-data:root /var/www/html /var/www/html

# Reference copy of default config files, outside the volume.
# Used by the entrypoint to warn if the persistent config volume contains
# stale files that differ from the current image defaults.
COPY --from=source /var/www/html/config /usr/src/nextcloud-config

RUN chmod -R g=u /var/www/html

# Persistent data: only what the user actually modifies at runtime.
# The application code in /var/www/html is part of the image and is
# replaced atomically on every `docker pull` + restart — no rsync needed.
VOLUME /var/www/html/config
VOLUME /var/www/html/data
VOLUME /var/www/html/custom_apps
VOLUME /var/www/html/themes

COPY docker-entrypoint.sh /docker-entrypoint.sh
COPY cron.sh /cron.sh
RUN chmod +x /docker-entrypoint.sh /cron.sh

ARG NEXTCLOUD_VERSION
ARG ENTERPRISE_ARCHIVE_URL
ENV NEXTCLOUD_VERSION=${NEXTCLOUD_VERSION}
# Expose whether this is an enterprise build for informational purposes
ENV NEXTCLOUD_EDITION=${ENTERPRISE_ARCHIVE_URL:+enterprise}
ENV NEXTCLOUD_EDITION=${NEXTCLOUD_EDITION:-community}

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["apache2-foreground"]
