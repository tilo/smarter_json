# frozen_string_literal: true

require "bigdecimal" # for bigdecimal_load: :auto / :bigdecimal (Oj-compatible)

require_relative "smarter_json/version"
require_relative "smarter_json/row_sep"
require_relative "smarter_json/peekable_io"
require_relative "smarter_json/parser"

# Optional C extension. When compiled and loadable it defines SmarterJSON.parse_c;
# otherwise we run pure Ruby. (Mirrors smarter_csv's load-with-rescue pattern.)
begin
  require_relative "smarter_json/smarter_json"
rescue LoadError
  # pure-Ruby fallback — no acceleration available
end

module SmarterJSON
  class Error < StandardError; end

  HAS_ACCELERATION = respond_to?(:parse_c)

  # parse_c is internal — the public API is parse / parse_file.
  # (rb_funcall from C and the internal `parse` dispatch still reach it.)
  private_class_method :parse_c if HAS_ACCELERATION
end
