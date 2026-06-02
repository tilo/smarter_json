# frozen_string_literal: true

module SmarterJSON
  # A non-fatal thing the parser worked around while staying lenient — e.g. an empty
  # comma slot it collapsed, a key with no value it read as null, or a duplicate key
  # it dropped. Surfaced only when process / process_file is called with warnings: true
  # (which then returns [result, warnings]); otherwise the parser stays silent.
  #
  #   type    — a Symbol you can branch on (:empty_slot, :empty_value, :duplicate_key)
  #   message — human-readable description
  #   line/col — where it happened in the input
  Warning = Struct.new(:type, :message, :line, :col) do
    def to_s
      line ? "#{message} at line #{line}, col #{col}" : message
    end
  end
end
