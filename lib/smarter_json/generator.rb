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
  # options[:indent]: spaces per nesting level for pretty-printing (Integer, default
  #   0 = compact). Empty objects/arrays stay inline. Not allowed with :ndjson (a
  #   record must be a single line) — combining them raises ArgumentError.
  #
  # Symbol keys/values are emitted as strings; BigDecimal as a JSON number.
  # Unsupported types (Time, custom objects) and non-finite Floats raise
  # SmarterJSON::GenerateError. Returns a String.
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

    # Strict configuration: an unknown writer option is a caller bug, so it raises
    # rather than being silently ignored.
    KNOWN_OPTIONS = %i[format indent ascii_only script_safe sort_keys coerce allow_nan].freeze

    def initialize(options = {})
      unknown = options.keys - KNOWN_OPTIONS
      unless unknown.empty?
        raise ArgumentError, "SmarterJSON.generate: unknown option#{unknown.size == 1 ? '' : 's'} " \
                             "#{unknown.map(&:inspect).join(', ')} — valid keys: #{KNOWN_OPTIONS.map(&:inspect).join(', ')}"
      end

      @format = options.fetch(:format, :json)
      unless %i[json ndjson].include?(@format)
        raise ArgumentError, "unknown writer format: #{@format.inspect} (expected :json or :ndjson)"
      end

      @indent = options.fetch(:indent, 0) # spaces per nesting level; 0 = compact (default)
      unless @indent.is_a?(Integer) && @indent >= 0
        raise ArgumentError, "indent must be a non-negative Integer, got #{@indent.inspect}"
      end
      if @indent > 0 && @format == :ndjson
        raise ArgumentError, "indent is not compatible with format: :ndjson (each record must be a single line)"
      end

      @pretty = @indent > 0

      @ascii_only  = boolean_option(options, :ascii_only)  # escape non-ASCII as \uXXXX
      @script_safe = boolean_option(options, :script_safe) # escape </ and U+2028 / U+2029
      @sort_keys   = boolean_option(options, :sort_keys)   # emit object keys in sorted order
      @coerce      = boolean_option(options, :coerce)      # convert unknown types via as_json / to_json
      @allow_nan   = boolean_option(options, :allow_nan)   # emit NaN / Infinity / -Infinity (JSON5) instead of raising
      @escape_re   = build_escape_re
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

    # A boolean writer option must be exactly true or false — a wrong type is a
    # caller bug, so it raises rather than being coerced or ignored.
    def boolean_option(options, key)
      value = options.fetch(key, false)
      return value if value == true || value == false

      raise ArgumentError, "#{key} must be true or false (got #{value.inspect})"
    end

    def emit(obj, buf, level = 0)
      case obj
      when nil        then buf << "null"
      when true       then buf << "true"
      when false      then buf << "false"
      when String     then emit_string(obj, buf)
      when Symbol     then emit_string(obj.to_s, buf)
      when Integer    then buf << obj.to_s
      when Float      then emit_float(obj, buf)
      when BigDecimal then emit_bigdecimal(obj, buf)
      when Array      then emit_array(obj, buf, level)
      when Hash       then emit_hash(obj, buf, level)
      else
        return emit_coerced(obj, buf, level) if @coerce

        raise SmarterJSON::GenerateError, "SmarterJSON.generate cannot serialize #{obj.class}"
      end
    end

    # coerce: true — let a value that isn't natively supported convert itself.
    # Prefer as_json (its result is re-emitted through the normal pipeline, so the
    # escaping/format options still apply); fall back to to_json (spliced as-is, so
    # ascii_only / script_safe do not reach inside it). Raise if it defines neither.
    def emit_coerced(obj, buf, level)
      if obj.respond_to?(:as_json)
        emit(obj.as_json, buf, level)
      elsif obj.respond_to?(:to_json)
        buf << obj.to_json
      else
        raise SmarterJSON::GenerateError, "SmarterJSON.generate cannot serialize #{obj.class} (no as_json or to_json)"
      end
    end

    def emit_array(arr, buf, level)
      return buf << "[]" if arr.empty? # empty stays inline, even in pretty mode

      if @pretty
        pad = " " * (@indent * (level + 1))
        buf << "[\n"
        arr.each_with_index do |v, i|
          buf << ",\n" unless i.zero?
          buf << pad
          emit(v, buf, level + 1)
        end
        buf << "\n" << (" " * (@indent * level)) << "]"
      else
        buf << "["
        arr.each_with_index do |v, i|
          buf << "," unless i.zero?
          emit(v, buf, level)
        end
        buf << "]"
      end
    end

    def emit_hash(hash, buf, level)
      return buf << "{}" if hash.empty? # empty stays inline, even in pretty mode

      pairs = @sort_keys ? hash.sort_by { |k, _| k.is_a?(String) ? k : k.to_s } : hash

      if @pretty
        pad = " " * (@indent * (level + 1))
        buf << "{\n"
        first = true
        pairs.each do |k, v|
          buf << ",\n" unless first
          first = false
          buf << pad
          emit_string(k.is_a?(String) ? k : k.to_s, buf) # Symbol/other keys -> string
          buf << ": "
          emit(v, buf, level + 1)
        end
        buf << "\n" << (" " * (@indent * level)) << "}"
      else
        buf << "{"
        first = true
        pairs.each do |k, v|
          buf << "," unless first
          first = false
          emit_string(k.is_a?(String) ? k : k.to_s, buf) # Symbol/other keys -> string
          buf << ":"
          emit(v, buf, level)
        end
        buf << "}"
      end
    end

    def emit_string(str, buf)
      buf << '"' << str.gsub(@escape_re) { |m| escape_match(m) } << '"'
    end

    # Per-instance escape regex from the active options. Always: ", backslash, C0
    # controls. script_safe adds the slash in </ and the JS line separators
    # U+2028/U+2029. ascii_only adds every non-ASCII char.
    def build_escape_re
      res = [ESCAPE_RE]
      res.unshift(%r{</}) if @script_safe
      res << Regexp.new("[#{[0x2028, 0x2029].pack('U*')}]") if @script_safe
      res << /[^\x00-\x7f]/ if @ascii_only
      Regexp.union(*res)
    end

    def escape_match(m)
      return "<\\/" if m == "</" # <\/ — stops </ from closing a <script> tag

      ESCAPE[m] || unicode_escape(m)
    end

    # \uXXXX for a BMP char; a UTF-16 surrogate pair for astral (> U+FFFF) chars.
    def unicode_escape(char)
      cp = char.ord
      return format("\\u%04x", cp) if cp <= 0xffff

      cp -= 0x10000
      format("\\u%04x\\u%04x", 0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff))
    end

    def emit_float(flt, buf)
      unless flt.finite?
        raise SmarterJSON::GenerateError, "SmarterJSON.generate cannot serialize non-finite Float #{flt}" unless @allow_nan

        return buf << non_finite_literal(flt)
      end

      buf << flt.to_s # Ruby's Float#to_s is shortest round-trippable; e-notation is valid JSON
    end

    def emit_bigdecimal(num, buf)
      unless num.finite?
        raise SmarterJSON::GenerateError, "SmarterJSON.generate cannot serialize non-finite BigDecimal" unless @allow_nan

        return buf << non_finite_literal(num)
      end

      buf << num.to_s("F") # plain decimal notation (BigDecimal's default "0.1e1" is not valid JSON)
    end

    # JSON5-style literals for non-finite numbers, emitted only when allow_nan: true.
    # `infinite?` returns 1 / -1 / nil for both Float and BigDecimal.
    def non_finite_literal(num)
      return "NaN" if num.nan?

      num.infinite? == 1 ? "Infinity" : "-Infinity"
    end
  end
end
