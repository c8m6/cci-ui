FROM ruby:4.0-slim
ENV BUNDLE_WITHOUT=development:test
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends build-essential libpq-dev && rm -rf /var/lib/apt/lists/*
COPY Gemfile Gemfile.lock ./
RUN bundle install && bundle clean --force
# Default gems also install Ruby/native files outside their gem directory.
# Keep the locked JSON gem and remove the separate bundled implementation.
RUN ruby <<'RUBY'
require "json"
require "rbconfig"
require "fileutils"

active = Gem.loaded_specs.fetch("json")
abort "Expected a patched, separately installed JSON gem" if active.default_gem? || active.version < Gem::Version.new("2.19.2")
Gem::Specification.select { |spec| spec.name == "json" && spec.default_gem? }.each do |spec|
  paths = RbConfig::CONFIG.values_at("rubylibdir", "rubyarchdir").uniq.flat_map do |directory|
    [File.join(directory, "json.rb"), File.join(directory, "json")]
  end
  paths.concat([spec.full_gem_path, spec.extension_dir, spec.cache_file, spec.loaded_from])
  abort "JSON implementations share storage" if paths.any? do |path|
    [active.full_gem_path, active.extension_dir].any? { |kept| kept == path || kept.start_with?("#{path}/") }
  end
  paths.each { |path| FileUtils.rm_rf(path, verbose: true) }
end
RUBY
COPY . .
RUN ruby test/container_json.rb && bundle exec ruby test/container_json.rb
RUN bundle exec rubocop --force-exclusion
RUN CCI_CONFIG_FILE=/app/config/build.yml bundle exec rails assets:precompile
RUN useradd --create-home --uid 10001 certui && mkdir -p tmp log && chown -R certui:certui /app
# Keep changing release metadata after the expensive build layers.
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
      org.opencontainers.image.licenses="AGPL-3.0-only" \
      org.opencontainers.image.source=${APP_SOURCE}
USER certui
EXPOSE 3000
CMD ["ruby", "bin/start"]
