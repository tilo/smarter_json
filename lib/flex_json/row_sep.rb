# frozen_string_literal: true

# Utility: Auto-detect line ending/row separator (CR, LF, CRLF) for arbitrary input.
# Adapted from smarter_csv, but only line ending part used here (not column).

module FlexJSON
  module RowSep
    # Given a String or IO (which responds to #each_char), return the most common line ending
    # Will return one of "\r\n", "\n", or "\r", or nil if not found.
    # Limitation: if IO, it rewinds at the end if possible.
    def self.detect_row_sep(input, sample_size = 500)
      counts = { "\n" => 0, "\r" => 0, "\r\n" => 0 }
      quoted = false
      last_char = nil
      lines_seen = 0
      chars =
        if input.respond_to?(:each_char)
          input.chars
        else
          input.to_s.chars
        end

      chars.each do |c|
        quoted = !quoted if c == '"'
        next if quoted

        if last_char == "\r"
          if c == "\n"
            counts["\r\n"] += 1
          else
            counts["\r"] += 1
          end
        elsif c == "\n"
          counts["\n"] += 1
        end
        last_char = c
        lines_seen += 1
        break if sample_size && lines_seen >= sample_size
      end
      # Handle case where file ends with '\r'
      counts["\r"] += 1 if last_char == "\r"
      # Find most frequent
      key, _ = counts.max_by { |_k, v| v }
      key if counts[key] > 0
    end
  end
end
