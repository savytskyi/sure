# frozen_string_literal: true

# Turns a raw merchant description from a provider ("LIDL 1234 MARIBOR",
# "AMZN MKTP DE") into a display name ("Lidl", "Amazon") with deterministic
# rules from config/merchant_aliases.yml. No ML; the same input always gives
# the same output. Provider-independent.
class Merchant::NameNormalizer
  CONFIG_PATH = Rails.root.join("config/merchant_aliases.yml")

  PROCESSOR_PREFIX = /\A(?:SQ|SUMUP|ZETTLE|IZ|PAYPAL|PP|SP|TST|DD)\s*\*\s*/i
  TRAILING_NOISE = /(?:\s+#?\d{3,}.*|\s*\*\s*[A-Z0-9]{4,}.*)\z/

  Rule = Data.define(:name, :patterns)

  class << self
    def default
      @default ||= new(load_config(CONFIG_PATH))
    end

    # Comparison key that ignores case, accents, punctuation and whitespace,
    # so "Café Lidl", "CAFE LIDL" and "cafe-lidl" are the same merchant.
    def key(name)
      I18n.transliterate(name.to_s).downcase.gsub(/[^a-z0-9]/, "")
    end

    private
      def load_config(path)
        return {} unless File.exist?(path)

        YAML.safe_load_file(path) || {}
      end
  end

  def initialize(config = {})
    @exact = (config["exact"] || {}).to_h { |raw, name| [ raw.to_s.strip.downcase, name.to_s ] }
    @rules = Array(config["rules"]).map do |rule|
      Rule.new(name: rule["name"].to_s, patterns: Array(rule["patterns"]).map { |p| Regexp.new(p, Regexp::IGNORECASE) })
    end
  end

  def normalize(raw_name)
    raw = raw_name.to_s.squish
    return nil if raw.blank?

    @exact[raw.downcase] ||
      @rules.find { |rule| rule.patterns.any? { |pattern| pattern.match?(raw) } }&.name ||
      basic_cleanup(raw)
  end

  private
    def basic_cleanup(raw)
      name = raw.sub(PROCESSOR_PREFIX, "").sub(TRAILING_NOISE, "").gsub(/\A[\s\-*]+|[\s\-*]+\z/, "")
      name = raw if name.blank?
      return name unless name == name.upcase && name.match?(/[A-Z]/)

      name.split.map { |word| word.length > 3 ? word.capitalize : word }.join(" ")
    end
end
