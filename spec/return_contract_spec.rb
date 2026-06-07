# frozen_string_literal: true

require "smarter_json"
require "stringio"
require "tempfile"

# The document & return contract for reading JSON.
#
# `process` and `process_file` always return an Array of documents — `[]` for none,
# `[doc]` for one, `[d1, d2, …]` for several. The block form yields each document and
# returns the count. `process_one` returns the one document's value (or nil), and warns
# — never raises — when the input holds more than one.
#
# A top-level value must be recognized JSON: a number; true / false / null (and their
# aliases); a quoted string; an object; or an array — or an implicit-root object
# (`key: value`, no braces). A bare top-level run — a single quoteless word, or two
# scalars separated only by a space — raises; there are no top-level quoteless strings.
# (That keeps quoteless strings working inside objects and arrays, and lets the
# wrapper/LLM recovery fire — wrapper junk fails to parse, which is what triggers it.)
#
# Documents are separated by a newline, comma, record separator (0x1E), EOF, or a
# self-delimiting value — never by a space; a non-self-delimiting scalar must be
# followed by one of those, or it raises. Quoteless strings inside objects and arrays
# are unchanged: a run ends at a comma, brace, bracket, newline, or a whitespace-led
# comment.
RSpec.describe SmarterJSON, "document & return contract" do
  # Parity harness: every example runs on the C path and the pure-Ruby path.
  [true, false].each do |acceleration|
    context "acceleration: #{acceleration}" do
      describe "process / process_file always return an Array of documents" do
        it "wraps a single object" do
          expect(SmarterJSON.process('{"a": 1}', acceleration: acceleration)).to eq([{ "a" => 1 }])
        end

        it "wraps a single bare scalar" do
          expect(SmarterJSON.process("42", acceleration: acceleration)).to eq([42])
        end

        it "wraps a single top-level array (does not flatten it)" do
          expect(SmarterJSON.process("[1, 2, 3]", acceleration: acceleration)).to eq([[1, 2, 3]])
        end

        it "returns [] for empty input (zero documents)" do
          expect(SmarterJSON.process("", acceleration: acceleration)).to eq([])
        end

        it "returns [] for whitespace-only input" do
          expect(SmarterJSON.process("   \n  ", acceleration: acceleration)).to eq([])
        end

        it "returns [] for comment-only input" do
          expect(SmarterJSON.process("// just a comment\n", acceleration: acceleration)).to eq([])
        end

        it "returns [nil] for a single null document" do
          expect(SmarterJSON.process("null", acceleration: acceleration)).to eq([nil])
        end

        it "returns every document of newline-delimited JSON (NDJSON / JSONL)" do
          input = %({"event": 1}\n{"event": 2}\n{"event": 3}\n)
          expect(SmarterJSON.process(input, acceleration: acceleration)).to eq([{ "event" => 1 }, { "event" => 2 }, { "event" => 3 }])
        end

        it "returns each of concatenated objects with no separator" do
          expect(SmarterJSON.process('{"a":1}{"b":2}', acceleration: acceleration)).to eq([{ "a" => 1 }, { "b" => 2 }])
        end

        it "process_file also returns an Array of documents" do
          Tempfile.create(["docs", ".ndjson"]) do |f|
            f.write(%({"a":1}\n{"b":2}\n))
            f.flush
            expect(SmarterJSON.process_file(f.path, acceleration: acceleration)).to eq([{ "a" => 1 }, { "b" => 2 }])
          end
        end
      end

      describe "the two polymorphic ambiguities are resolved" do
        it "distinguishes one array document from several scalar documents" do
          expect(SmarterJSON.process("[1, 2, 3]", acceleration: acceleration)).to eq([[1, 2, 3]])
          expect(SmarterJSON.process("1, 2, 3", acceleration: acceleration)).to eq([1, 2, 3])
        end

        it "distinguishes empty input from a single null document" do
          expect(SmarterJSON.process("", acceleration: acceleration)).to eq([])
          expect(SmarterJSON.process("null", acceleration: acceleration)).to eq([nil])
        end
      end

      describe "top-level values must be recognized JSON — bare runs raise (no top-level quoteless)" do
        it "raises on a bare top-level word" do
          expect { SmarterJSON.process("localhost", acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
        end

        it "raises on two scalars separated only by a space (a space is not a separator)" do
          expect { SmarterJSON.process("1 2", acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
        end

        it "raises on a top-level space run" do
          expect { SmarterJSON.process("1 2 3", acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
        end

        it "raises on a bare run mixing scalars and quoted strings" do
          expect { SmarterJSON.process('42 "x" true', acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
        end

        it "raises on comma-separated bare words (each element is a bare word)" do
          expect { SmarterJSON.process("red, green, blue", acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
        end

        it "raises on a bare keyword typo instead of silently making it a string" do
          expect { SmarterJSON.process("flase", acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
        end
      end

      describe "documents separate on newline / comma / self-delimitation — never a space" do
        it "separates scalar documents on newlines (NDJSON of numbers)" do
          expect(SmarterJSON.process("1\n2\n3", acceleration: acceleration)).to eq([1, 2, 3])
        end

        it "separates scalar documents on commas" do
          expect(SmarterJSON.process("1, 2, 3", acceleration: acceleration)).to eq([1, 2, 3])
        end

        it "separates concatenated objects with no separator" do
          expect(SmarterJSON.process("{}{}", acceleration: acceleration)).to eq([{}, {}])
        end

        it "separates self-delimiting objects with only a space between them" do
          expect(SmarterJSON.process('{"a":1} {"b":2}', acceleration: acceleration)).to eq([{ "a" => 1 }, { "b" => 2 }])
        end
      end

      describe "in-container quoteless strings are unchanged (only the top level is restricted)" do
        it "keeps a space run inside an array as one quoteless element" do
          expect(SmarterJSON.process("[1 2 3]", acceleration: acceleration)).to eq([["1 2 3"]])
        end

        it "keeps comma-separated quoteless words inside an array" do
          expect(SmarterJSON.process("[red, green, blue]", acceleration: acceleration)).to eq([["red", "green", "blue"]])
        end

        it "ends an in-container quoteless run at an opening brace (symmetric { terminator)" do
          expect(SmarterJSON.process('[localhost {"a":1}]', acceleration: acceleration)).to eq([["localhost", { "a" => 1 }]])
        end

        it "still parses an implicit-root object with a quoteless value" do
          expect(SmarterJSON.process("host: localhost", acceleration: acceleration)).to eq([{ "host" => "localhost" }])
        end
      end

      describe "process_one — the first document's value, warn (never raise) on 2+" do
        it "returns the single document's value, unwrapped" do
          expect(SmarterJSON.process_one('{"a": 1}', acceleration: acceleration)).to eq({ "a" => 1 })
        end

        it "returns a bare scalar as itself" do
          expect(SmarterJSON.process_one("42", acceleration: acceleration)).to eq(42)
        end

        it "raises on a bare top-level run (same restriction as process)" do
          expect { SmarterJSON.process_one("1 2 3", acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
        end

        it "returns nil for zero documents" do
          expect(SmarterJSON.process_one("", acceleration: acceleration)).to be_nil
        end

        it "accepts an IO" do
          expect(SmarterJSON.process_one(StringIO.new('{"a": 1}'), acceleration: acceleration)).to eq({ "a" => 1 })
        end

        it "does not warn for a single document" do
          warnings = []
          SmarterJSON.process_one('{"a": 1}', acceleration: acceleration, on_warning: ->(w) { warnings << w })
          expect(warnings).to be_empty
        end

        it "returns the first document and warns (does not raise) when 2+ documents are present" do
          warnings = []
          result = SmarterJSON.process_one("1\n2\n3", acceleration: acceleration, on_warning: ->(w) { warnings << w })
          expect(result).to eq(1)
          expect(warnings.map(&:type)).to include(:extra_documents)
        end
      end

      describe "the block form returns the document count" do
        it "returns 1 for a single document" do
          expect(SmarterJSON.process('{"a": 1}', acceleration: acceleration) { |_d| }).to eq(1)
        end

        it "returns the count for multiple documents" do
          expect(SmarterJSON.process("1\n2\n3", acceleration: acceleration) { |_d| }).to eq(3)
        end

        it "returns 0 for zero documents" do
          expect(SmarterJSON.process("", acceleration: acceleration) { |_d| }).to eq(0)
        end
      end

      describe "process wraps a single document of every value type in a one-element Array" do
        {
          "true" => [true],
          "false" => [false],
          "null" => [nil],
          "0" => [0],
          "-3.14" => [-3.14],
          '"hello"' => ["hello"],
          "[]" => [[]],
          "{}" => [{}],
          "[1, 2, 3]" => [[1, 2, 3]],
          '{"a": 1}' => [{ "a" => 1 }],
        }.each do |input, expected|
          it "process(#{input.inspect}) => #{expected.inspect}" do
            expect(SmarterJSON.process(input, acceleration: acceleration)).to eq(expected)
          end
        end
      end

      describe "process_one warns once (never raises) when more than one document is present" do
        it "warns and returns the first for two concatenated objects" do
          warnings = []
          result = SmarterJSON.process_one('{"a":1}{"b":2}', acceleration: acceleration, on_warning: ->(w) { warnings << w })
          expect(result).to eq({ "a" => 1 })
          expect(warnings.map(&:type)).to eq([:extra_documents])
        end

        it "warns and returns the first for three NDJSON documents" do
          warnings = []
          result = SmarterJSON.process_one("1\n2\n3", acceleration: acceleration, on_warning: ->(w) { warnings << w })
          expect(result).to eq(1)
          expect(warnings.map(&:type)).to eq([:extra_documents])
        end

        it "emits exactly one warning regardless of how many extra documents follow" do
          warnings = []
          SmarterJSON.process_one("1\n2\n3\n4\n5", acceleration: acceleration, on_warning: ->(w) { warnings << w })
          expect(warnings.size).to eq(1)
        end

        it "passes a SmarterJSON::Warning of type :extra_documents" do
          warnings = []
          SmarterJSON.process_one("1\n2", acceleration: acceleration, on_warning: ->(w) { warnings << w })
          expect(warnings.first).to be_a(SmarterJSON::Warning)
          expect(warnings.first.type).to eq(:extra_documents)
        end
      end

      describe ".first / [0] on a process result is a silent-data-loss footgun — use process_one" do
        it ".first silently returns only the first document and cannot warn" do
          warnings = []
          result = SmarterJSON.process("1\n2\n3", acceleration: acceleration, on_warning: ->(w) { warnings << w })
          expect(result.first).to eq(1) # documents 2 and 3 are silently dropped
          expect(warnings).to be_empty # Array#first has no way to warn — the footgun
        end

        it "[0] silently returns only the first document and cannot warn" do
          warnings = []
          result = SmarterJSON.process("1\n2\n3", acceleration: acceleration, on_warning: ->(w) { warnings << w })
          expect(result[0]).to eq(1)
          expect(warnings).to be_empty
        end

        it "process_one is the safe alternative: same first value, but it warns on 2+" do
          warnings = []
          value = SmarterJSON.process_one("1\n2\n3", acceleration: acceleration, on_warning: ->(w) { warnings << w })
          expect(value).to eq(1)
          expect(warnings.map(&:type)).to include(:extra_documents)
        end
      end
    end
  end

  # warn_extra_documents routing when process_one gets >1 document and NO on_warning
  # handler. The handler path is covered above; these cover the other two branches:
  # Rails.logger.warn when Rails is loaded, else Kernel#warn. Path-independent, so once.
  describe "process_one extra-document warning routing (no on_warning handler)" do
    it "warns via Kernel#warn when Rails is not loaded" do
      expect(defined?(Rails)).to be_nil # the suite does not load Rails
      expect(Kernel).to receive(:warn).with(/more than one document/)
      expect(SmarterJSON.process_one("1\n2", acceleration: false)).to eq(1)
    end

    it "routes the warning to Rails.logger.warn when Rails is loaded" do
      logger = double("logger")
      expect(logger).to receive(:warn).with(/more than one document/)
      stub_const("Rails", double("Rails", logger: logger))
      expect(SmarterJSON.process_one("1\n2", acceleration: false)).to eq(1)
    end
  end
end
