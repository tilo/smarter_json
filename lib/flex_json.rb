# frozen_string_literal: true

require_relative "flex_json/version"
require_relative "flex_json/row_sep"
require_relative "flex_json/peekable_io"
require_relative "flex_json/parser"

module FlexJSON
  class Error < StandardError; end
end
