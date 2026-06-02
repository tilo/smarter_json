# frozen_string_literal: true

require "smarter_json"
require "tempfile"

# warnings: true makes process / process_file return [result, warnings] — the same
# data, plus a record of the lenient fixes that were applied (collapsed empty comma
# slots, empty hash values read as null, dropped duplicate keys). Default is silent.
# Both the C and pure-Ruby paths collect warnings, so the parity loop runs each case
# on both (acceleration: true | false) and they must agree.
RSpec.describe "SmarterJSON.process warnings:" do
  [true, false].each do |acceleration|
    context "acceleration: #{acceleration}" do
      it "returns just the value when warnings is off (default) — no tuple" do
        expect(SmarterJSON.process("[1,,2]", acceleration: acceleration)).to eq([1, 2])
      end

      it "returns [result, warnings] with an empty array on clean input" do
        result, warnings = SmarterJSON.process("[1, 2, 3]", warnings: true, acceleration: acceleration)
        expect(result).to eq([1, 2, 3])
        expect(warnings).to eq([])
      end

      describe "empty comma slots" do
        it "warns once on a collapsed interior slot" do
          result, warnings = SmarterJSON.process("[1,,2]", warnings: true, acceleration: acceleration)
          expect(result).to eq([1, 2])
          expect(warnings.map(&:type)).to eq([:empty_slot])
          expect(warnings.first.message).to match(/comma/i)
        end

        it "warns per empty slot for leading + interior, but NOT for a trailing comma" do
          result, warnings = SmarterJSON.process("[,1,,2,]", warnings: true, acceleration: acceleration)
          expect(result).to eq([1, 2])
          expect(warnings.map(&:type)).to eq(%i[empty_slot empty_slot])
        end

        it "does not warn on a plain trailing comma" do
          _, warnings = SmarterJSON.process("[1, 2,]", warnings: true, acceleration: acceleration)
          expect(warnings).to eq([])
        end

        it "warns on empty slots in objects too" do
          result, warnings = SmarterJSON.process('{"a":1,,"b":2}', warnings: true, acceleration: acceleration)
          expect(result).to eq({ "a" => 1, "b" => 2 })
          expect(warnings.map(&:type)).to eq([:empty_slot])
        end
      end

      describe "empty hash value" do
        it "warns when a key has no value (read as null)" do
          result, warnings = SmarterJSON.process("{a:}", warnings: true, acceleration: acceleration)
          expect(result).to eq({ "a" => nil })
          expect(warnings.map(&:type)).to eq([:empty_value])
          expect(warnings.first.message).to match(/null/i)
        end
      end

      describe "duplicate keys" do
        it "warns when a duplicate key is dropped (last_wins default)" do
          result, warnings = SmarterJSON.process('{"a":1,"a":2}', warnings: true, acceleration: acceleration)
          expect(result).to eq({ "a" => 2 })
          expect(warnings.map(&:type)).to eq([:duplicate_key])
        end

        it "does not warn under duplicate_key: :raise (it raises instead)" do
          expect do
            SmarterJSON.process('{"a":1,"a":2}', warnings: true, duplicate_key: :raise, acceleration: acceleration)
          end.to raise_error(SmarterJSON::ParseError)
        end
      end

      describe "warning objects" do
        it "carry type, message, line, col and render with to_s" do
          _, warnings = SmarterJSON.process("[1,,2]", warnings: true, acceleration: acceleration)
          w = warnings.first
          expect(w).to be_a(SmarterJSON::Warning)
          expect(w.type).to eq(:empty_slot)
          expect(w.line).to be_a(Integer)
          expect(w.col).to be_a(Integer)
          expect(w.to_s).to include("line")
        end
      end

      it "works through process_file too" do
        Tempfile.create(["warn", ".json"]) do |f|
          f.write("[1,,2]")
          f.flush
          result, warnings = SmarterJSON.process_file(f.path, warnings: true, acceleration: acceleration)
          expect(result).to eq([1, 2])
          expect(warnings.map(&:type)).to eq([:empty_slot])
        end
      end
    end
  end
end
