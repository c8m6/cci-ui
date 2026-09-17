class BrowserLocale
  def self.resolve(header)
    supported = I18n.available_locales.map(&:to_s)
    preferences = header.to_s.split(",").filter_map.with_index do |part, index|
      language, *parameters = part.strip.downcase.split(";")
      next unless language&.match?(/\A[a-z]{1,8}(?:-[a-z0-9]{1,8})*\z/)
      quality = parameters.find { |parameter| parameter.strip.start_with?("q=") }
      weight = quality ? Float(quality.strip.delete_prefix("q="), exception: false) : 1.0
      next unless weight && weight.positive? && weight <= 1
      [language, weight, index]
    end
    preferences.sort_by { |_, weight, index| [-weight, index] }.each do |language, _, _|
      # Prefer an exact locale, then its base language (for example en-GB -> en).
      match = supported.find { |locale| locale.downcase == language } ||
        supported.find { |locale| locale.downcase == language.split("-").first }
      return match if match
    end
    I18n.default_locale
  end
end
