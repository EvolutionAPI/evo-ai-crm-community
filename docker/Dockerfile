# pre-build stage
FROM node:23-alpine AS node
FROM ruby:3.4.4-alpine3.21 AS pre-builder

ARG NODE_VERSION="23.7.0"
ARG PNPM_VERSION="10.2.0"
ENV NODE_VERSION=${NODE_VERSION}
ENV PNPM_VERSION=${PNPM_VERSION}

# ARG default to production settings
# For development docker-compose file overrides ARGS
ARG BUNDLE_WITHOUT="development:test"
ENV BUNDLE_WITHOUT=${BUNDLE_WITHOUT}
ENV BUNDLER_VERSION=2.5.11

ARG RAILS_SERVE_STATIC_FILES=true
ENV RAILS_SERVE_STATIC_FILES=${RAILS_SERVE_STATIC_FILES}

ARG RAILS_ENV=production
ENV RAILS_ENV=${RAILS_ENV}

ARG NODE_OPTIONS="--max-old-space-size=4096 --openssl-legacy-provider"
ENV NODE_OPTIONS=${NODE_OPTIONS}

ENV BUNDLE_PATH="/gems"

RUN apk update && apk add --no-cache \
  openssl \
  tar \
  build-base \
  tzdata \
  postgresql-dev \
  postgresql-client \
  git \
  curl \
  xz \
  && mkdir -p /var/app \
  && gem install bundler -v "${BUNDLER_VERSION}"

COPY --from=node /usr/local/bin/node /usr/local/bin/
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
  && ln -s /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx

RUN npm install -g pnpm@${PNPM_VERSION}

RUN echo 'export PNPM_HOME="/root/.local/share/pnpm"' >> /root/.shrc \
  && echo 'export PATH="$PNPM_HOME:$PATH"' >> /root/.shrc \
  && export PNPM_HOME="/root/.local/share/pnpm" \
  && export PATH="$PNPM_HOME:$PATH" \
  && pnpm --version

# Persist the environment variables in Docker
ENV PNPM_HOME="/root/.local/share/pnpm"
ENV PATH="$PNPM_HOME:$PATH"

WORKDIR /app

COPY Gemfile Gemfile.lock ./
# CI-only path-gem referenced by Gemfile.lock. Must be present at bundle install
# time even when the :extension_consumer_stub group is excluded — Bundler still
# resolves the lockfile entry and fails on missing path. See EVO-1378.
COPY spec/support/extension_consumer_stub spec/support/extension_consumer_stub

# adding xz as nokogiri was failing to build libxml
# https://github.com/evolution/evolution/issues/4045
RUN apk update && apk add --no-cache build-base musl ruby-full ruby-dev gcc make musl-dev openssl openssl-dev g++ linux-headers xz vips
RUN bundle config set --local force_ruby_platform true

# Do not install development or test gems in production
RUN if [ "$RAILS_ENV" = "production" ]; then \
  bundle config set without 'development test extension_consumer_stub'; bundle install -j 4 -r 3; \
  else bundle install -j 4 -r 3; \
  fi

COPY package.json pnpm-lock.yaml ./
RUN pnpm i

COPY . /app

# creating a log directory so that image wont fail when RAILS_LOG_TO_STDOUT is false
# https://github.com/evolution/evolution/issues/701
RUN mkdir -p /app/log

# clean up non-production files
# Preserve spec/support/extension_consumer_stub/ because Gemfile.lock references
# that path (CI-only :extension_consumer_stub group, EVO-1378). Bundler validates
# the path at runtime startup even when the group is excluded via BUNDLE_WITHOUT.
RUN if [ "$RAILS_ENV" = "production" ]; then \
  find spec -mindepth 1 -maxdepth 1 ! -name support -exec rm -rf {} + && \
  find spec/support -mindepth 1 -maxdepth 1 ! -name extension_consumer_stub -exec rm -rf {} + && \
  rm -rf node_modules tmp/cache; \
  fi

# Write git SHA to file (passed as build arg, falls back to "unknown")
ARG GIT_SHA="unknown"
RUN echo "${GIT_SHA}" > /app/.git_sha

# Remove unnecessary files
RUN rm -rf /gems/ruby/3.4.0/cache/*.gem \
  && find /gems/ruby/3.4.0/gems/ \( -name "*.c" -o -name "*.o" \) -delete \
  && rm -rf .git \
  && rm -f .gitignore

# final build stage
FROM ruby:3.4.4-alpine3.21

ARG NODE_VERSION="23.7.0"
ARG PNPM_VERSION="10.2.0"
ENV NODE_VERSION=${NODE_VERSION}
ENV PNPM_VERSION=${PNPM_VERSION}

ARG BUNDLE_WITHOUT="development:test"
ENV BUNDLE_WITHOUT=${BUNDLE_WITHOUT}
ENV BUNDLER_VERSION=2.5.11

ARG EXECJS_RUNTIME="Disabled"
ENV EXECJS_RUNTIME=${EXECJS_RUNTIME}

ARG RAILS_SERVE_STATIC_FILES=true
ENV RAILS_SERVE_STATIC_FILES=${RAILS_SERVE_STATIC_FILES}

ARG BUNDLE_FORCE_RUBY_PLATFORM=1
ENV BUNDLE_FORCE_RUBY_PLATFORM=${BUNDLE_FORCE_RUBY_PLATFORM}

ARG RAILS_ENV=production
ENV RAILS_ENV=${RAILS_ENV}
ENV BUNDLE_PATH="/gems"

RUN apk update && apk add --no-cache \
  build-base \
  openssl \
  tzdata \
  postgresql-client \
  imagemagick \
  git \
  vips \
  dos2unix \
  ffmpeg \
  && gem install bundler -v "${BUNDLER_VERSION}"

COPY --from=node /usr/local/bin/node /usr/local/bin/
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules

RUN if [ "$RAILS_ENV" != "production" ]; then \
  apk add --no-cache curl \
  && ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
  && ln -s /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
  && npm install -g pnpm@${PNPM_VERSION} \
  && pnpm --version; \
  fi

COPY --from=pre-builder /gems/ /gems/
COPY --from=pre-builder /app /app

# Copy .git_sha file from pre-builder stage
COPY --from=pre-builder /app/.git_sha /app/.git_sha

# Fix line endings and ensure entrypoint/bin scripts have proper permissions.
# Includes /app/bin/* because a Windows checkout leaves CRLF in the bin/rails
# shebang (#!/usr/bin/env ruby\r) -> "env: can't execute 'ruby'" on `rails runner`.
# dos2unix skips binary files automatically, so it is safe on bin/*.
RUN dos2unix /app/docker/entrypoints/*.sh /app/bin/* \
  && chmod +x /app/docker/entrypoints/*.sh /app/bin/*

WORKDIR /app

EXPOSE 3000

# EVO-1999: the image boots via rails.sh, which prepares the database on boot
# (RUN_MIGRATIONS gate, default true) — so any orchestrator that ignores the
# compose command/entrypoint (CapRover) still migrates and brings up an
# up-to-date schema. The default CMD starts the server; the sidekiq service
# overrides the command (and must set RUN_MIGRATIONS=false to avoid preparing
# the database twice).
ENTRYPOINT ["/app/docker/entrypoints/rails.sh"]
CMD ["bundle", "exec", "rails", "server", "-b", "0.0.0.0", "-p", "3000"]
