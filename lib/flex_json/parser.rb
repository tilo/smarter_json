# frozen_string_literal: true

module FlexJSON
  class ParseError < StandardError
    attr_reader :line, :col

    def initialize(message, line: nil, col: nil)
      @line = line
      @col = col
      super(line && col ? "#{message} at line #{line}, col #{col}" : message)
    end
  end

  class EncodingError < ParseError; end

  module_function

  def parse(input, **opts)
    Parser.new(input, **opts).parse
  end

  # Returns an Array of every top-level value in the input.
  # Handles JSONL / NDJSON, concatenated JSON, and "misplaced value"
  # input without dropping anything.
  def parse_many(input, **opts)
    Parser.new(input, **opts).parse_all
  end

  # The :encoding option labels the input's encoding (default "UTF-8").
  # It does NOT trigger a transcoding pass — the parser works on bytes in
  # their native encoding and emits string values with the same tag.
  def parse_file(path, encoding: "UTF-8", **opts)
    input = File.read(path, encoding: encoding)
    parse(input, **opts)
  end

  # Hand-rolled FSM single-pass parser.
  # Layer 1: strict JSON (RFC 8259).
  # Layer 2: JSON5 additions — line/block comments, trailing comma,
  #          unquoted ECMAScript identifier keys, single-quoted strings,
  #          hex numbers, leading/trailing decimal points, Infinity/NaN,
  #          explicit + sign, \-line-continuation inside strings.
  # Layer 3: HJSON-inspired additions — #/comment-marker rule, triple-quoted
  #          strings, quoteless single-line strings, implicit root object,
  #          newline-as-separator, broader unquoted keys, recognized-literals-win.
  # Layer 4: flex_json additions — UTF-8 BOM skip, smart/curly quotes,
  #          Python literals (True/False/None) and undefined, underscores in
  #          numeric literals, and encoding validation (FlexJSON::EncodingError).
  class Parser
    LBRACE     = 0x7B
    RBRACE     = 0x7D
    LBRACKET   = 0x5B
    RBRACKET   = 0x5D
    COLON      = 0x3A
    COMMA      = 0x2C
    DQUOTE     = 0x22
    SQUOTE     = 0x27
    BACKSLASH  = 0x5C
    SLASH      = 0x2F
    STAR       = 0x2A
    HASH       = 0x23
    MINUS      = 0x2D
    PLUS       = 0x2B
    DOT        = 0x2E
    ZERO       = 0x30
    NINE       = 0x39
    LOWER_E    = 0x65
    UPPER_E    = 0x45
    LOWER_T    = 0x74
    LOWER_F    = 0x66
    LOWER_N    = 0x6E
    LOWER_U    = 0x75
    LOWER_X    = 0x78
    UPPER_X    = 0x58
    UPPER_I    = 0x49
    UPPER_N    = 0x4E
    UPPER_T    = 0x54
    UPPER_F    = 0x46
    UNDERSCORE = 0x5F
    DOLLAR     = 0x24
    SPACE      = 0x20
    TAB        = 0x09
    LF         = 0x0A
    CR         = 0x0D

    NOT_NUMERIC = Object.new
    HEX_RE      = /\A[-+]?0[xX][0-9a-fA-F_]+\z/.freeze
    DEC_RE      = /\A[-+]?(?:0|[1-9][0-9_]*)?(?:\.[0-9_]*)?(?:[eE][-+]?[0-9_]+)?\z/.freeze
    BLANK_HEAD  = /\A[[:space:]]+/.freeze
    BLANK_TAIL  = /[[:space:]]+\z/.freeze

    def initialize(input, encoding: nil, symbolize_keys: false, duplicate_key: :last_wins, max_depth: 512, **_opts)
      raise ArgumentError, "input must be a String" unless input.is_a?(String)

      @input = encoding ? input.dup.force_encoding(encoding) : input
      raise EncodingError, "invalid byte sequence for #{@input.encoding.name}" unless @input.valid_encoding?

      @bytesize = @input.bytesize
      # Skip a UTF-8 BOM (EF BB BF) at the start of input.
      @pos = @input.getbyte(0) == 0xEF && @input.getbyte(1) == 0xBB && @input.getbyte(2) == 0xBF ? 3 : 0
      @line = 1
      @col = 1
      @symbolize_keys = symbolize_keys
      @duplicate_key = duplicate_key
      @max_depth = max_depth
      @depth = 0
    end

    def parse
      skip_whitespace_and_comments
      raise error("unexpected end of input") if eof?

      value = parse_document
      skip_whitespace_and_comments
      unless eof?
        raise error("unexpected content after top-level value — to parse multiple documents, use FlexJSON.parse_many")
      end

      value
    end

    # Parse every top-level value until EOF. Used by FlexJSON.parse_many.
    def parse_all
      values = []
      loop do
        skip_whitespace_and_comments
        break if eof?

        values << parse_document
      end
      values
    end

    private

    # --- top-level dispatch ---

    def parse_document
      if implicit_root_object_ahead?
        parse_members(implicit: true)
      else
        parse_value
      end
    end

    # At the start of a document: an unquoted identifier followed by ':' means
    # an implicit root object (no outer braces). Look ahead without consuming.
    def implicit_root_object_ahead?
      b = byte
      return false unless b && key_start_byte?(b)

      saved = [@pos, @line, @col]
      advance(1) while (c = byte) && key_continue_byte?(c)
      skip_pure_whitespace
      result = (byte == COLON)
      @pos, @line, @col = saved
      result
    end

    # --- byte access ---

    def byte
      @input.getbyte(@pos)
    end

    def byte_at(offset)
      @input.getbyte(@pos + offset)
    end

    def eof?
      @pos >= @bytesize
    end

    def advance(n = 1)
      n.times do
        b = @input.getbyte(@pos)
        return if b.nil?

        if b == LF
          @line += 1
          @col = 1
          @pos += 1
        elsif b == CR
          @line += 1
          @col = 1
          @pos += 1
          @pos += 1 if @input.getbyte(@pos) == LF
        else
          @col += 1
          @pos += 1
        end
      end
    end

    # --- whitespace (Unicode [[:space:]] / Rails blank?; see flex_json.md §4.7) ---

    def skip_pure_whitespace
      loop do
        b = byte
        break if b.nil?

        if b == SPACE || (b >= TAB && b <= CR) # 0x20, or 0x09..0x0D
          advance(1)
        elsif b >= 0x80
          n = multibyte_ws_len(@pos)
          break if n.zero?

          @pos += n
          @col += 1
        else
          break
        end
      end
    end

    # Number of bytes of the Unicode-whitespace char starting at pos, or 0.
    # Only meaningful for bytes >= 0x80.
    def multibyte_ws_len(pos)
      b0 = @input.getbyte(pos)
      return 0 if b0 != 0xC2 && (b0 < 0xE1 || b0 > 0xE3) # reject-gate

      b1 = @input.getbyte(pos + 1)
      return 0 if b1.nil?
      return [0xA0, 0x85].include?(b1) ? 2 : 0 if b0 == 0xC2 # NBSP, NEL

      b2 = @input.getbyte(pos + 2)
      return 0 if b2.nil?

      case b0
      when 0xE1
        return 3 if b1 == 0x9A && b2 == 0x80                 # U+1680
      when 0xE2
        if b1 == 0x80
          return 3 if (b2 >= 0x80 && b2 <= 0x8A) || b2 == 0xA8 || b2 == 0xA9 || b2 == 0xAF
        elsif b1 == 0x81 && b2 == 0x9F
          return 3                                           # U+205F
        end
      when 0xE3
        return 3 if b1 == 0x80 && b2 == 0x80                 # U+3000
      end
      0
    end

    # A '#', '//', or '/*' starts a comment only when preceded by whitespace
    # or at the very start of input (the comment-marker rule).
    def skip_whitespace_and_comments
      loop do
        skip_pure_whitespace
        b = byte
        break if b.nil?

        is_marker = (b == HASH) || (b == SLASH && [SLASH, STAR].include?(byte_at(1)))
        break unless is_marker
        break unless preceded_by_ws_or_start?

        if b == SLASH && byte_at(1) == STAR
          skip_block_comment
        else
          skip_to_eol
        end
      end
    end

    def preceded_by_ws_or_start?
      return true if @pos.zero?

      prev = @input.getbyte(@pos - 1)
      return true if prev == SPACE || (prev >= TAB && prev <= CR)
      return false if prev < 0x80

      # rare: a multibyte whitespace char ending right before @pos
      i = @pos - 1
      i -= 1 while i.positive? && (@input.getbyte(i) & 0xC0) == 0x80
      n = multibyte_ws_len(i)
      n.positive? && (i + n == @pos)
    end

    def skip_to_eol
      advance(1) while (c = byte) && c != LF && c != CR
    end

    def skip_block_comment
      advance(2) # consume /*
      until eof?
        break if byte == STAR && byte_at(1) == SLASH

        advance(1)
      end
      raise error("unterminated block comment") if eof?

      advance(2) # consume */
    end

    # Layer 1 (strict JSON) shape: whitespace + at most one comma + whitespace.
    # The Lenient Commas Option becomes a one-line change here.
    def skip_separator_run
      skip_whitespace_and_comments
      return unless byte == COMMA

      advance(1)
      skip_whitespace_and_comments
    end

    # --- values ---

    # Top-level / strict value: no quoteless fallback.
    def parse_value
      skip_whitespace_and_comments
      raise error("unexpected end of input") if eof?

      b = byte
      case b
      when LBRACE   then parse_object
      when LBRACKET then parse_array
      when DQUOTE   then parse_string(DQUOTE)
      when SQUOTE   then parse_single_or_triple
      when MINUS, PLUS, DOT, ZERO..NINE, UPPER_I then parse_number
      when UPPER_N then parse_upper_n # NaN vs None
      when LOWER_T then parse_literal_keyword("true", true)
      when LOWER_F then parse_literal_keyword("false", false)
      when LOWER_N then parse_literal_keyword("null", nil)
      when LOWER_U then parse_literal_keyword("undefined", nil)
      when UPPER_T then parse_literal_keyword("True", true)
      when UPPER_F then parse_literal_keyword("False", false)
      else
        kind = smart_quote_kind(@pos)
        return parse_smart_string(kind) if kind

        raise error("unexpected character #{display_byte(b)}")
      end
    end

    # Disambiguate NaN (number) from None (Python null) at a strict position.
    def parse_upper_n
      if byte_at(1) == 0x61 # 'a' → NaN
        parse_number
      else
        parse_literal_keyword("None", nil)
      end
    end

    # Value in object-value or array-element position: quoteless allowed.
    def parse_member_value
      skip_whitespace_and_comments
      raise error("unexpected end of input") if eof?

      b = byte
      case b
      when LBRACE   then parse_object
      when LBRACKET then parse_array
      when DQUOTE   then parse_string(DQUOTE)
      when SQUOTE   then parse_single_or_triple
      else
        kind = smart_quote_kind(@pos)
        kind ? parse_smart_string(kind) : parse_quoteless_or_literal
      end
    end

    # Smart / curly quotes (U+201C/201D double, U+2018/2019 single), UTF-8
    # E2 80 9C/9D/98/99. Returns :double, :single, or nil.
    def smart_quote_kind(pos)
      return nil unless @input.getbyte(pos) == 0xE2 && @input.getbyte(pos + 1) == 0x80

      case @input.getbyte(pos + 2)
      when 0x9C, 0x9D then :double
      when 0x98, 0x99 then :single
      end
    end

    # Content between smart quotes is taken literally (no escape processing).
    # Accepts either curly variant as opener/closer (lenient about direction).
    def parse_smart_string(kind)
      closers = kind == :double ? [0x9C, 0x9D] : [0x98, 0x99]
      advance(3)
      start = @pos
      until eof?
        if @input.getbyte(@pos) == 0xE2 && @input.getbyte(@pos + 1) == 0x80 &&
           closers.include?(@input.getbyte(@pos + 2))
          result = @input.byteslice(start, @pos - start).force_encoding(@input.encoding)
          advance(3)
          return result
        end
        advance(1)
      end
      raise error("unterminated smart-quoted string")
    end

    def parse_object
      @depth += 1
      raise error("maximum nesting depth (#{@max_depth}) exceeded") if @depth > @max_depth

      advance(1) # consume {
      result = parse_members(implicit: false)
      @depth -= 1
      result
    end

    def parse_members(implicit:)
      result = {}
      loop do
        skip_whitespace_and_comments
        if byte == RBRACE
          raise error("unexpected '}'") if implicit

          advance(1)
          return result
        end
        if eof?
          return result if implicit

          raise error("unterminated object")
        end
        raise error("unexpected ']' — expected a key or '}'") if byte == RBRACKET

        key = parse_object_key
        skip_whitespace_and_comments
        raise error("expected ':' after key #{key.inspect}") unless byte == COLON

        advance(1)
        value = parse_member_value
        store_member(result, key, value)
        skip_separator_run
      end
    end

    def store_member(hash, key, value)
      k = @symbolize_keys ? key.to_sym : key
      if hash.key?(k)
        case @duplicate_key
        when :first_wins then return
        when :raise      then raise error("duplicate key #{k.inspect}")
        end
      end
      hash[k] = value
    end

    def parse_object_key
      b = byte
      return parse_string(DQUOTE) if b == DQUOTE
      return parse_string(SQUOTE) if b == SQUOTE
      raise error("expected a key") unless b && key_start_byte?(b)

      parse_identifier_key
    end

    def key_start_byte?(b)
      (b >= 0x41 && b <= 0x5A) ||   # A-Z
        (b >= 0x61 && b <= 0x7A) || # a-z
        b == UNDERSCORE ||
        b == DOLLAR
    end

    def key_continue_byte?(b)
      key_start_byte?(b) || (b >= ZERO && b <= NINE) || b == MINUS # hyphen allowed
    end

    def parse_identifier_key
      start = @pos
      advance(1)
      advance(1) while (b = byte) && key_continue_byte?(b)
      @input.byteslice(start, @pos - start).force_encoding(@input.encoding)
    end

    def parse_array
      @depth += 1
      raise error("maximum nesting depth (#{@max_depth}) exceeded") if @depth > @max_depth

      advance(1) # consume [
      result = []
      loop do
        skip_whitespace_and_comments
        if byte == RBRACKET
          advance(1)
          @depth -= 1
          return result
        end
        raise error("unterminated array") if eof?
        raise error("unexpected '}' — expected ']' or a value") if byte == RBRACE

        result << parse_member_value
        skip_separator_run
      end
    end

    # --- quoteless strings & literal classification ---

    def parse_quoteless_or_literal
      start = @pos
      scan_quoteless_run
      raw = @input.byteslice(start, @pos - start).force_encoding(@input.encoding)
      classify_quoteless(trim_blank(raw))
    end

    # Advance to the end of a quoteless run. Stops at structural punctuation
    # (',' '}' ']'), a newline, EOF, or a comment marker that is preceded by
    # whitespace. Spaces by themselves are not delimiters.
    def scan_quoteless_run
      prev_ws = false
      loop do
        b = byte
        break if b.nil?
        break if [COMMA, RBRACE, RBRACKET, LF, CR].include?(b)
        break if prev_ws && (b == HASH || (b == SLASH && [SLASH, STAR].include?(byte_at(1))))

        if b == SPACE || (b >= TAB && b <= CR) # tab/VT/FF/space (LF/CR already broke)
          prev_ws = true
          advance(1)
        elsif b >= 0x80 && (n = multibyte_ws_len(@pos)).positive?
          prev_ws = true
          @pos += n
          @col += 1
        else
          prev_ws = false
          advance(1)
        end
      end
    end

    def trim_blank(str)
      str.sub(BLANK_HEAD, "").sub(BLANK_TAIL, "")
    end

    def classify_quoteless(str)
      case str
      when "true", "True"          then return true
      when "false", "False"        then return false
      when "null", "None"          then return nil
      when "undefined"             then return nil
      when "NaN"                   then return Float::NAN
      when "Infinity", "+Infinity" then return Float::INFINITY
      when "-Infinity"             then return (-Float::INFINITY)
      end
      num = numeric_value(str)
      num.equal?(NOT_NUMERIC) ? str : num
    end

    # Returns an Integer/Float, or NOT_NUMERIC if the whole token isn't a number.
    def numeric_value(str)
      if HEX_RE.match?(str)
        neg = str.start_with?("-")
        body = str.sub(/\A[-+]/, "").delete("_") # "0x...."
        v = body[2..-1].to_i(16)
        return neg ? -v : v
      end
      return NOT_NUMERIC unless DEC_RE.match?(str) && str.match?(/[0-9]/)

      body = str.delete("_")
      body.match?(/[.eE]/) ? body.to_f : body.to_i
    end

    # --- quoted strings ---

    def parse_single_or_triple
      if byte_at(1) == SQUOTE && byte_at(2) == SQUOTE
        parse_triple_quoted
      else
        parse_string(SQUOTE)
      end
    end

    def parse_triple_quoted
      indent = @col - 1
      advance(3)
      raw_start = @pos
      until eof?
        break if byte == SQUOTE && byte_at(1) == SQUOTE && byte_at(2) == SQUOTE

        advance(1)
      end
      raise error("unterminated triple-quoted string") if eof?

      raw = @input.byteslice(raw_start, @pos - raw_start).force_encoding(@input.encoding)
      advance(3)
      strip_triple(raw, indent)
    end

    def strip_triple(raw, indent)
      text = raw.gsub(/\r\n?/, "\n")
      leading_newline = text.start_with?("\n")
      lines = text.split("\n", -1)
      out = []
      lines.each_with_index do |line, idx|
        if idx.zero?
          leading_newline ? next : (out << line)
        else
          out << strip_indent(line, indent)
        end
      end
      out.pop if out.last && out.last =~ /\A[ \t]*\z/
      out.join("\n").force_encoding(@input.encoding)
    end

    def strip_indent(line, indent)
      i = 0
      i += 1 while i < indent && [" ", "\t"].include?(line[i])
      line[i..-1] || ""
    end

    def parse_string(quote)
      advance(1)
      start = @pos
      has_escape = false
      while (b = byte)
        if b == quote
          if has_escape
            decoded = decode_string_with_escapes(start, @pos, quote)
            advance(1)
            return decoded
          else
            result = @input.byteslice(start, @pos - start).force_encoding(@input.encoding)
            advance(1)
            return result
          end
        elsif b == BACKSLASH
          has_escape = true
          advance(1)
          raise error("unterminated string escape") if eof?

          advance(1)
        else
          advance(1)
        end
      end
      raise error("unterminated string")
    end

    def decode_string_with_escapes(start, finish, _quote)
      buf = String.new(encoding: Encoding::ASCII_8BIT)
      i = start
      while i < finish
        b = @input.getbyte(i)
        unless b == BACKSLASH
          buf << b
          i += 1
          next
        end
        i += 1
        esc = @input.getbyte(i)
        case esc
        when DQUOTE    then buf << '"'.b
        when SQUOTE    then buf << "'".b
        when BACKSLASH then buf << "\\".b
        when SLASH     then buf << "/".b
        when 0x62      then buf << "\b".b
        when 0x66      then buf << "\f".b
        when 0x6E      then buf << "\n".b
        when 0x72      then buf << "\r".b
        when 0x74      then buf << "\t".b
        when LF
          # JSON5 line continuation: \<LF> emits nothing
        when CR
          i += 1 if @input.getbyte(i + 1) == LF
        when LOWER_U
          cp, consumed = decode_unicode_escape(i)
          buf << [cp].pack("U").b
          i += consumed
          next
        else
          raise error("invalid escape \\#{esc&.chr || "?"}")
        end
        i += 1
      end
      buf.force_encoding(@input.encoding)
    end

    def decode_unicode_escape(i)
      raise error("incomplete \\u escape") if i + 4 >= @bytesize

      hex = @input.byteslice(i + 1, 4)
      raise error("invalid \\u escape") unless hex =~ /\A\h{4}\z/

      cp = hex.to_i(16)
      consumed = 5
      if cp >= 0xD800 && cp <= 0xDBFF
        unless @input.getbyte(i + consumed) == BACKSLASH && @input.getbyte(i + consumed + 1) == LOWER_U
          raise error("unpaired high surrogate in string")
        end

        hex2 = @input.byteslice(i + consumed + 2, 4)
        raise error("invalid low surrogate \\u escape") unless hex2 && hex2.bytesize == 4 && hex2 =~ /\A\h{4}\z/

        cp2 = hex2.to_i(16)
        raise error("invalid low surrogate value") unless cp2 >= 0xDC00 && cp2 <= 0xDFFF

        cp = 0x10000 + ((cp - 0xD800) << 10) + (cp2 - 0xDC00)
        consumed += 6
      end
      [cp, consumed]
    end

    # --- numbers (top-level / strict positions) ---

    def parse_number
      negative = false
      if byte == MINUS
        negative = true
        advance(1)
      elsif byte == PLUS
        advance(1)
      end

      if byte == UPPER_I
        consume_keyword!("Infinity")
        return negative ? -Float::INFINITY : Float::INFINITY
      end
      if byte == UPPER_N
        consume_keyword!("NaN")
        return Float::NAN
      end

      int_start = @pos

      if byte == ZERO
        advance(1)
        if [LOWER_X, UPPER_X].include?(byte)
          advance(1)
          hex_start = @pos
          advance(1) while (b = byte) && (hex_digit?(b) || b == UNDERSCORE)
          raise error("invalid hex number") if @pos == hex_start

          value = @input.byteslice(hex_start, @pos - hex_start).delete("_").to_i(16)
          return negative ? -value : value
        end
      elsif byte && byte >= 0x31 && byte <= NINE
        advance(1) while (b = byte) && ((b >= ZERO && b <= NINE) || b == UNDERSCORE)
      elsif byte == DOT
        # leading decimal handled below
      else
        raise error("invalid number")
      end

      is_float = false

      if byte == DOT
        is_float = true
        advance(1)
        advance(1) while (b = byte) && ((b >= ZERO && b <= NINE) || b == UNDERSCORE)
      end

      if [LOWER_E, UPPER_E].include?(byte)
        is_float = true
        advance(1)
        advance(1) if [PLUS, MINUS].include?(byte)
        raise error("invalid number: expected digits in exponent") unless byte && byte >= ZERO && byte <= NINE

        advance(1) while (b = byte) && ((b >= ZERO && b <= NINE) || b == UNDERSCORE)
      end

      slice = @input.byteslice(int_start, @pos - int_start).delete("_")
      value = is_float ? slice.to_f : slice.to_i
      negative ? -value : value
    end

    def hex_digit?(b)
      (b >= ZERO && b <= NINE) ||
        (b >= 0x41 && b <= 0x46) ||
        (b >= 0x61 && b <= 0x66)
    end

    def consume_keyword!(word)
      word.bytesize.times do |i|
        raise error("invalid literal #{word.inspect}") unless byte_at(i) == word.getbyte(i)
      end
      advance(word.bytesize)
    end

    def parse_literal_keyword(word, value)
      consume_keyword!(word)
      value
    end

    def error(message)
      ParseError.new(message, line: @line, col: @col)
    end

    def display_byte(b)
      return "EOF" if b.nil?

      if b >= 0x20 && b < 0x7F
        "'#{b.chr}'"
      else
        format("0x%02X", b)
      end
    end
  end
end
