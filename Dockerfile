ARG DISTRO=debian
ARG DISTRO_VARIANT=bullseye
ARG PHP_VERSION=php82

FROM docker.io/wyveo/nginx-php-fpm:${PHP_VERSION}
LABEL maintainer="Dave Conroy (github.com/tiredofit)"

ARG OSTICKET_VERSION
ARG OSTICKET_PLUGINS_VERSION

ENV OSTICKET_VERSION=${OSTICKET_VERSION:-"v1.18"} \
    OSTICKET_PLUGINS_VERSION=${OSTICKET_PLUGINS_VERSION:-"develop"} \
    OSTICKET_REPO_URL=${OSTICKET_REPO_URL:-"https://github.com/osticket/osticket"} \
    OSTICKET_PLUGINS_REPO_URL=${OSTICKET_PLUGINS_REPO_URL:-"https://github.com/CubedCon/osTicket-plugins"} \
    DB_PREFIX=ost_ \
    DB_PORT=3306 \
    CRON_INTERVAL=10 \
    MEMCACHE_PORT=11211 \
    PHP_ENABLE_CURL=TRUE \
    PHP_ENABLE_FILEINFO=TRUE \
    PHP_ENABLE_IMAP=TRUE \
    PHP_ENABLE_LDAP=TRUE \
    PHP_ENABLE_MYSQLI=TRUE \
    PHP_ENABLE_OPENSSL=FALSE \
    PHP_ENABLE_CREATE_SAMPLE_PHP=FALSE \
    PHP_ENABLE_ZIP=TRUE \
    NGINX_SITE_ENABLED=osticket \
    NGINX_WEBROOT=/www/osticket \
    ZABBIX_AGENT_TYPE=classic \
    IMAGE_NAME="CubedCon/osticket" \
    IMAGE_REPO_URL="https://github.com/CubedCon/docker-osticket/"

# Define sane defaults for nginx user/group used by base image
ENV NGINX_USER=${NGINX_USER:-nginx} NGINX_GROUP=${NGINX_GROUP:-nginx}

### Dependency Installation (detect package manager)
RUN set -xe; \
    if command -v apk >/dev/null 2>&1; then \
      apk update && \
      apk upgrade && \
      apk add --no-cache \
          git \
          openldap \
          openssl \
          php82-pecl-memcached \
          tar \
          wget \
          zlib \
      ; \
    elif command -v apt-get >/dev/null 2>&1; then \
      export DEBIAN_FRONTEND=noninteractive; \
      apt-get update && \
      if apt-cache show php8.2-memcached >/dev/null 2>&1; then PHP_MEMCACHED_PKG=php8.2-memcached; else PHP_MEMCACHED_PKG=php-memcached; fi; \
      apt-get install -y --no-install-recommends \
          git \
          libldap-common \
          openssl \
          "$PHP_MEMCACHED_PKG" \
          tar \
          wget \
          zlib1g \
      && rm -rf /var/lib/apt/lists/*; \
    else \
      echo "Unsupported base image: no apk or apt-get found" >&2; exit 127; \
    fi && \
    git clone --depth 1 --branch "${OSTICKET_VERSION}" "${OSTICKET_REPO_URL}" /assets/install && \
    chown -R "${NGINX_USER}":"${NGINX_GROUP}" /assets/install && \
    chmod -R a+rX /assets/install/ && \
    chmod -R u+rw /assets/install/ && \
    mv /assets/install/setup /assets/install/setup_hidden && \
    chown -R root:root /assets/install/setup_hidden && \
    chmod 700 /assets/install/setup_hidden

### Setup Official Plugins
RUN set -x && \
    git clone --depth 1 --branch "${OSTICKET_PLUGINS_VERSION}" "${OSTICKET_PLUGINS_REPO_URL}" /usr/src/plugins && \
    cd /usr/src/plugins && \
    php make.php hydrate && \
    for plugin in $(find * -maxdepth 0 -type d ! -name doc ! -name lib); do cp -r ${plugin} /assets/install/include/plugins; done; \
    cp -R /usr/src/plugins/*.phar /assets/install/include/plugins/ && \
    cd /

### Add Community Plugins
RUN set -x; \
    clone_auto() { \
      url="$1"; dest="$2"; \
      # Try to detect default branch (HEAD) then fallback to master/main \
      det_branch=""; \
      head_line=$(git ls-remote --symref "$url" HEAD 2>/dev/null | awk '/^ref:/ {print $2}'); \
      if [ -n "$head_line" ]; then det_branch=${head_line##refs/heads/}; fi; \
      if [ -n "$det_branch" ]; then \
        git clone --depth 1 --single-branch --branch "$det_branch" "$url" "$dest" 2>/dev/null || true; \
      fi; \
      if [ ! -d "$dest/.git" ]; then \
        git clone --depth 1 --single-branch --branch master "$url" "$dest" 2>/dev/null || \
        git clone --depth 1 --single-branch --branch main "$url" "$dest"; \
      fi; \
    }; \
    clone_auto https://github.com/clonemeagain/osticket-plugin-archiver /assets/install/include/plugins/archiver && \
    clone_auto https://github.com/clonemeagain/attachment_preview /assets/install/include/plugins/attachment-preview && \
    clone_auto https://github.com/clonemeagain/plugin-autocloser /assets/install/include/plugins/auto-closer && \
    clone_auto https://github.com/bkonetzny/osticket-fetch-note /assets/install/include/plugins/fetch-note && \
    clone_auto https://github.com/Micke1101/OSTicket-plugin-field-radiobuttons /assets/install/include/plugins/field-radiobuttons && \
    clone_auto https://github.com/clonemeagain/osticket-plugin-mentioner /assets/install/include/plugins/mentioner && \
    clone_auto https://github.com/philbertphotos/osticket-multildap-auth /assets/install/include/plugins/multi-ldap && \
    if [ -d /assets/install/include/plugins/multi-ldap/multi-ldap ]; then \
      mv /assets/install/include/plugins/multi-ldap/multi-ldap/* /assets/install/include/plugins/multi-ldap/ && \
      rm -rf /assets/install/include/plugins/multi-ldap/multi-ldap; \
    fi && \
    clone_auto https://github.com/clonemeagain/osticket-plugin-preventautoscroll /assets/install/include/plugins/prevent-autoscroll && \
    clone_auto https://github.com/clonemeagain/plugin-fwd-rewriter /assets/install/include/plugins/rewriter && \
    clone_auto https://github.com/clonemeagain/osticket-slack /assets/install/include/plugins/slack && \
    clone_auto https://github.com/ipavlovi/osTicket-Microsoft-Teams-plugin /assets/install/include/plugins/teams

### Log Miscellany Installation and Cleanup
RUN set -x; \
    touch /var/log/msmtp.log && \
    chown "${NGINX_USER}":"${NGINX_GROUP}" /var/log/msmtp.log && \
    if command -v apk >/dev/null 2>&1; then \
      apk del --no-cache git || true; \
    elif command -v apt-get >/dev/null 2>&1; then \
      export DEBIAN_FRONTEND=noninteractive; \
      apt-get purge -y git || true; \
      apt-get autoremove -y || true; \
      rm -rf /var/lib/apt/lists/*; \
    fi && \
    rm -rf \
            /root/.composer \
            /tmp/* \
            /usr/src/*

COPY install /
