# frozen_string_literal: true

module SmarterJSON
  # Single base for everything this gem raises — `rescue SmarterJSON::Error` catches
  # both read (process / process_file) and write (generate) failures. This file is
  # required before parser.rb and generator.rb so the subclasses below can inherit
  # from Error at load time.
  class Error < StandardError; end

  # Raised by process / process_file on genuinely unparseable input (unterminated
  # string, mismatched bracket, …). Carries the line and column when known.
  class ParseError < Error
    attr_reader :line, :col

    def initialize(message, line = nil, col = nil)
      @line = line
      @col = col
      super(line && col ? "#{message} at line #{line}, col #{col}" : message)
    end
  end

  # Raised when input bytes are invalid for the claimed encoding.
  class EncodingError < ParseError; end

  # Raised by generate when a value cannot be written as strict JSON (an unsupported
  # type, or a non-finite Float / BigDecimal).
  class GenerateError < Error; end
end
