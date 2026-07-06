require "json"
require "digest"
require "securerandom"

module Cms
  module Validation
    MAX_STRING_LENGTH = 100_000

    UUID_PATTERN = %r{\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z}i
    HTTP_URL_PATTERN = %r{\Ahttps?://\S+\z}i
    ISO_DATETIME_PATTERN = %r{\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,3})?(Z|[+-]\d{2}:\d{2})\z}

    DANGEROUS_KEYS = ["__proto__", "constructor", "prototype"].freeze

    # Control characters stripped from every string. The multiline variant keeps the
    # regular whitespace Tab (U+0009), Newline (U+000A) and Carriage Return (U+000D)
    # so long-form text can hold line breaks; the default variant removes those too.
    # Null bytes (U+0000) and the C1 block fall in both ranges and are always removed.
    CONTROL_CHARS_KEEP_WS = %r{[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f]}
    CONTROL_CHARS_ALL = %r{[\u0000-\u001f\u007f-\u009f]}

    def self.dangerous_key?(k)
      DANGEROUS_KEYS.include?(k)
    end

    def self.sanitize_string(value, multiline = false)
      normalized = value.unicode_normalize(:nfc)
      pattern = multiline ? CONTROL_CHARS_KEEP_WS : CONTROL_CHARS_ALL
      normalized.gsub(pattern, "").strip
    end

    def self.deep_sanitize(value)
      case value
      when String
        sanitize_string(value)
      when Array
        value.map { |v| deep_sanitize(v) }
      when Hash
        out = {}
        value.each do |k, v|
          out[k] = deep_sanitize(v) unless dangerous_key?(k)
        end
        out
      else
        value
      end
    end

    def self.valid_uuid?(value)
      value.is_a?(String) && !UUID_PATTERN.match(value).nil?
    end

    def self.normalize_uuid(value)
      value.is_a?(String) ? value.downcase : value
    end

    def self.check_scalar(type, value)
      case type
      when "Integer"
        value.is_a?(Integer)
      when "Number"
        value.is_a?(Numeric)
      when "Boolean"
        value == true || value == false
      when "Date", "DateTime", "Time"
        value.is_a?(String) && !ISO_DATETIME_PATTERN.match(value).nil?
      when "URL"
        value.is_a?(String) && !HTTP_URL_PATTERN.match(value).nil?
      else
        value.is_a?(String) && value.length <= MAX_STRING_LENGTH
      end
    end

    def self.embed?(value, type)
      value.is_a?(Hash) && value["@type"] == type
    end

    def self.etag_for(item)
      body = JSON.generate(item)
      '"' + Digest::SHA256.hexdigest(body)[0, 16] + '"'
    end

    def self.generate_uuid
      SecureRandom.uuid
    end
  end
end
