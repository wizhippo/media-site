#syntax=docker/dockerfile:1.4

# https://github.com/dunglas/symfony-docker

# The different stages of this Dockerfile are meant to be built into separate images
# https://docs.docker.com/develop/develop-images/multistage-build/#stop-at-a-specific-build-stage
# https://docs.docker.com/compose/compose-file/#target

# https://docs.docker.com/engine/reference/builder/#understand-how-arg-and-from-interact
ARG PHP_VERSION=8.1
ARG CADDY_VERSION=2.7

# Builder images
FROM composer/composer:2-bin AS composer

FROM mlocati/php-extension-installer:latest AS php_extension_installer

FROM caddy:${CADDY_VERSION}-builder-alpine AS app_caddy_builder

RUN xcaddy build \
	--with github.com/dunglas/mercure/caddy \
	--with github.com/dunglas/vulcain/caddy

# Prod image
FROM php:${PHP_VERSION}-fpm AS app_php

ENV APP_ENV=prod

WORKDIR /srv/app

# php extensions installer: https://github.com/mlocati/docker-php-extension-installer
COPY --from=php_extension_installer --link /usr/bin/install-php-extensions /usr/local/bin/

# persistent / runtime deps
RUN apt-get update -q -y \
  && apt-get dist-upgrade -q -y \
  && apt-get install -q -y --no-install-recommends \
    ca-certificates \
    acl \
    libfcgi-bin \
    file \
    gettext \
    unzip \
    git \
  && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
  install-php-extensions \
    apcu \
    intl \
    opcache \
    zip \
    bcmath \
    exif \
    gd \
    imagick \
    xsl \
    pcntl \
    igbinary \
    memcached \
    redis \
    ;

###> recipes ###
###> doctrine/doctrine-bundle ###
RUN set -eux; \
  install-php-extensions \
    mysqli \
    pdo_mysql \
    pdo_pgsql \
    ;
###< doctrine/doctrine-bundle ###
###< recipes ###

RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"
COPY --link docker/php/conf.d/zz-app.ini $PHP_INI_DIR/conf.d/
COPY --link docker/php/conf.d/zz-app.prod.ini $PHP_INI_DIR/conf.d/

COPY --link docker/php/php-fpm.d/zz-docker.conf /usr/local/etc/php-fpm.d/zz-docker.conf
RUN mkdir -p /var/run/php

COPY --link docker/php/docker-healthcheck.sh /usr/local/bin/docker-healthcheck
RUN chmod +x /usr/local/bin/docker-healthcheck

HEALTHCHECK --interval=10s --timeout=3s --retries=3 CMD ["docker-healthcheck"]

COPY --link docker/php/docker-entrypoint.sh /usr/local/bin/docker-entrypoint
RUN chmod +x /usr/local/bin/docker-entrypoint

ENTRYPOINT ["docker-entrypoint"]
CMD ["php-fpm"]

# https://getcomposer.org/doc/03-cli.md#composer-allow-superuser
ENV COMPOSER_ALLOW_SUPERUSER=1
ENV PATH="${PATH}:/root/.composer/vendor/bin"

COPY --from=composer --link /composer /usr/bin/composer

## prevent the reinstallation of vendors at every changes in the source code
COPY --link composer.* symfony.* ./
RUN set -eux; \
  if [ -f composer.json ]; then \
  composer install --prefer-dist --no-dev --no-autoloader --no-scripts --no-progress; \
  composer clear-cache; \
  fi

# copy sources
COPY --link  . ./
RUN rm -Rf docker/

# Required for ibexa storage
RUN mkdir -p public/var

RUN set -eux; \
	mkdir -p var/cache var/log; \
  if [ -f composer.json ]; then \
  composer dump-autoload --classmap-authoritative --no-dev; \
  composer dump-env prod; \
  composer run-script --no-dev --no-interaction post-install-cmd; \
  chmod +x bin/console; sync; \
  fi

# Dev image
FROM app_php AS app_php_dev

ENV APP_ENV=dev XDEBUG_MODE=off

RUN rm "$PHP_INI_DIR/conf.d/zz-app.prod.ini"; \
	mv "$PHP_INI_DIR/php.ini" "$PHP_INI_DIR/php.ini-production"; \
	mv "$PHP_INI_DIR/php.ini-development" "$PHP_INI_DIR/php.ini"

COPY --link docker/php/conf.d/zz-app.dev.ini $PHP_INI_DIR/conf.d/

RUN set -eux; \
	install-php-extensions \
    	xdebug \
    ;

RUN rm -f .env.local.php

# Install Node.js and Yarn
RUN apt-get update -q -y \
  && apt-get install -q -y --no-install-recommends gnupg \
  && curl -sL https://deb.nodesource.com/setup_18.x | bash - \
  && apt-get install -y nodejs \
  && curl -sL https://dl.yarnpkg.com/debian/pubkey.gpg | apt-key add - \
  && echo "deb https://dl.yarnpkg.com/debian/ stable main" | tee /etc/apt/sources.list.d/yarn.list \
  && apt-get update && apt-get install yarn \
  && rm -rf /var/lib/apt/lists/*

# Caddy image
FROM caddy:${CADDY_VERSION}-alpine AS app_caddy

WORKDIR /srv/app

COPY --from=app_caddy_builder --link /usr/bin/caddy /usr/bin/caddy
COPY --from=app_php --link /srv/app/public public/
COPY --link docker/caddy/Caddyfile /etc/caddy/Caddyfile

# Solr image
FROM solr:8.11-slim AS app_solr

USER root

COPY --from=app_php --link /srv/app/vendor/ibexa/solr/src/lib/Resources/config/solr/ /opt/solr/server/solr/configsets/ibexa/conf

RUN cp /opt/solr/server/solr/configsets/_default/conf/solrconfig.xml /opt/solr/server/solr/configsets/ibexa/conf \
  && cp /opt/solr/server/solr/configsets/_default/conf/stopwords.txt /opt/solr/server/solr/configsets/ibexa/conf \
  && cp /opt/solr/server/solr/configsets/_default/conf/synonyms.txt /opt/solr/server/solr/configsets/ibexa/conf \
  && sed -i.bak '/<updateRequestProcessorChain name="add-unknown-fields-to-the-schema".*/,/<\/updateRequestProcessorChain>/d' /opt/solr/server/solr/configsets/ibexa/conf/solrconfig.xml \
  && sed -ie 's/${solr.autoSoftCommit.maxTime:-1}/${solr.autoSoftCommit.maxTime:20}/' /opt/solr/server/solr/configsets/ibexa/conf/solrconfig.xml

USER $SOLR_USER

CMD ["solr-precreate", "collection1", "/opt/solr/server/solr/configsets/ibexa"]
