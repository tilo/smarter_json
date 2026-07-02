# frozen_string_literal: true

require "smarter_json"

# RFC 7464 — JSON Text Sequences.
#
# A sequence frames each record as:  RS (0x1E)  <JSON-text>  LF (0x0A)
#
# The contract we assert here: the record separator 0x1E is a FIRST-CLASS, SILENT
# top-level document separator — like the newline / comma that already separate
# concatenated documents. Two consequences:
#
#   1. It never raises and never fires an on_warning (it is a real separator, not
#      "non-JSON prefix text" that the recovery layer strips).
#   2. A bare-scalar record (a number / keyword / string on its own) is valid — a
#      scalar followed by 0x1E is a record boundary, exactly like a scalar followed
#      by a newline.
#
# 0x1E is only a separator BETWEEN top-level records; inside a quoted string it stays
# content.
RSpec.describe "RFC 7464 JSON Text Sequences (0x1E record separator)" do
  [true, false].each do |acceleration|
    context "acceleration: #{acceleration}" do
      # RS-frame each record the way RFC 7464 does: 0x1E <text> 0x0A
      def framed(*records)
        records.map { |r| "\x1E" + r + "\n" }.join
      end

      # Collect every lenient-fix warning the parser reports for `input`.
      def warnings_for(input, acceleration:)
        collected = []
        SmarterJSON.process(input, acceleration: acceleration, on_warning: ->(w) { collected << w })
        collected
      end

      describe "object records" do
        it "parses a canonical RS/LF-framed object sequence into every document" do
          input = framed('{"id":1}', '{"id":2}', '{"id":3}')
          expect(SmarterJSON.process(input, acceleration: acceleration))
            .to eq([{ "id" => 1 }, { "id" => 2 }, { "id" => 3 }])
        end

        it "fires no warning — 0x1E is a separator, not stripped prefix text" do
          input = framed('{"id":1}', '{"id":2}')
          expect(warnings_for(input, acceleration: acceleration)).to eq([])
        end

        it "treats a single leading 0x1E as a silent separator, not prefix noise" do
          input = "\x1E" + '{"a":1}'
          expect(SmarterJSON.process(input, acceleration: acceleration)).to eq([{ "a" => 1 }])
          expect(warnings_for(input, acceleration: acceleration)).to eq([])
        end

        it "accepts 0x1E as the only separator, with no trailing LF" do
          input = "\x1E" + '{"a":1}' + "\x1E" + '{"b":2}'
          expect(SmarterJSON.process(input, acceleration: acceleration))
            .to eq([{ "a" => 1 }, { "b" => 2 }])
        end
      end

      describe "scalar records (the case that used to raise)" do
        it "parses number records" do
          expect(SmarterJSON.process(framed("1", "2", "3"), acceleration: acceleration))
            .to eq([1, 2, 3])
        end

        it "parses number records separated by 0x1E alone, no trailing LF" do
          expect(SmarterJSON.process("\x1E1\x1E2\x1E3", acceleration: acceleration))
            .to eq([1, 2, 3])
        end

        it "parses keyword records true / false / null" do
          expect(SmarterJSON.process(framed("true", "false", "null"), acceleration: acceleration))
            .to eq([true, false, nil])
        end

        it "parses string records" do
          expect(SmarterJSON.process("\x1E\"hi\"\x1E\"yo\"", acceleration: acceleration))
            .to eq(%w[hi yo])
        end

        it "fires no warning on scalar records" do
          expect(warnings_for(framed("1", "2"), acceleration: acceleration)).to eq([])
        end
      end

      describe "mixed-type records" do
        it "parses objects, arrays, and scalars in one sequence" do
          input = framed('{"a":1}', "[1,2,3]", "42", '"txt"', "true", "null")
          expect(SmarterJSON.process(input, acceleration: acceleration))
            .to eq([{ "a" => 1 }, [1, 2, 3], 42, "txt", true, nil])
        end
      end

      describe "0x1E inside a quoted string stays content" do
        it "does not treat an in-string 0x1E as a record separator" do
          value = SmarterJSON.process_one("{\"a\":\"x\x1Ey\"}", acceleration: acceleration)
          expect(value["a"].bytes).to include(0x1E)
          expect(value["a"]).to eq("x\x1Ey")
        end
      end

      describe "single-document and streaming access" do
        it "returns the one value via process_one for a single RS-framed record" do
          expect(SmarterJSON.process_one("\x1E" + '{"a":1}' + "\n", acceleration: acceleration))
            .to eq({ "a" => 1 })
        end

        it "streams each RS-framed record to a block" do
          collected = []
          SmarterJSON.process(framed('{"id":1}', '{"id":2}', '{"id":3}'), acceleration: acceleration) do |doc|
            collected << doc
          end
          expect(collected).to eq([{ "id" => 1 }, { "id" => 2 }, { "id" => 3 }])
        end
      end
    end
  end
end
