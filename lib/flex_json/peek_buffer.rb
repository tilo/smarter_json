# frozen_string_literal: true
# PeekBuffer: for tokenizer/lexers that need to peek and consume input char-by-char with lookahead
# Provides .peek(n=1), .get(n=1), .eof?, .pos, .line, .col for use in error messages, and #rewind.

module FlexJSON
  class PeekBuffer
    attr_reader :line, :col, :pos

    def initialize(source)
      @input = source.is_a?(String) ? source.each_char : source
      @buffer = []
      @pos = 0
      @line = 1
      @col = 1
      @eof = false
    end

    def peek(n = 1)
      fill_buffer(n)
      return nil if @buffer.empty?
      n == 1 ? @buffer[0] : @buffer[0, n]
    end

    def get(n = 1)
      fill_buffer(n)
      chars = @buffer.shift(n)
      chars.each { |ch| advance_pos(ch) } if chars
      n == 1 ? chars&.first : chars
    end

    def eof?
      fill_buffer(1)
      @eof && @buffer.empty?
    end

    # For tests/debug: current window ahead (as string)
    def buffer(n=10)
      fill_buffer(n)
      @buffer[0, n].join
    end

    # For tokenizer to back up (rare)
    def rewind(n=1)
      # Not implemented here: would need history for full retraction, add if needed
      raise NotImplementedError, "PeekBuffer#rewind is NYI"
    end

    private
    def fill_buffer(n)
      while @buffer.size < n && !@eof
        if (ch = @input.next rescue nil)
          @buffer << ch
        else
          @eof = true
        end
      end
    end

    def advance_pos(ch)
      @pos += 1
      if ch == "\n"
        @line += 1
        @col = 1
      else
        @col += 1
      end
    end
  end
end
