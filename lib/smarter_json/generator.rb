# frozen_string_literal: true

require "bigdecimal"

module SmarterJSON
  module_function

  # SmarterJSON.generate(obj, options = {}) — write a Ruby value as JSON.
  #
  # options[:format]:
  #   :json   (default) — standard JSON. Hash -> object, Array -> array,
  #                       scalar -> scalar. Always valid, interoperable JSON.
  #   :ndjson           — newline-delimited JSON. An Array writes one element per
  #                       line; any other value writes as a single line. The
  #                       inverse of process reading NDJSON back into an Array.
  #
  # Symbol keys/values are emitted as strings; BigDecimal as a JSON number.
  # Unsupported types (Time, custom objects) and non-finite Floats raise
  # SmarterJSON::Error. Returns a String.
  def generate(obj, options = {})
    Generator.new(options).generate(obj)
  end

  class Generator
    ESCAPE = {
      '"' => '\\"', "\\" => "\\\\", "\b" => "\\b", "\f" => "\\f",
      "\n" => "\\n", "\r" => "\\r", "\t" => "\\t"
    }.freeze
    # ", backslash, and control chars 0x00-0x1F must be escaped; everything else
    # (including multi-byte UTF-8) is emitted raw — valid JSON.
    ESCAPE_RE = /["\\\x00-\x1f]/.freeze

    def initialize(options = {})
      @format = options.fetch(:format, :json)
      unless %i[json ndjson].include?(@format)
        raise ArgumentError, "unknown writer format: #{@format.inspect} (expected :json or :ndjson)"
      end
    end

    def generate(obj)
      buf = +""
      if @format == :ndjson
        if obj.is_a?(Array)
          obj.each do |v|
            emit(v, buf)
            buf << "\n"
          end
        else
          emit(obj, buf)
          buf << "\n"
        end
      else
        emit(obj, buf)
      end
      buf
    end

    private

    def emit(obj, buf)
      case obj
      when nil        then buf << "null"
      when true       then buf << "true"
      when false      then buf << "false"
      when String     then emit_string(obj, buf)
      when Symbol     then emit_string(obj.to_s, buf)
      when Integer    then buf << obj.to_s
      when Float      then emit_float(obj, buf)
      when BigDecimal then emit_bigdecimal(obj, buf)
      when Array      then emit_array(obj, buf)
      when Hash       then emit_hash(obj, buf)
      else
        raise SmarterJSON::Error, "SmarterJSON.generate cannot serialize #{obj.class}"
      end
    end

    def emit_array(arr, buf)
      buf << "["
      arr.each_with_index do |v, i|
        buf << "," unless i.zero?
        emit(v, buf)
      end
      buf << "]"
    end

    def emit_hash(hash, buf)
      buf << "{"
      first = true
      hash.each do |k, v|
        buf << "," unless first
        first = false
        emit_string(k.is_a?(String) ? k : k.to_s, buf) # Symbol/other keys -> string
        buf << ":"
        emit(v, buf)
      end
      buf << "}"
    end

    def emit_string(str, buf)
      buf << '"'
      buf << str.gsub(ESCAPE_RE) { |c| ESCAPE[c] || format("\\u%04x", c.ord) }
      buf << '"'
    end

    def emit_float(flt, buf)
      raise SmarterJSON::Error, "SmarterJSON.generate cannot serialize non-finite Float #{flt}" unless flt.finite?

      buf << flt.to_s # Ruby's Float#to_s is shortest round-trippable; e-notation is valid JSON
    end

    def emit_bigdecimal(num, buf)
      raise SmarterJSON::Error, "SmarterJSON.generate cannot serialize non-finite BigDecimal" unless num.finite?

      buf << num.to_s("F") # plain decimal notation (BigDecimal's default "0.1e1" is not valid JSON)
    end
  end
end
