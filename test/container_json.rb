# frozen_string_literal: true

# Run in fresh plain and bundled Ruby processes in the application image.
require "json"
require "rbconfig"

active = Gem.loaded_specs.fetch("json")
abort "Expected a patched installed JSON gem" if active.default_gem? || active.version < Gem::Version.new("2.19.2")
specs = Gem::Specification.find_all_by_name("json")
abort "Unexpected JSON implementation remains" unless specs.one? && specs.first.version == active.version

RbConfig::CONFIG.values_at("rubylibdir", "rubyarchdir").uniq.each do |directory|
  %w[json.rb json].each do |name|
    abort "Bundled JSON files remain in #{directory}" if File.exist?(File.join(directory, name))
  end
end
abort "Default JSON gemspec remains" unless Dir.glob(File.join(Gem.default_specifications_dir, "json-[0-9]*.gemspec")).empty?
artifacts = Gem.path.flat_map do |directory|
  %w[gems extensions/** cache].flat_map { |kind| Dir.glob(File.join(directory, kind, "json-[0-9]*")) }
end
abort "Unexpected JSON package artifacts remain" unless (artifacts - [active.full_gem_path, active.extension_dir, active.cache_file]).empty?

%w[parser generator].each do |name|
  feature = $LOADED_FEATURES.find { |path| path.end_with?("/json/ext/#{name}.#{RbConfig::CONFIG.fetch("DLEXT")}") }
  unless feature&.start_with?("#{active.full_gem_path}/", "#{active.extension_dir}/")
    abort "JSON native #{name} did not load from the installed gem"
  end
end

payload = { "subject" => "CN=Grüße", "values" => [1, true, nil] }
abort "JSON round trip failed" unless JSON.parse(JSON.generate(payload)) == payload
%w[%s %n %99999s].each do |key|
  JSON.parse(JSON.generate(key => 1).sub(/}\z/, ",#{JSON.generate(key)}:2}"), allow_duplicate_key: false)
  abort "Duplicate JSON key was accepted"
rescue JSON::ParserError => e
  abort "Duplicate JSON key was interpreted as a format string" unless e.message.include?(key)
end

require "openssl"
require "psych"
require "net/http"
require "rubygems/package"
puts "Ruby #{RUBY_VERSION}: JSON #{JSON::VERSION}, native extensions and standard libraries verified"
