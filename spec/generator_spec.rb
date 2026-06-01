# frozen_string_literal: true

require "smarter_json"
require "bigdecimal"

RSpec.describe "SmarterJSON.generate" do
  describe "format: :json (default) — standard JSON" do
    it "generates scalars" do
      expect(SmarterJSON.generate(42)).to eq("42")
      expect(SmarterJSON.generate(-3.5)).to eq("-3.5")
      expect(SmarterJSON.generate("hi")).to eq('"hi"')
      expect(SmarterJSON.generate(true)).to eq("true")
      expect(SmarterJSON.generate(false)).to eq("false")
      expect(SmarterJSON.generate(nil)).to eq("null")
    end

    it "generates objects (Symbol keys/values become strings)" do
      expect(SmarterJSON.generate({ "a" => 1, "b" => [2, 3] })).to eq('{"a":1,"b":[2,3]}')
      expect(SmarterJSON.generate({ a: 1, b: :sym })).to eq('{"a":1,"b":"sym"}')
    end

    it "generates a top-level array as a JSON array (NOT NDJSON)" do
      expect(SmarterJSON.generate([1, 2, 3])).to eq("[1,2,3]")
      expect(SmarterJSON.generate([{ "a" => 1 }, { "b" => 2 }])).to eq('[{"a":1},{"b":2}]')
      expect(SmarterJSON.generate([[1, 2], [3, 4]])).to eq("[[1,2],[3,4]]")
    end

    it "escapes strings and emits non-ASCII as raw UTF-8" do
      expect(SmarterJSON.generate(%(a"b\\c))).to eq('"a\\"b\\\\c"')
      expect(SmarterJSON.generate("tab\tnl\n")).to eq('"tab\\tnl\\n"')
      expect(SmarterJSON.generate("café résumé")).to eq('"café résumé"')
      expect(SmarterJSON.generate("")).to eq('""')
    end

    it "emits BigDecimal as a JSON number (not a string)" do
      expect(SmarterJSON.generate(BigDecimal("1.5"))).to eq("1.5")
      expect(SmarterJSON.generate({ "x" => BigDecimal("65.613616999999977") })).to eq('{"x":65.613616999999977}')
    end

    it "raises on unsupported types and non-finite floats" do
      expect { SmarterJSON.generate(Time.now) }.to raise_error(SmarterJSON::Error)
      expect { SmarterJSON.generate(Float::INFINITY) }.to raise_error(SmarterJSON::Error)
      expect { SmarterJSON.generate(Float::NAN) }.to raise_error(SmarterJSON::Error)
    end
  end

  describe "format: :ndjson" do
    it "writes each array element on its own line" do
      expect(SmarterJSON.generate([{ "a" => 1 }, { "b" => 2 }], format: :ndjson)).to eq(%({"a":1}\n{"b":2}\n))
    end

    it "writes a single non-array value as one line" do
      expect(SmarterJSON.generate({ "a" => 1 }, format: :ndjson)).to eq(%({"a":1}\n))
    end

    it "writes an empty array as no lines (empty string)" do
      expect(SmarterJSON.generate([], format: :ndjson)).to eq("")
    end

    it "writes scalar / mixed elements one per line" do
      expect(SmarterJSON.generate([1, "x", true], format: :ndjson)).to eq(%(1\n"x"\ntrue\n))
    end

    it "keeps nested arrays as JSON arrays, one element (line) each" do
      expect(SmarterJSON.generate([[1, 2], [3, 4]], format: :ndjson)).to eq("[1,2]\n[3,4]\n")
    end

    it "writes multi-key objects (Symbol keys) one per line" do
      expect(SmarterJSON.generate([{ a: 1, b: 2 }, { c: 3, d: 4 }], format: :ndjson)).to eq(%({"a":1,"b":2}\n{"c":3,"d":4}\n))
    end
  end

  describe "round-trips with process" do
    it "process(generate(obj)) == obj for standard JSON" do
      obj = { "a" => 1, "b" => [2, "three", nil, true], "c" => { "d" => -4.5 } }
      expect(SmarterJSON.process(SmarterJSON.generate(obj))).to eq(obj)
    end

    it "process(generate(arr, format: :ndjson)) == arr for NDJSON" do
      arr = [{ "id" => 1 }, { "id" => 2 }, { "id" => 3 }]
      expect(SmarterJSON.process(SmarterJSON.generate(arr, format: :ndjson))).to eq(arr)
    end
  end

  describe "indent: pretty-printing" do
    it "indents an object by the given number of spaces" do
      expect(SmarterJSON.generate({ "a" => 1, "b" => 2 }, indent: 2)).to eq(<<~JSON.chomp)
        {
          "a": 1,
          "b": 2
        }
      JSON
    end

    it "indents an array by the given number of spaces" do
      expect(SmarterJSON.generate([1, 2, 3], indent: 2)).to eq(<<~JSON.chomp)
        [
          1,
          2,
          3
        ]
      JSON
    end

    it "indents nested objects and arrays, deepening per level" do
      expect(SmarterJSON.generate({ "a" => [1, { "b" => 2 }] }, indent: 2)).to eq(<<~JSON.chomp)
        {
          "a": [
            1,
            {
              "b": 2
            }
          ]
        }
      JSON
    end

    it "puts a space after the colon in objects (pretty mode)" do
      expect(SmarterJSON.generate({ "a" => 1 }, indent: 2)).to include('"a": 1')
    end

    it "keeps empty array and object inline" do
      expect(SmarterJSON.generate([], indent: 2)).to eq("[]")
      expect(SmarterJSON.generate({}, indent: 2)).to eq("{}")
      expect(SmarterJSON.generate({ "a" => [], "b" => {} }, indent: 2)).to eq(<<~JSON.chomp)
        {
          "a": [],
          "b": {}
        }
      JSON
    end

    it "honors a different indent width" do
      expect(SmarterJSON.generate({ "a" => 1 }, indent: 4)).to eq(<<~JSON.chomp)
        {
            "a": 1
        }
      JSON
    end

    it "indent: 0 (the default) is unchanged compact output" do
      expect(SmarterJSON.generate({ "a" => [1, 2] }, indent: 0)).to eq('{"a":[1,2]}')
      expect(SmarterJSON.generate({ "a" => [1, 2] })).to eq('{"a":[1,2]}')
    end

    it "round-trips: process(generate(obj, indent: 2)) == obj" do
      obj = { "a" => 1, "b" => [2, "three", nil, true], "c" => { "d" => -4.5 } }
      expect(SmarterJSON.process(SmarterJSON.generate(obj, indent: 2))).to eq(obj)
    end
  end

  describe "errors" do
    it "raises ArgumentError on an unknown writer format" do
      expect { SmarterJSON.generate({}, format: :bogus) }.to raise_error(ArgumentError, /format/)
    end

    it "raises ArgumentError on a negative or non-Integer indent" do
      expect { SmarterJSON.generate({}, indent: -1) }.to raise_error(ArgumentError, /indent/)
      expect { SmarterJSON.generate({}, indent: "2") }.to raise_error(ArgumentError, /indent/)
    end

    it "raises ArgumentError when indent is combined with format: :ndjson" do
      expect { SmarterJSON.generate([1, 2], format: :ndjson, indent: 2) }.to raise_error(ArgumentError, /ndjson/)
    end
  end
end
