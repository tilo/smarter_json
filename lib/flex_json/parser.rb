# frozen_string_literal: true
require_relative "tokenizer"

module FlexJSON
  class ParseError < StandardError; end
  class EncodingError < ParseError; end

  module_function

  def parse(input, **opts)
    tokenizer = Tokenizer.new(input, opts)
    # TODO: invoke recursive-descent parsing using tokenizer
    raise NotImplementedError, "Parser not yet implemented"
  end

  def parse_file(path, **opts)
    File.open(path, "rb:utf-8") do |f|
      parse(f, **opts)
    end
  end
end
