FROM nextcloud:31.0.9-fpm

RUN set -ex; \
    \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ffmpeg \
        procps \
        supervisor \
#       ghostscript \
#       libreoffice \
#       smbclient \
    ; \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

RUN set -ex; \
    \
    savedAptMark="$(apt-mark showmanual)"; \
    \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        libbz2-dev \
        libkrb5-dev \
#       libsmbclient-dev \
    ; \
    \
    docker-php-ext-install \
        bz2 \
    ; \
#   pecl install smbclient; \
#   docker-php-ext-enable smbclient; \
    \
# reset apt-mark's "manual" list so that "purge --auto-remove" will remove all build dependencies
    apt-mark auto '.*' > /dev/null; \
    apt-mark manual $savedAptMark; \
    ldd "$(php -r 'echo ini_get("extension_dir");')"/*.so \
        | awk '/=>/ { so = $(NF-1); if (index(so, "/usr/local/") == 1) { next }; gsub("^/(usr/)?", "", so); print so }' \
        | sort -u \
        | xargs -r dpkg-query --search \
        | cut -d: -f1 \
        | sort -u \
        | xargs -rt apt-mark manual; \
    \
    apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

RUN mkdir -p \
    /var/log/supervisord \
    /var/run/supervisord \
    ; \
    sed -e '/stream_get_contents($pipes\[1\])/i\stream_set_blocking($pipes\[1\], 0);' -e '/stream_get_contents($pipes\[2\])/i\stream_set_blocking($pipes\[2\], 0);' -i /usr/src/nextcloud/lib/private/Preview/Movie.php ; \
    sed -e "s/user='www-data'/user='root'/g" -e "s/group='www-data'/group='root'/g" -i /entrypoint.sh ; \
    rm -rf /var/spool/cron/crontabs/www-data \
;

COPY supervisord.conf /

ENV NEXTCLOUD_UPDATE=1

CMD ["/usr/bin/supervisord", "-c", "/supervisord.conf"]
