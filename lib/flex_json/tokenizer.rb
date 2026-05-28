# frozen_string_literal: true
require_relative "peekable_io"

module FlexJSON
  Token = Struct.new(:type, :value, :line, :col)

  class Tokenizer
    def initialize(source, options = {})
      @options = options.dup
      @io =
        if source.respond_to?(:read)
          source
        else
          StringIO.new(source)
        end
      @peek_io = PeekableIO.new(@io, @options)
      @row_sep = options[:row_sep] || RowSep.detect_row_sep(@peek_io)
      @peek_io.rewind_buffer
      @peek_io.freeze_buffer!
      @line = 1
      @col = 1
      # ... more: setup char buffer etc.
    end

    def next_token
      # TODO: Actual implementation
      nil
    end

    def peek_token
      # TODO: Actual implementation
      nil
    end
  end
end
