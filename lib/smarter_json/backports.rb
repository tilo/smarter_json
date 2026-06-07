# frozen_string_literal: true

# Refinement backport of Array#filter_map for Ruby < 2.7 (the gem supports >= 2.6.0).
#
# filter_map shipped in Ruby 2.7. Rather than monkey-patching core Enumerable
# globally, this is a refinement scoped to the single file that needs it: parser.rb
# does `using SmarterJSON::Backports` (guarded to Ruby < 2.7). On 2.7+ the
# refinement is never activated, so the native (C) filter_map is used and this is a
# complete no-op.
#
# DELETE this file, its require in lib/smarter_json.rb, and the `using` line in
# parser.rb once the minimum supported Ruby is >= 2.7.
module SmarterJSON
  module Backports
    refine Array do
      def filter_map
        return enum_for(:filter_map) unless block_given?

        result = []
        each do |element|
          value = yield(element)
          result << value if value
        end
        result
      end
    end
  end
end
