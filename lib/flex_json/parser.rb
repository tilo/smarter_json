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
    UNDERSCORE = 0x5F
    DOLLAR     = 0x24
    SPACE      = 0x20
    TAB        = 0x09
    LF         = 0x0A
    CR         = 0x0D

    def initialize(input, encoding: nil, **_opts)
      raise ArgumentError, "input must be a String" unless input.is_a?(String)
      @input = encoding ? input.dup.force_encoding(encoding) : input
      @bytesize = @input.bytesize
      @pos = 0
      @line = 1
      @col = 1
    end

    def parse
      skip_whitespace_and_comments
      value = parse_value
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
        values << parse_value
      end
      values
    end

    private

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

    def skip_pure_whitespace
      while (b = byte) && (b == SPACE || b == TAB || b == LF || b == CR)
        advance(1)
      end
    end

    def skip_whitespace_and_comments
      loop do
        skip_pure_whitespace
        case byte
        when SLASH
          n = byte_at(1)
          if n == SLASH
            advance(2)
            advance(1) while (c = byte) && c != LF && c != CR
          elsif n == STAR
            advance(2)
            until eof?
              break if byte == STAR && byte_at(1) == SLASH
              advance(1)
            end
            raise error("unterminated block comment") if eof?
            advance(2)
          else
            return
          end
        else
          return
        end
      end
    end

    # Layer 1 (strict JSON) shape: whitespace + at most one comma + whitespace.
    # The Lenient Commas Option becomes a one-line change here.
    def skip_separator_run
      skip_whitespace_and_comments
      if byte == COMMA
        advance(1)
        skip_whitespace_and_comments
      end
    end

    def parse_value
      skip_whitespace_and_comments
      raise error("unexpected end of input") if eof?
      b = byte
      case b
      when LBRACE   then parse_object
      when LBRACKET then parse_array
      when DQUOTE   then parse_string(DQUOTE)
      when SQUOTE   then parse_single_or_triple
      when MINUS, PLUS, DOT, ZERO..NINE, UPPER_I, UPPER_N then parse_number
      when LOWER_T then parse_literal_keyword("true", true)
      when LOWER_F then parse_literal_keyword("false", false)
      when LOWER_N then parse_literal_keyword("null", nil)
      else
        raise error("unexpected character #{display_byte(b)}")
      end
    end

    def parse_object
      advance(1)
      result = {}
      skip_whitespace_and_comments
      if byte == RBRACE
        advance(1)
        return result
      end
      loop do
        skip_whitespace_and_comments
        # Trailing comma support: a `}` here means the previous separator was a trailing comma.
        if byte == RBRACE
          advance(1)
          return result
        end
        key = parse_object_key
        skip_whitespace_and_comments
        raise error("expected ':' after object key") unless byte == COLON
        advance(1)
        result[key] = parse_value
        skip_separator_run
        if byte == RBRACE
          advance(1)
          return result
        end
        raise error("unterminated object") if eof?
      end
    end

    def parse_object_key
      b = byte
      case b
      when DQUOTE then parse_string(DQUOTE)
      when SQUOTE then parse_string(SQUOTE)
      else
        raise error("expected string or identifier key") unless b && identifier_start_byte?(b)
        parse_identifier_key
      end
    end

    def identifier_start_byte?(b)
      (b >= 0x41 && b <= 0x5A) ||
        (b >= 0x61 && b <= 0x7A) ||
        b == UNDERSCORE ||
        b == DOLLAR
    end

    def identifier_continue_byte?(b)
      identifier_start_byte?(b) || (b >= ZERO && b <= NINE)
    end

    def parse_identifier_key
      start = @pos
      advance(1)
      advance(1) while (b = byte) && identifier_continue_byte?(b)
      @input.byteslice(start, @pos - start).force_encoding(@input.encoding)
    end

    def parse_array
      advance(1)
      result = []
      skip_whitespace_and_comments
      if byte == RBRACKET
        advance(1)
        return result
      end
      loop do
        skip_whitespace_and_comments
        # Trailing comma support inside arrays.
        if byte == RBRACKET
          advance(1)
          return result
        end
        result << parse_value
        skip_separator_run
        if byte == RBRACKET
          advance(1)
          return result
        end
        raise error("unterminated array") if eof?
      end
    end

    # A single quote may open either a single-quoted string or a triple-quoted
    # multi-line string. Three quotes in a row means triple.
    def parse_single_or_triple
      if byte_at(1) == SQUOTE && byte_at(2) == SQUOTE
        parse_triple_quoted
      else
        parse_string(SQUOTE)
      end
    end

    # Triple-quoted multi-line string. Indentation is stripped based on the
    # column of the opening ''' marker alone. No escape processing inside.
    def parse_triple_quoted
      indent = @col - 1            # whitespace columns before the opening '''
      advance(3)                   # consume opening '''
      raw_start = @pos
      until eof?
        break if byte == SQUOTE && byte_at(1) == SQUOTE && byte_at(2) == SQUOTE
        advance(1)
      end
      raise error("unterminated triple-quoted string") if eof?
      raw = @input.byteslice(raw_start, @pos - raw_start).force_encoding(@input.encoding)
      advance(3)                   # consume closing '''
      strip_triple(raw, indent)
    end

    def strip_triple(raw, indent)
      text = raw.gsub(/\r\n?/, "\n")
      leading_newline = text.start_with?("\n")
      lines = text.split("\n", -1)
      out = []
      lines.each_with_index do |line, idx|
        if idx.zero?
          if leading_newline
            next                   # the empty segment before the first newline
          else
            out << line            # text on the opening line — verbatim
          end
        else
          out << strip_indent(line, indent)
        end
      end
      # Drop the closing marker's own line if it was whitespace-only.
      out.pop if out.last && out.last =~ /\A[ \t]*\z/
      out.join("\n").force_encoding(@input.encoding)
    end

    # Remove up to `indent` leading space/tab characters; stop early if the
    # line has fewer (never strip into the text).
    def strip_indent(line, indent)
      i = 0
      i += 1 while i < indent && (line[i] == " " || line[i] == "\t")
      line[i..] || ""
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
        if b == BACKSLASH
          i += 1
          esc = @input.getbyte(i)
          case esc
          when DQUOTE    then buf << '"'.b
          when SQUOTE    then buf << "'".b
          when BACKSLASH then buf << '\\'.b
          when SLASH     then buf << '/'.b
          when 0x62      then buf << "\b".b
          when 0x66      then buf << "\f".b
          when 0x6E      then buf << "\n".b
          when 0x72      then buf << "\r".b
          when 0x74      then buf << "\t".b
          when LF
            # JSON5 line continuation: \<LF> emits nothing
          when CR
            # JSON5 line continuation: \<CR> or \<CR><LF> emits nothing
            i += 1 if @input.getbyte(i + 1) == LF
          when LOWER_U
            cp, consumed = decode_unicode_escape(i)
            buf << [cp].pack("U").b
            i += consumed
            next
          else
            raise error("invalid escape \\#{esc&.chr || '?'}")
          end
          i += 1
        else
          buf << b
          i += 1
        end
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
        unless hex2 && hex2.bytesize == 4 && hex2 =~ /\A\h{4}\z/
          raise error("invalid low surrogate \\u escape")
        end
        cp2 = hex2.to_i(16)
        raise error("invalid low surrogate value") unless cp2 >= 0xDC00 && cp2 <= 0xDFFF
        cp = 0x10000 + ((cp - 0xD800) << 10) + (cp2 - 0xDC00)
        consumed += 6
      end
      [cp, consumed]
    end

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
        if byte == LOWER_X || byte == UPPER_X
          advance(1)
          hex_start = @pos
          advance(1) while (b = byte) && hex_digit?(b)
          raise error("invalid hex number") if @pos == hex_start
          value = @input.byteslice(hex_start, @pos - hex_start).to_i(16)
          return negative ? -value : value
        end
      elsif byte && byte >= 0x31 && byte <= NINE
        advance(1) while (b = byte) && b >= ZERO && b <= NINE
      elsif byte == DOT
        # leading decimal handled below
      else
        raise error("invalid number")
      end

      is_float = false

      if byte == DOT
        is_float = true
        advance(1)
        advance(1) while (b = byte) && b >= ZERO && b <= NINE
      end

      if byte == LOWER_E || byte == UPPER_E
        is_float = true
        advance(1)
        advance(1) if byte == PLUS || byte == MINUS
        unless byte && byte >= ZERO && byte <= NINE
          raise error("invalid number: expected digits in exponent")
        end
        advance(1) while (b = byte) && b >= ZERO && b <= NINE
      end

      slice = @input.byteslice(int_start, @pos - int_start)
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
