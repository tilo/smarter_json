# frozen_string_literal: true

module SmarterJSON
  # Ported 1:1 from SmarterCSV - see smarter_csv/lib/smarter_csv/peekable_io.rb
  class PeekableIO
    DEFAULT_PEEK_SIZE = 16_384
    MIN_BUFFER_SIZE = 4_096
    MAX_BUFFER_SIZE = 16_384 # update if you want SmarterCSV::AutoDetection::MAX_AUTO_ROW_SEP_CHARS

    def initialize(io, options = {}, buffer_size: DEFAULT_PEEK_SIZE)
      @io = io
      @buffer_size = buffer_size
      @options = options
      @peek_buf = nil
      @peek_pos = 0
      @emit_encoding = nil
      @buffer_frozen = false
    end

    def peek(n = @buffer_size)
      return @peek_buf.dup.force_encoding(@emit_encoding || Encoding::ASCII_8BIT) if @peek_buf

      chunk = @io.read(n)
      if chunk && !chunk.empty?
        raw = strip_bom(chunk.b)
        @emit_encoding = external_encoding
        raw = align_to_char_boundary(raw) if @emit_encoding
        @peek_buf = raw
        @peek_pos = 0
      end
      @peek_buf ? @peek_buf.dup.force_encoding(@emit_encoding || Encoding::ASCII_8BIT) : chunk
    end

    def gets(sep = @options[:row_sep])
      raise ArgumentError, "PeekableIO#gets does not support gets(nil) — pass an explicit separator string" if sep.nil?
      return @io.gets(sep) if @peek_buf.nil?

      if @buffer_frozen && buffer_exhausted?
        line = @io.gets(sep)
        return nil if line.nil?

        int = internal_encoding
        return line if int && line.encoding == int

        out_enc = @emit_encoding || external_encoding
        line = line.force_encoding(out_enc) if out_enc && line.encoding != out_enc
        return maybe_transcode(line)
      end
      out_enc = @emit_encoding || external_encoding
      unless @buffer_frozen
        loop do
          rest = @peek_buf.byteslice(@peek_pos..-1)
          rest.force_encoding(out_enc || Encoding::ASCII_8BIT)
          idx = rest.b.index(sep.b)
          if idx
            line = rest.byteslice(0, idx + sep.bytesize)
            @peek_pos += line.bytesize
            return maybe_transcode(line)
          end
          break unless extend_buffer!
        end
        rest = @peek_buf.byteslice(@peek_pos..-1)
        return nil if rest.empty?

        @peek_pos = @peek_buf.bytesize
        return maybe_transcode(rest.force_encoding(out_enc || Encoding::ASCII_8BIT))
      end
      rest = @peek_buf.byteslice(@peek_pos..-1)
      rest.force_encoding(out_enc || Encoding::ASCII_8BIT)
      idx = rest.b.index(sep.b)
      if idx
        line = rest.byteslice(0, idx + sep.bytesize)
        @peek_pos += line.bytesize
        maybe_transcode(line)
      else
        @peek_pos = @peek_buf.bytesize
        remainder = @io.gets(sep)
        combined = rest.b + (remainder ? remainder.b : "".b)
        maybe_transcode(out_enc ? combined.force_encoding(out_enc) : combined)
      end
    end

    def readline(sep = @options[:row_sep])
      line = gets(sep)
      raise EOFError, "end of file reached" if line.nil?

      line
    end

    def read(n = nil)
      return @io.read(n) if @peek_buf.nil?
      return @io.read(n) if @buffer_frozen && buffer_exhausted?

      buffered = @peek_buf.byteslice(@peek_pos..-1)
      out_enc = @emit_encoding || Encoding::ASCII_8BIT
      if n.nil?
        @peek_pos = @peek_buf.bytesize
        rest_from_io = @io.read
        appended = rest_from_io ? rest_from_io.b : "".b
        @peek_buf << appended unless @buffer_frozen
        combined = buffered + appended
        maybe_transcode(combined.force_encoding(out_enc))
      elsif n == 0
        String.new.force_encoding(out_enc)
      elsif buffered.bytesize >= n
        @peek_pos += n
        maybe_transcode(buffered.byteslice(0, n).force_encoding(out_enc))
      else
        @peek_pos = @peek_buf.bytesize
        rest_from_io = @io.read(n - buffered.bytesize)
        appended = rest_from_io ? rest_from_io.b : "".b
        @peek_buf << appended unless @buffer_frozen
        combined = buffered + appended
        maybe_transcode(combined.force_encoding(out_enc))
      end
    end

    def each_char(&block)
      return enum_for(:each_char) unless block_given?
      return @io.each_char(&block) if @peek_buf.nil?
      return @io.each_char(&block) if @buffer_frozen && buffer_exhausted?

      rest = @peek_buf.byteslice(@peek_pos..-1)
      rest.force_encoding(@emit_encoding || external_encoding || Encoding::ASCII_8BIT)
      rest = maybe_transcode(rest) || rest
      rest.each_char(&block)
      @peek_pos = @peek_buf.bytesize
      until @io.eof?
        chunk = @io.read(@buffer_size)
        break unless chunk

        @peek_buf << chunk.b unless @buffer_frozen
        chunk.force_encoding(@emit_encoding || external_encoding || Encoding::ASCII_8BIT)
        (maybe_transcode(chunk) || chunk).each_char(&block)
      end
    end

    def eof?
      return @io.eof? if buffer_exhausted?

      false
    end

    def rewind_buffer
      @peek_pos = 0
    end

    def rewind
      raise NoMethodError, "use rewind_buffer instead of rewind — PeekableIO does not seek the underlying IO"
    end

    def freeze_buffer!
      @buffer_frozen = true
    end

    def close
      @io.close if @io.respond_to?(:close)
    end

    def external_encoding
      @io.respond_to?(:external_encoding) ? @io.external_encoding : nil
    end

    def internal_encoding
      @io.respond_to?(:internal_encoding) ? @io.internal_encoding : nil
    end

    private

    def buffer_exhausted?
      @peek_buf.nil? || @peek_pos >= @peek_buf.bytesize
    end

    def extend_buffer!
      chunk = @io.read(@buffer_size)
      return false unless chunk && !chunk.empty?

      @peek_buf << chunk.b
      true
    end

    BOM_PATTERNS = [
      "\x00\x00\xFE\xFF".b,  # UTF-32 BE
      "\xFF\xFE\x00\x00".b,  # UTF-32 LE
      "\xEF\xBB\xBF".b,      # UTF-8
      "\xFE\xFF".b, # UTF-16 BE
      "\xFF\xFE".b # UTF-16 LE
    ].freeze

    def strip_bom(raw)
      BOM_PATTERNS.each do |bom|
        return raw.byteslice(bom.bytesize..-1) if raw.start_with?(bom)
      end
      raw
    end

    MAX_ALIGN_BYTES = 4
    def align_to_char_boundary(raw)
      MAX_ALIGN_BYTES.times do
        probe = raw.dup.force_encoding(@emit_encoding)
        return raw if probe.valid_encoding?

        extra = @io.read(1)
        break unless extra

        raw += extra.b
      end
      raw
    end

    def maybe_transcode(str)
      return str unless str

      int = internal_encoding
      return str unless int && @emit_encoding && int != @emit_encoding

      str.force_encoding(@emit_encoding).encode(int, invalid: :replace, undef: :replace)
    end
  end
end
