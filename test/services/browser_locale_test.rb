require "test_helper"

class BrowserLocaleTest < ActiveSupport::TestCase
  test "browser preferences respect weights regional variants and header order" do
    {
      "en-US,en;q=0.9,de;q=0.8" => "en",
      "en;q=0.2,de-DE;q=0.9" => "de",
      "fr-CH, en-GB;q=0.8, de;q=0.7" => "en",
      "EN-gb;q=0.8, DE;q=0.8" => "en",
      "en;q=0,de;q=0.5" => "de",
      "en;q=invalid,de" => "de",
      "en;q=1.1,de" => "de",
      "fr, *;q=0.5" => "de",
      "../../en, de" => "de",
      "" => "de",
      nil => "de"
    }.each do |header, expected|
      assert_equal expected, BrowserLocale.resolve(header).to_s, header.inspect
    end
  end

  test "locales provide matching keys interpolation variables and plural forms" do
    catalogs = I18n.available_locales.to_h do |locale|
      [locale, YAML.safe_load_file(Rails.root.join("config/locales/#{locale}.yml")).fetch(locale.to_s)]
    end
    flatten = lambda do |hash, prefix = ""|
      hash.each_with_object({}) do |(key, value), result|
        path = "#{prefix}#{key}"
        value.is_a?(Hash) ? result.merge!(flatten.call(value, "#{path}.")) : result[path] = value
      end
    end
    german = flatten.call(catalogs.fetch(:de))
    catalogs.each do |locale, catalog|
      values = flatten.call(catalog)
      # Additional CLDR plural categories are allowed for future languages.
      extra_plurals = values.keys.select do |key|
        key.match?(/\.(zero|two|few|many)\z/) && german.key?(key.sub(/\.[^.]+\z/, ".other"))
      end
      assert_equal german.keys.sort, (values.keys - extra_plurals).sort, locale.to_s
      values.each do |key, value|
        reference = german.fetch(key) { german.fetch(key.sub(/\.[^.]+\z/, ".other")) }
        assert_equal reference.scan(/%\{\w+\}/).sort, value.scan(/%\{\w+\}/).sort, "#{locale}.#{key}"
      end
    end
  end
end
