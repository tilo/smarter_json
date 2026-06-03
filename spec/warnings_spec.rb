# frozen_string_literal: true

require "smarter_json"
require "stringio"
require "tempfile"

# on_warning: takes a callable the parser invokes once per non-fatal lenient fix it
# applies (a collapsed empty comma slot, an empty hash value read as null, a dropped
# duplicate key), passing a SmarterJSON::Warning. It never changes the return shape —
# process / process_file still return the bare value (nil / value / Array) on every
# path — and costs nothing when no callable is given (the default). Both the C and
# pure-Ruby paths fire it, so the parity loop runs each case on both
# (acceleration: true | false) and they must agree.
RSpec.describe "SmarterJSON.process on_warning:" do
  # A simple collector: an Array the handler appends each Warning to.
  def collect
    warns = []
    [warns, ->(w) { warns << w }]
  end

  [true, false].each do |acceleration|
    context "acceleration: #{acceleration}" do
      describe "default (no handler)" do
        it "returns the bare value, never a tuple, on input that triggers a lenient fix" do
          expect(SmarterJSON.process("[1,,2]", acceleration: acceleration)).to eq([1, 2])
          expect(SmarterJSON.process("{a:}", acceleration: acceleration)).to eq({ "a" => nil })
          expect(SmarterJSON.process('{"a":1,"a":2}', acceleration: acceleration)).to eq({ "a" => 2 })
        end

        it "returns nil for empty input and the bare value for a single document" do
          expect(SmarterJSON.process("", acceleration: acceleration)).to be_nil
          expect(SmarterJSON.process("[1,,2]", acceleration: acceleration)).to eq([1, 2])
        end

        it "does not raise when a lenient fix is applied with no handler set" do
          expect { SmarterJSON.process("[1,,2]", acceleration: acceleration) }.not_to raise_error
        end
      end

      describe "the handler fires" do
        it "calls on_warning once per warning, passing a SmarterJSON::Warning" do
          warns, handler = collect
          SmarterJSON.process("[1,,2]", on_warning: handler, acceleration: acceleration)
          expect(warns.size).to eq(1)
          w = warns.first
          expect(w).to be_a(SmarterJSON::Warning)
          expect(w.type).to eq(:empty_slot)
          expect(w.message).not_to be_empty
        end

        it "does NOT call on_warning on clean strict JSON" do
          warns, handler = collect
          result = SmarterJSON.process('[1, 2, 3]', on_warning: handler, acceleration: acceleration)
          expect(result).to eq([1, 2, 3])
          expect(warns).to be_empty
        end

        it "fires :empty_slot on a collapsed interior comma" do
          warns, handler = collect
          result = SmarterJSON.process("[1,,2]", on_warning: handler, acceleration: acceleration)
          expect(result).to eq([1, 2])
          expect(warns.map(&:type)).to eq([:empty_slot])
        end

        it "fires :empty_value on a key with no value (read as null)" do
          warns, handler = collect
          result = SmarterJSON.process("{a:}", on_warning: handler, acceleration: acceleration)
          expect(result).to eq({ "a" => nil })
          expect(warns.map(&:type)).to eq([:empty_value])
          expect(warns.first.message).to match(/null/i)
        end

        it "fires :duplicate_key on a repeated key (last_wins default)" do
          warns, handler = collect
          result = SmarterJSON.process('{"a":1,"a":2}', on_warning: handler, acceleration: acceleration)
          expect(result).to eq({ "a" => 2 })
          expect(warns.map(&:type)).to eq([:duplicate_key])
        end

        it "fires :duplicate_key under duplicate_key: :first_wins too (first value kept)" do
          warns, handler = collect
          result = SmarterJSON.process('{"a":1,"a":2}', on_warning: handler, duplicate_key: :first_wins, acceleration: acceleration)
          expect(result).to eq({ "a" => 1 })
          expect(warns.map(&:type)).to eq([:duplicate_key])
        end

        it "fires per empty slot for leading + interior, but NOT for a trailing comma" do
          warns, handler = collect
          result = SmarterJSON.process("[,1,,2,]", on_warning: handler, acceleration: acceleration)
          expect(result).to eq([1, 2])
          expect(warns.map(&:type)).to eq(%i[empty_slot empty_slot])
        end

        it "does not warn on a plain trailing comma" do
          warns, handler = collect
          SmarterJSON.process("[1, 2,]", on_warning: handler, acceleration: acceleration)
          expect(warns).to be_empty
        end

        it "fires empty slots in objects too" do
          warns, handler = collect
          result = SmarterJSON.process('{"a":1,,"b":2}', on_warning: handler, acceleration: acceleration)
          expect(result).to eq({ "a" => 1, "b" => 2 })
          expect(warns.map(&:type)).to eq([:empty_slot])
        end

        it "fires multiple warnings in document order" do
          warns, handler = collect
          # interior empty slot (:empty_slot), then a key with no value (:empty_value)
          result = SmarterJSON.process('{a:1,,b:}', on_warning: handler, acceleration: acceleration)
          expect(result).to eq({ "a" => 1, "b" => nil })
          expect(warns.map(&:type)).to eq(%i[empty_slot empty_value])
        end
      end

      describe "the Warning object" do
        it "carries type, message, line, col and renders with to_s" do
          warns, handler = collect
          SmarterJSON.process("[1,,2]", on_warning: handler, acceleration: acceleration)
          w = warns.first
          expect(w.type).to eq(:empty_slot)
          expect(w.line).to be_a(Integer)
          expect(w.col).to be_a(Integer)
          expect(w.to_s).to include("line")
        end

        it "reports the exact line/col of the collapsed slot" do
          warns, handler = collect
          SmarterJSON.process("[1,,2]", on_warning: handler, acceleration: acceleration)
          w = warns.first
          expect(w.line).to eq(1)
          expect(w.col).to eq(4) # the second comma in "[1,,2]"
        end

        it "reports the exact line/col of a collapsed slot across CRLF" do
          warns, handler = collect
          SmarterJSON.process("[1,\r\n,2]", on_warning: handler, acceleration: acceleration)
          w = warns.first
          expect(w.type).to eq(:empty_slot)
          expect(w.line).to eq(2)
          expect(w.col).to eq(1)
        end

        it "reports the exact line/col of an empty value across CRLF" do
          warns, handler = collect
          SmarterJSON.process("{a:\r\n}", on_warning: handler, acceleration: acceleration)
          w = warns.first
          expect(w.type).to eq(:empty_value)
          expect(w.line).to eq(2)
          expect(w.col).to eq(1)
        end

        it "reports the duplicate-key warning on the duplicate line across CRLF" do
          warns, handler = collect
          SmarterJSON.process("{\"a\":1,\r\n\"a\":2}", on_warning: handler, acceleration: acceleration)
          w = warns.first
          expect(w.type).to eq(:duplicate_key)
          expect(w.line).to eq(2)
          expect(w.col).to be >= 1
        end
      end

      describe "every path delivers warnings to the handler" do
        it "in-memory String, no block" do
          warns, handler = collect
          SmarterJSON.process("[1,,2]", on_warning: handler, acceleration: acceleration)
          expect(warns.map(&:type)).to eq([:empty_slot])
        end

        it "in-memory String, with block" do
          warns, handler = collect
          docs = []
          SmarterJSON.process("[1,,2]", on_warning: handler, acceleration: acceleration) { |d| docs << d }
          expect(docs).to eq([[1, 2]])
          expect(warns.map(&:type)).to eq([:empty_slot])
        end

        it "IO, no block" do
          warns, handler = collect
          io = StringIO.new("[1,,2]")
          result = SmarterJSON.process(io, on_warning: handler, acceleration: acceleration)
          expect(result).to eq([1, 2])
          expect(warns.map(&:type)).to eq([:empty_slot])
        end

        it "IO, streaming with block — fires for each NDJSON line" do
          warns, handler = collect
          io = StringIO.new("[1,,2]\n[3,,4]\n[5,,6]\n")
          docs = []
          SmarterJSON.process(io, on_warning: handler, acceleration: acceleration) { |d| docs << d }
          expect(docs).to eq([[1, 2], [3, 4], [5, 6]])
          expect(warns.map(&:type)).to eq(%i[empty_slot empty_slot empty_slot])
        end

        it "process_file, no block" do
          warns, handler = collect
          Tempfile.create(["warn", ".json"]) do |f|
            f.write("[1,,2]")
            f.flush
            result = SmarterJSON.process_file(f.path, on_warning: handler, acceleration: acceleration)
            expect(result).to eq([1, 2])
          end
          expect(warns.map(&:type)).to eq([:empty_slot])
        end

        it "process_file, streaming with block" do
          warns, handler = collect
          docs = []
          Tempfile.create(["warn", ".ndjson"]) do |f|
            f.write("[1,,2]\n[3,,4]\n")
            f.flush
            SmarterJSON.process_file(f.path, on_warning: handler, acceleration: acceleration) { |d| docs << d }
          end
          expect(docs).to eq([[1, 2], [3, 4]])
          expect(warns.map(&:type)).to eq(%i[empty_slot empty_slot])
        end
      end
    end
  end
end
