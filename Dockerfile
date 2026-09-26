FROM ruby:3.4-slim
ARG APP_VERSION=development
ARG APP_REVISION=unknown
ARG APP_BUILD_TIME=unknown
ARG APP_SOURCE=https://github.com/c8m6/cci-ui
ENV APP_VERSION=${APP_VERSION} \
    APP_REVISION=${APP_REVISION} \
    APP_BUILD_TIME=${APP_BUILD_TIME}
LABEL org.opencontainers.image.version=${APP_VERSION} \
      org.opencontainers.image.revision=${APP_REVISION} \
      org.opencontainers.image.created=${APP_BUILD_TIME} \
      org.opencontainers.image.source=${APP_SOURCE}
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends build-essential libpq-dev && rm -rf /var/lib/apt/lists/*
COPY Gemfile Gemfile.lock ./
RUN bundle install && bundle clean --force
COPY . .
RUN bundle exec rubocop --force-exclusion
RUN AUTH_MODE=local CCI_AREAS='{"build":"Build"}' CCI_LEGACY_PATHS='{}' bundle exec rails assets:precompile
RUN useradd --create-home --uid 10001 certui && mkdir -p tmp log && chown -R certui:certui /app
USER certui
EXPOSE 3000
CMD ["ruby", "bin/start"]
