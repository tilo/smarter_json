# frozen_string_literal: true

require "smarter_json"
require "stringio"

# Edge-path coverage for the pure-Ruby branches in parser.rb — the streaming Framer
# and the wrapper-recovery byte FSM — driven entirely through the public API
# (SmarterJSON.process). These paths are Ruby-only (their C counterparts live in
# smarter_json.c), so there is no acceleration loop.
RSpec.describe "parser.rb edge-path coverage (public API)" do
  def stream(io_or_string)
    docs = []
    io = io_or_string.is_a?(String) ? StringIO.new(io_or_string) : io_or_string
    SmarterJSON.process(io) { |d| docs << d }
    docs
  end

  describe "Framer (IO streaming)" do
    it "reads via #read when the IO does not respond to #readpartial" do
      read_only = Class.new do
        def initialize(string)
          @io = StringIO.new(string)
        end

        def read(length = nil)
          @io.read(length)
        end
      end.new(%({"a":1}\n{"b":2}\n))

      expect(stream(read_only)).to eq([{ "a" => 1 }, { "b" => 2 }])
    end

    it "frames an escaped quote in a double-quoted string alongside a nested array" do
      expect(stream(%({"a":"x\\"y","b":[1,2]}\n))).to eq([{ "a" => 'x"y', "b" => [1, 2] }])
    end

    it "frames a single-quoted string value that contains a backslash escape" do
      expect(stream("{a:'p\\nq'}\n")).to eq([{ "a" => "p\nq" }])
    end

    it "skips a block comment between two streamed documents" do
      expect(stream(%({"a":1}\n/* between */\n{"b":2}\n))).to eq([{ "a" => 1 }, { "b" => 2 }])
    end

    it "skips non-JSON junk before the payload and recovers it" do
      expect(stream("Here is the data:\n{\"a\":1}\n")).to eq([{ "a" => 1 }])
    end

    it "treats a trailing line comment after the last document as separators only" do
      expect(stream(%({"a":1}\n# trailing note\n))).to eq([{ "a" => 1 }])
    end

    it "treats a trailing block comment after the last document as separators only" do
      expect(stream(%({"a":1}\n/* trailing */\n))).to eq([{ "a" => 1 }])
    end
  end

  describe "wrapper-recovery byte FSM" do
    it "recovers a payload trailed by a // line comment in noisy input" do
      expect(SmarterJSON.process("Here is the answer:\n{ \"a\": 1 } // note\n")).to eq({ "a" => 1 })
    end

    it "recovers a payload containing a /* block comment */ in noisy input" do
      expect(SmarterJSON.process("Here is the answer:\n{ \"a\": 1 /* c */ }\n")).to eq({ "a" => 1 })
    end

    it "recovers a payload containing a triple-quoted string in noisy input" do
      expect(SmarterJSON.process("Here is the result:\n{ a: '''multi''' }\nthanks")).to eq({ "a" => "multi" })
    end

    it "computes line/col across CRLF line endings for a wrapper warning" do
      warns = []
      SmarterJSON.process("Here is the JSON you requested:\r\n\r\n{\"a\":1}\r\n", on_warning: ->(w) { warns << w })
      expect(warns.map(&:type)).to include(:prefix_text_ignored)
      expect(warns.first.line).to be > 1
    end
  end
end
