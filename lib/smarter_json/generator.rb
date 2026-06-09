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

    # Iterative serializer — an explicit frame stack (one frame per open container),
    # mirroring the recursive structure but heap-allocated, so arbitrarily deep input
    # cannot overflow the call stack (parity with the iterative parser). Output is
    # byte-identical to the former recursive version. A frame is a small Array:
    #   [members, idx, is_hash, before_first, before_rest, colon, closer, level]
    def emit(obj, buf)
      stack = []
      push_value(obj, 0, buf, stack)
      until stack.empty?
        frame   = stack.last
        members = frame[0]
        i       = frame[1]
        if i == members.length
          buf << frame[6] # closer
          stack.pop
          next
        end
        frame[1] = i + 1
        buf << (i.zero? ? frame[3] : frame[4]) # opener-pad / separator-pad
        if frame[2] # hash
          k, v = members[i]
          emit_string(k.is_a?(String) ? k : k.to_s, buf) # Symbol/other keys -> string
          buf << frame[5] # colon
          push_value(v, frame[7] + 1, buf, stack)
        else
          push_value(members[i], frame[7] + 1, buf, stack)
        end
      end
    end

    # Emit one value at `level`: a scalar appends directly; a non-empty container writes
    # its opener and pushes a frame for the driver above to walk (no recursion into it).
    def push_value(obj, level, buf, stack)
      case obj
      when nil        then buf << "null"
      when true       then buf << "true"
      when false      then buf << "false"
      when String     then emit_string(obj, buf)
      when Symbol     then emit_string(obj.to_s, buf)
      when Integer    then buf << obj.to_s
      when Float      then emit_float(obj, buf)
      when BigDecimal then emit_bigdecimal(obj, buf)
      when Array
        return buf << "[]" if obj.empty? # empty stays inline, even in pretty mode

        buf << (@pretty ? "[\n" : "[")
        stack << container_frame(obj, false, level)
      when Hash
        return buf << "{}" if obj.empty? # empty stays inline, even in pretty mode

        pairs = @sort_keys ? obj.sort_by { |k, _| k.is_a?(String) ? k : k.to_s } : obj.to_a
        buf << (@pretty ? "{\n" : "{")
        stack << container_frame(pairs, true, level)
      else
        return push_coerced(obj, level, buf, stack) if @coerce

        raise SmarterJSON::GenerateError, "SmarterJSON.generate cannot serialize #{obj.class}"
      end
    end

    # coerce: true — prefer as_json (re-emitted through the normal pipeline, so the
    # escaping/format options still apply); else to_json (spliced as-is, so ascii_only /
    # script_safe do not reach inside it); else raise.
    def push_coerced(obj, level, buf, stack)
      if obj.respond_to?(:as_json)
        push_value(obj.as_json, level, buf, stack)
      elsif obj.respond_to?(:to_json)
        buf << obj.to_json
      else
        raise SmarterJSON::GenerateError, "SmarterJSON.generate cannot serialize #{obj.class} (no as_json or to_json)"
      end
    end

    # Build a frame for an open container at `level`, precomputing its punctuation/indent
    # once (as the recursive version computed `pad` once per container).
    def container_frame(members, is_hash, level)
      close_glyph = is_hash ? "}" : "]"
      if @pretty
        pad  = " " * (@indent * (level + 1))
        padl = " " * (@indent * level)
        [members, 0, is_hash, pad, ",\n#{pad}", ": ", "\n#{padl}#{close_glyph}", level]
      else
        [members, 0, is_hash, "", ",", ":", close_glyph, level]
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
