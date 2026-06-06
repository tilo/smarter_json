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
      expect(SmarterJSON.process(SmarterJSON.generate(obj))).to eq([obj])
      expect(SmarterJSON.process_one(SmarterJSON.generate(obj))).to eq(obj)
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
      expect(SmarterJSON.process(SmarterJSON.generate(obj, indent: 2))).to eq([obj])
      expect(SmarterJSON.process_one(SmarterJSON.generate(obj, indent: 2))).to eq(obj)
    end
  end

  describe "ascii_only: escape non-ASCII as \\uXXXX" do
    it "leaves ASCII unchanged" do
      expect(SmarterJSON.generate("hello", ascii_only: true)).to eq('"hello"')
    end

    it "escapes a BMP non-ASCII char" do
      e_acute = [0x00E9].pack("U") # é
      expect(SmarterJSON.generate(e_acute, ascii_only: true)).to eq('"\u00e9"')
    end

    it "escapes an astral (> U+FFFF) char as a UTF-16 stand-in pair" do
      grinning = [0x1F600].pack("U") # 😀
      expect(SmarterJSON.generate(grinning, ascii_only: true)).to eq('"\ud83d\ude00"')
    end

    it "escapes non-ASCII in object keys too" do
      key = [0x00E9].pack("U")
      expect(SmarterJSON.generate({ key => 1 }, ascii_only: true)).to eq('{"\u00e9":1}')
    end

    it "default (ascii_only off) emits raw UTF-8" do
      cafe = "caf#{[0x00E9].pack('U')}"
      expect(SmarterJSON.generate(cafe)).to eq(%("#{cafe}"))
    end
  end

  describe "script_safe: escape </ and JS line separators" do
    it "escapes the slash in </ so it cannot close a <script> tag" do
      expect(SmarterJSON.generate("</script>", script_safe: true)).to eq('"<\/script>"')
    end

    it "escapes U+2028 and U+2029" do
      expect(SmarterJSON.generate([0x2028].pack("U"), script_safe: true)).to eq('"\u2028"')
      expect(SmarterJSON.generate([0x2029].pack("U"), script_safe: true)).to eq('"\u2029"')
    end

    it "leaves a slash that is not part of </ alone" do
      expect(SmarterJSON.generate("http://example.com", script_safe: true)).to eq('"http://example.com"')
    end

    it "default (script_safe off) leaves </ and separators raw" do
      expect(SmarterJSON.generate("</x>")).to eq('"</x>"')
      ls = [0x2028].pack("U")
      expect(SmarterJSON.generate(ls)).to eq(%("#{ls}"))
    end
  end

  describe "sort_keys: emit object keys in sorted order" do
    it "sorts string keys" do
      expect(SmarterJSON.generate({ "b" => 1, "a" => 2, "c" => 3 }, sort_keys: true)).to eq('{"a":2,"b":1,"c":3}')
    end

    it "sorts nested objects too" do
      expect(SmarterJSON.generate({ "z" => { "b" => 1, "a" => 2 } }, sort_keys: true)).to eq('{"z":{"a":2,"b":1}}')
    end

    it "sorts Symbol keys by their string form" do
      expect(SmarterJSON.generate({ b: 1, a: 2 }, sort_keys: true)).to eq('{"a":2,"b":1}')
    end

    it "default preserves insertion order" do
      expect(SmarterJSON.generate({ "b" => 1, "a" => 2 })).to eq('{"b":1,"a":2}')
    end

    it "works together with indent" do
      expect(SmarterJSON.generate({ "b" => 1, "a" => 2 }, sort_keys: true, indent: 2)).to eq(<<~JSON.chomp)
        {
          "a": 2,
          "b": 1
        }
      JSON
    end
  end

  describe "combining writer options" do
    it "applies ascii_only and script_safe together" do
      s = "</s>#{[0x00E9].pack('U')}"
      expect(SmarterJSON.generate(s, ascii_only: true, script_safe: true)).to eq('"<\/s>\u00e9"')
    end
  end

  describe "coerce: serialize unknown types via as_json / to_json (opt-in)" do
    it "raises GenerateError on an unknown type by default (coerce off)" do
      expect { SmarterJSON.generate(Object.new) }.to raise_error(SmarterJSON::GenerateError)
    end

    it "calls as_json and emits the returned structure" do
      obj = Object.new
      def obj.as_json(*)
        { "kind" => "thing", "n" => 1 }
      end
      expect(SmarterJSON.generate(obj, coerce: true)).to eq('{"kind":"thing","n":1}')
    end

    it "emits the as_json result through the normal pipeline (sort_keys still applies)" do
      obj = Object.new
      def obj.as_json(*)
        { "b" => 2, "a" => 1 }
      end
      expect(SmarterJSON.generate(obj, coerce: true, sort_keys: true)).to eq('{"a":1,"b":2}')
    end

    it "prefers as_json over to_json" do
      obj = Object.new
      def obj.as_json(*)
        { "via" => "as_json" }
      end

      def obj.to_json(*)
        '{"via":"to_json"}'
      end
      expect(SmarterJSON.generate(obj, coerce: true)).to eq('{"via":"as_json"}')
    end

    it "falls back to to_json (spliced verbatim) when as_json is absent" do
      obj = Object.new
      def obj.to_json(*)
        '{"raw":true}'
      end
      expect(SmarterJSON.generate(obj, coerce: true)).to eq('{"raw":true}')
    end

    it "coerces recursively (an as_json result may itself contain objects needing coercion)" do
      inner = Object.new
      def inner.as_json(*)
        "inner!"
      end
      outer = Object.new
      outer.define_singleton_method(:as_json) { { "x" => inner } }
      expect(SmarterJSON.generate(outer, coerce: true)).to eq('{"x":"inner!"}')
    end

    it "still raises GenerateError when the value defines neither as_json nor to_json" do
      klass = Class.new do
        undef_method :to_json if method_defined?(:to_json)
        undef_method :as_json if method_defined?(:as_json)
      end
      expect { SmarterJSON.generate(klass.new, coerce: true) }.to raise_error(SmarterJSON::GenerateError)
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
