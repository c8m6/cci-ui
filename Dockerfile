FROM ruby:3.4-slim
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
