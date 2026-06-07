# frozen_string_literal: true

require "smarter_json"

# Line/column reporting in ParseError and Warning. Columns are BYTE-based — the
# 1-based byte offset within the line; CR, LF, and CRLF each count as one line.
# The C and pure-Ruby paths must agree (parity). These specs pin that contract,
# including the multibyte cases where the two paths previously diverged (the
# Ruby path used to count multibyte whitespace char-based; it is now byte-based,
# matching the C reference).
RSpec.describe "line/col reporting" do
  nbsp = [0xC2, 0xA0].pack("C*").force_encoding("UTF-8") # U+00A0 NO-BREAK SPACE (2-byte whitespace)

  [true, false].each do |acceleration|
    context "acceleration: #{acceleration}" do
      def error_position(input, acceleration)
        SmarterJSON.process(input, acceleration: acceleration)
        nil
      rescue SmarterJSON::ParseError => e
        [e.line, e.col]
      end

      def warning_positions(input, acceleration)
        positions = []
        SmarterJSON.process(input, acceleration: acceleration, on_warning: ->(w) { positions << [w.line, w.col] })
        positions
      end

      describe "error position" do
        it "reports line 1, col 1 for a bad first byte" do
          expect(error_position("@", acceleration)).to eq([1, 1])
        end

        it "counts LF newlines" do
          expect(error_position("\n\n@", acceleration)).to eq([3, 1])
        end

        it "counts CRLF as a single newline" do
          expect(error_position("\r\n@", acceleration)).to eq([2, 1])
        end

        it "counts a lone CR as a single newline" do
          expect(error_position("\r@", acceleration)).to eq([2, 1])
        end

        it "uses byte-based columns (multibyte whitespace counts its bytes)" do
          # two NBSP (2 bytes each) then '@' -> '@' is at byte 4 -> col 5
          expect(error_position("#{nbsp}#{nbsp}@", acceleration)).to eq([1, 5])
        end
      end

      describe "warning position" do
        it "uses byte-based columns after multibyte string content" do
          # the empty slot's comma sits at byte 9 of '["café",,2]' -> col 10
          expect(warning_positions('["café",,2]', acceleration)).to eq([[1, 10]])
        end

        it "uses byte-based columns after a multibyte whitespace char" do
          # '[1,' + NBSP + ',2]' -> the empty-slot comma is at byte 5 -> col 6
          expect(warning_positions("[1,#{nbsp},2]", acceleration)).to eq([[1, 6]])
        end
      end
    end
  end
end
