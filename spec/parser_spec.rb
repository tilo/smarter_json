# frozen_string_literal: true

require "flex_json"

RSpec.describe FlexJSON do
  let(:fixtures_dir) { File.expand_path("fixtures", __dir__) }

  # ============================================================
  # Layer 1 — Strict JSON (RFC 8259)
  # ============================================================

  describe "strict JSON (Layer 1)" do
    describe "literals" do
      it "parses true" do
        expect(FlexJSON.parse("true")).to eq(true)
      end

      it "parses false" do
        expect(FlexJSON.parse("false")).to eq(false)
      end

      it "parses null as nil" do
        expect(FlexJSON.parse("null")).to be_nil
      end
    end

    describe "numbers" do
      it "parses zero" do
        expect(FlexJSON.parse("0")).to eq(0)
      end

      it "parses positive integer" do
        expect(FlexJSON.parse("1234567890")).to eq(1_234_567_890)
      end

      it "parses negative integer" do
        expect(FlexJSON.parse("-42")).to eq(-42)
      end

      it "parses float" do
        expect(FlexJSON.parse("-9876.543210")).to eq(-9876.543210)
      end

      it "parses scientific notation (lower e, negative exponent)" do
        expect(FlexJSON.parse("0.123456789e-12")).to eq(0.123456789e-12)
      end

      it "parses scientific notation (upper E, explicit +)" do
        expect(FlexJSON.parse("1.234567890E+34")).to eq(1.234567890E+34)
      end

      it "returns Infinity for numeric overflow (tentative §7.2)" do
        expect(FlexJSON.parse("1e500")).to eq(Float::INFINITY)
      end
    end

    describe "strings" do
      it "parses simple double-quoted string" do
        expect(FlexJSON.parse('"hello"')).to eq("hello")
      end

      it "parses empty string" do
        expect(FlexJSON.parse('""')).to eq("")
      end

      it "parses string with escaped quote" do
        expect(FlexJSON.parse('"\""')).to eq('"')
      end

      it "parses string with backslash escape" do
        expect(FlexJSON.parse('"\\\\"')).to eq("\\")
      end

      it "parses string with control character escapes" do
        expect(FlexJSON.parse('"\b\f\n\r\t"')).to eq("\b\f\n\r\t")
      end

      it "parses string with forward-slash escape" do
        expect(FlexJSON.parse('"\/"')).to eq("/")
      end

      it 'parses BMP \\uXXXX escape' do
        expect(FlexJSON.parse('"A"')).to eq("A")
      end

      it 'parses surrogate pair \\uD83D\\uDE00 (😀)' do
        expect(FlexJSON.parse('"😀"')).to eq("\u{1F600}")
      end
    end

    describe "arrays" do
      it "parses empty array" do
        expect(FlexJSON.parse("[]")).to eq([])
      end

      it "parses array of integers" do
        expect(FlexJSON.parse("[1, 2, 3]")).to eq([1, 2, 3])
      end

      it "parses array of mixed types" do
        expect(FlexJSON.parse('[1, "two", true, null]')).to eq([1, "two", true, nil])
      end

      it "parses nested array" do
        expect(FlexJSON.parse("[[1, 2], [3, 4]]")).to eq([[1, 2], [3, 4]])
      end
    end

    describe "objects" do
      it "parses empty object" do
        expect(FlexJSON.parse("{}")).to eq({})
      end

      it "parses single-key object" do
        expect(FlexJSON.parse('{"a": 1}')).to eq({ "a" => 1 })
      end

      it "parses multi-key object" do
        expect(FlexJSON.parse('{"a": 1, "b": 2}')).to eq({ "a" => 1, "b" => 2 })
      end

      it "parses nested object" do
        expect(FlexJSON.parse('{"outer": {"inner": 42}}')).to eq({ "outer" => { "inner" => 42 } })
      end
    end

    describe "comprehensive fixture" do
      it "parses json_pass1.json end-to-end" do
        input = File.read(File.join(fixtures_dir, "json_pass1.json"))
        result = FlexJSON.parse(input)
        expect(result).to be_a(Array)
        expect(result[0]).to eq("JSON Test Pattern pass1")
        expect(result[1]).to eq({ "object with 1 member" => ["array with 1 element"] })
        expect(result[2]).to eq({})
        expect(result[3]).to eq([])
        expect(result[4]).to eq(-42)
        expect(result[5]).to eq(true)
        expect(result[6]).to eq(false)
        expect(result[7]).to be_nil
        expect(result[8]["integer"]).to eq(1_234_567_890)
        expect(result[8]["real"]).to eq(-9876.543210)
        expect(result[8]["controls"]).to eq("\b\f\n\r\t")
        expect(result[8]["url"]).to eq("http://www.JSON.org/")
      end
    end
  end

  # ============================================================
  # Layer 2 — JSON5 additions
  # ============================================================

  describe "JSON5 additions (Layer 2)" do
    describe "// line comments" do
      it "accepts a line comment before a value" do
        expect(FlexJSON.parse("// a comment\n42")).to eq(42)
      end

      it "accepts a line comment between object members" do
        expect(FlexJSON.parse('{"a": 1, // mid-line comment' + "\n" + '"b": 2}')).to eq({ "a" => 1, "b" => 2 })
      end
    end

    describe "/* */ block comments" do
      it "accepts a block comment before a value" do
        expect(FlexJSON.parse("/* block comment */ 42")).to eq(42)
      end

      it "accepts a block comment inside an array" do
        expect(FlexJSON.parse("[1, /* mid */ 2, 3]")).to eq([1, 2, 3])
      end

      it "accepts a multi-line block comment" do
        expect(FlexJSON.parse("/*\nmulti\nline\n*/ 42")).to eq(42)
      end
    end

    describe "trailing comma" do
      it "accepts trailing comma in array" do
        expect(FlexJSON.parse("[1, 2, 3,]")).to eq([1, 2, 3])
      end

      it "accepts trailing comma in object" do
        expect(FlexJSON.parse('{"a": 1, "b": 2,}')).to eq({ "a" => 1, "b" => 2 })
      end
    end

    describe "unquoted keys (ECMAScript identifier names)" do
      it "accepts simple identifier key" do
        expect(FlexJSON.parse("{foo: 1}")).to eq({ "foo" => 1 })
      end

      it "accepts identifier with underscore prefix" do
        expect(FlexJSON.parse("{_bar: 2}")).to eq({ "_bar" => 2 })
      end

      it "accepts identifier with dollar sign" do
        expect(FlexJSON.parse("{$baz: 3}")).to eq({ "$baz" => 3 })
      end

      it "accepts identifier with digits after first char" do
        expect(FlexJSON.parse("{a1b2: 1}")).to eq({ "a1b2" => 1 })
      end
    end

    describe "single-quoted strings" do
      it "parses single-quoted string value" do
        expect(FlexJSON.parse("{a: 'bar'}")).to eq({ "a" => "bar" })
      end

      it "parses single-quoted string with escaped single quote" do
        expect(FlexJSON.parse("'it\\'s'")).to eq("it's")
      end
    end

    describe "hex numbers" do
      it "parses 0xFF as 255" do
        expect(FlexJSON.parse("0xFF")).to eq(255)
      end

      it "parses negative hex number" do
        expect(FlexJSON.parse("-0x10")).to eq(-16)
      end
    end

    describe "leading/trailing decimal points" do
      it "parses .5 as 0.5" do
        expect(FlexJSON.parse(".5")).to eq(0.5)
      end

      it "parses 5. as 5.0" do
        expect(FlexJSON.parse("5.")).to eq(5.0)
      end
    end

    describe "Infinity and NaN" do
      it "parses Infinity" do
        expect(FlexJSON.parse("Infinity")).to eq(Float::INFINITY)
      end

      it "parses -Infinity" do
        expect(FlexJSON.parse("-Infinity")).to eq(-Float::INFINITY)
      end

      it "parses NaN" do
        expect(FlexJSON.parse("NaN")).to be_a(Float).and(be_nan)
      end
    end

    describe "explicit + sign on numbers" do
      it "parses +5 as 5" do
        expect(FlexJSON.parse("+5")).to eq(5)
      end
    end

    describe 'multi-line strings via \\-continuation' do
      it "joins lines via backslash continuation" do
        expect(FlexJSON.parse('"first\
second"')).to eq("firstsecond")
      end
    end
  end

  # ============================================================
  # Layer 3 — HJSON-inspired additions
  # ============================================================

  describe "HJSON-inspired additions (Layer 3)" do
    describe "# line comments" do
      it "accepts # comment before a value" do
        expect(FlexJSON.parse("# comment\n42")).to eq(42)
      end

      it "accepts # comment between object members" do
        expect(FlexJSON.parse("{a: 1 # comment\nb: 2}")).to eq({ "a" => 1, "b" => 2 })
      end
    end

    describe "comment-marker whitespace rule" do
      it "preserves URL with // (no whitespace before //)" do
        expect(FlexJSON.parse("url: http://example.com")).to eq({ "url" => "http://example.com" })
      end

      it "preserves identifier with mid-token #" do
        expect(FlexJSON.parse("method: Klass#meth")).to eq({ "method" => "Klass#meth" })
      end

      it "preserves email with mid-token #" do
        expect(FlexJSON.parse("email: foo@bar#example.com")).to eq({ "email" => "foo@bar#example.com" })
      end

      it "treats # after whitespace as a comment" do
        expect(FlexJSON.parse("name: Tilo # this is a comment")).to eq({ "name" => "Tilo" })
      end

      it "treats // after whitespace as a comment" do
        expect(FlexJSON.parse("name: Tilo // this is a comment")).to eq({ "name" => "Tilo" })
      end

      it "treats # at start of line as a comment" do
        expect(FlexJSON.parse("# top-level comment\nname: Tilo")).to eq({ "name" => "Tilo" })
      end

      it "preserves URL with full URL + trailing comment" do
        expect(FlexJSON.parse("url: http://example.com/ # see this site")).to eq({ "url" => "http://example.com/" })
      end

      it "keeps /* as part of the token when not preceded by whitespace" do
        expect(FlexJSON.parse("path: a/*b/c")).to eq({ "path" => "a/*b/c" })
      end

      it "treats /* after whitespace as a block comment" do
        expect(FlexJSON.parse("name: Tilo /* a comment */")).to eq({ "name" => "Tilo" })
      end
    end

    describe "triple-quoted multi-line strings" do
      it "parses single-line triple-quoted string" do
        expect(FlexJSON.parse("'''hello'''")).to eq("hello")
      end

      it "parses an empty triple-quoted string" do
        expect(FlexJSON.parse("''''''")).to eq("")
      end

      it "parses multi-line content at column 0 (no stripping)" do
        expect(FlexJSON.parse("'''first\nsecond'''")).to eq("first\nsecond")
      end

      it "does not process escapes — backslashes and quotes are literal" do
        expect(FlexJSON.parse("'''a \\ b \"q\" c'''")).to eq('a \\ b "q" c')
      end

      describe "indentation stripping (based on opening ''' marker column)" do
        it "marker alone on its line: strips structural indent, preserves surplus" do
          # opening ''' at column 4; content at 8/10/8 → keeps 4/6/4
          input = "    '''\n        first line\n          indented line\n        last line\n    '''"
          expect(FlexJSON.parse(input)).to eq("    first line\n      indented line\n    last line")
        end

        it "strips exactly to the marker column when content aligns with it" do
          # opening ''' at column 4; content also at 4 → fully stripped
          input = "    '''\n    first line\n      indented line\n    last line\n    '''"
          expect(FlexJSON.parse(input)).to eq("first line\n  indented line\nlast line")
        end

        it "text on the opening line is taken verbatim, later lines stripped" do
          input = "    '''first line\n      indented line\n    last line'''"
          expect(FlexJSON.parse(input)).to eq("first line\n  indented line\nlast line")
        end

        it "preserves a genuine blank line and the resulting trailing newline" do
          input = "    '''\n    first line\n    last line\n\n    '''"
          expect(FlexJSON.parse(input)).to eq("first line\nlast line\n")
        end

        it "never strips into the text when a line has less indent than the marker" do
          # opening ''' at column 4; a content line has only 2 leading spaces
          input = "    '''\n  short\n        deep\n    '''"
          expect(FlexJSON.parse(input)).to eq("short\n    deep")
        end

        it 'normalizes CRLF line endings to \\n inside the content' do
          input = "    '''\r\n    a\r\n    b\r\n    '''"
          expect(FlexJSON.parse(input)).to eq("a\nb")
        end
      end

      it "raises on an unterminated triple-quoted string" do
        expect { FlexJSON.parse("'''never closed") }.to raise_error(FlexJSON::ParseError, /unterminated/)
      end
    end

    describe "quoteless single-line strings" do
      it "parses simple quoteless string value" do
        expect(FlexJSON.parse("name: Tilo")).to eq({ "name" => "Tilo" })
      end

      it "trims surrounding whitespace from quoteless string" do
        expect(FlexJSON.parse("text:    hello world   ")).to eq({ "text" => "hello world" })
      end

      it "treats backslashes inside quoteless strings as literal (no escape processing)" do
        expect(FlexJSON.parse('text: a \ is just a \\').values.first).to eq('a \\ is just a \\')
      end

      it 'treats \\n inside a quoteless string as two literal characters' do
        # Ruby single-quoted source: the input is the 4 chars  a \ n b
        expect(FlexJSON.parse('x: a\nb')).to eq({ "x" => 'a\nb' })
      end

      it "terminates a quoteless value at }" do
        expect(FlexJSON.parse("{a: hello world}")).to eq({ "a" => "hello world" })
      end

      it "terminates a quoteless value at ]" do
        expect(FlexJSON.parse("[hello world]")).to eq(["hello world"])
      end

      it "treats a malformed number as a quoteless string (1.2.3)" do
        expect(FlexJSON.parse("{version: 1.2.3}")).to eq({ "version" => "1.2.3" })
      end

      it "treats a digit-led non-number token as a quoteless string (12abc)" do
        expect(FlexJSON.parse("{v: 12abc}")).to eq({ "v" => "12abc" })
      end
    end

    describe "leading-zero numbers fall through to quoteless strings" do
      it 'parses 0080 as the string "0080"' do
        expect(FlexJSON.parse("port: 0080")).to eq({ "port" => "0080" })
      end

      it 'parses 00 as the string "00"' do
        expect(FlexJSON.parse("n: 00")).to eq({ "n" => "00" })
      end

      it 'parses 02 as the string "02"' do
        expect(FlexJSON.parse("n: 02")).to eq({ "n" => "02" })
      end
    end

    describe "implicit root object" do
      it "parses key: value at top level without outer {}" do
        expect(FlexJSON.parse("host: localhost\nport: 5432")).to eq({ "host" => "localhost", "port" => 5432 })
      end

      it "parses nested object under implicit root" do
        input = "database:\n{\n  host: 127.0.0.1\n  port: 555\n}"
        expect(FlexJSON.parse(input)).to eq({ "database" => { "host" => "127.0.0.1", "port" => 555 } })
      end
    end

    describe "newline as separator" do
      it "separates object members on newlines without commas" do
        expect(FlexJSON.parse("{\n  a: 1\n  b: 2\n}")).to eq({ "a" => 1, "b" => 2 })
      end

      it "separates array elements on newlines without commas" do
        expect(FlexJSON.parse("[\n  1\n  2\n  3\n]")).to eq([1, 2, 3])
      end
    end

    describe "broader unquoted keys" do
      it "accepts {_var3: 1}" do
        expect(FlexJSON.parse("{_var3: 1}")).to eq({ "_var3" => 1 })
      end

      it "accepts {my-key: 1}" do
        expect(FlexJSON.parse("{my-key: 1}")).to eq({ "my-key" => 1 })
      end

      it "accepts {user-id-42: 1}" do
        expect(FlexJSON.parse("{user-id-42: 1}")).to eq({ "user-id-42" => 1 })
      end

      it "rejects key starting with a digit (123-foo)" do
        expect { FlexJSON.parse("{123-foo: 1}") }.to raise_error(FlexJSON::ParseError)
      end
    end

    describe "recognized literals win in quoteless context" do
      it "parses [1, 2, 3] as three integers" do
        expect(FlexJSON.parse("[1, 2, 3]")).to eq([1, 2, 3])
      end

      it 'parses [1 2 3] as the single string "1 2 3"' do
        expect(FlexJSON.parse("[1 2 3]")).to eq(["1 2 3"])
      end

      it "parses [red green blue] as a single-element array with one string" do
        expect(FlexJSON.parse("[red green blue]")).to eq(["red green blue"])
      end

      it "parses [red, green, blue] as three strings" do
        expect(FlexJSON.parse("[red, green, blue]")).to eq(%w[red green blue])
      end

      it "parses [true, false, null] as three literals" do
        expect(FlexJSON.parse("[true, false, null]")).to eq([true, false, nil])
      end

      it 'parses [true false] as the string "true false"' do
        expect(FlexJSON.parse("[true false]")).to eq(["true false"])
      end
    end
  end

  # ============================================================
  # Layer 4 — flex_json-specific features
  # ============================================================

  describe "flex_json features (Layer 4)" do
    describe "UTF-8 BOM" do
      it "strips UTF-8 BOM at start of input" do
        input = "\xEF\xBB\xBF{\"a\":1}".b.force_encoding("UTF-8")
        expect(FlexJSON.parse(input)).to eq({ "a" => 1 })
      end
    end

    describe "smart / curly quotes" do
      it "accepts curly double quotes as regular double quotes" do
        # U+201C LEFT DOUBLE QUOTATION MARK, U+201D RIGHT DOUBLE QUOTATION MARK
        input = "{\"a\": \u201Chello\u201D}"
        expect(FlexJSON.parse(input)).to eq({ "a" => "hello" })
      end

      it "accepts curly single quotes as regular single quotes" do
        # U+2018 LEFT SINGLE QUOTATION MARK, U+2019 RIGHT SINGLE QUOTATION MARK
        input = "{a: \u2018hello\u2019}"
        expect(FlexJSON.parse(input)).to eq({ "a" => "hello" })
      end
    end

    describe "Python literals" do
      it "parses True as true" do
        expect(FlexJSON.parse("True")).to eq(true)
      end

      it "parses False as false" do
        expect(FlexJSON.parse("False")).to eq(false)
      end

      it "parses None as nil" do
        expect(FlexJSON.parse("None")).to be_nil
      end
    end

    describe "JavaScript undefined" do
      it "parses undefined as nil" do
        expect(FlexJSON.parse("undefined")).to be_nil
      end
    end

    describe "underscores in numeric literals" do
      it "parses 1_000_000 as 1000000" do
        expect(FlexJSON.parse("1_000_000")).to eq(1_000_000)
      end

      it "parses 1_000.5 as 1000.5" do
        expect(FlexJSON.parse("1_000.5")).to eq(1000.5)
      end
    end

    describe "line ending normalization" do
      it "accepts CRLF line endings" do
        expect(FlexJSON.parse("{\r\n  a: 1\r\n  b: 2\r\n}")).to eq({ "a" => 1, "b" => 2 })
      end

      it "accepts CR-only line endings (classic Mac)" do
        expect(FlexJSON.parse("{\r  a: 1\r  b: 2\r}")).to eq({ "a" => 1, "b" => 2 })
      end

      it "accepts mixed line endings in one document" do
        expect(FlexJSON.parse("{\n  a: 1\r\n  b: 2\r  c: 3\n}")).to eq({ "a" => 1, "b" => 2, "c" => 3 })
      end
    end

    describe "duplicate keys" do
      it "last value wins by default" do
        expect(FlexJSON.parse('{"dup": 1, "dup": 2}')["dup"]).to eq(2)
      end
    end
  end

  # ============================================================
  # Top-level scalars (RFC 8259)
  # ============================================================

  describe "top-level scalars" do
    it "parses bare integer at top level" do
      expect(FlexJSON.parse("42")).to eq(42)
    end

    it "parses bare float at top level" do
      expect(FlexJSON.parse("3.14")).to eq(3.14)
    end

    it "parses bare string at top level" do
      expect(FlexJSON.parse('"hello"')).to eq("hello")
    end

    it "parses bare true at top level" do
      expect(FlexJSON.parse("true")).to eq(true)
    end

    it "parses bare null at top level" do
      expect(FlexJSON.parse("null")).to be_nil
    end
  end

  # ============================================================
  # Encoding handling (§3.1)
  # ============================================================

  describe "encoding handling" do
    it "preserves input string encoding (UTF-8)" do
      input = '{"name": "café"}'.dup.force_encoding("UTF-8")
      result = FlexJSON.parse(input)
      expect(result["name"]).to eq("café")
      expect(result["name"].encoding).to eq(Encoding::UTF_8)
    end

    it "preserves Latin-1 input encoding without transcoding" do
      # "café" in Latin-1: 0x63 0x61 0x66 0xE9
      input = "{\"name\": \"caf\xE9\"}".b.force_encoding("ISO-8859-1")
      result = FlexJSON.parse(input)
      expect(result["name"].encoding).to eq(Encoding::ISO_8859_1)
      expect(result["name"].bytes).to eq([0x63, 0x61, 0x66, 0xE9])
    end

    it "parse_file accepts :encoding option" do
      file = File.join(fixtures_dir, "json_pass1.json")
      result = FlexJSON.parse_file(file, encoding: "UTF-8")
      expect(result).to be_a(Array)
      expect(result[0]).to eq("JSON Test Pattern pass1")
    end
  end

  # ============================================================
  # Error handling
  # ============================================================

  describe "error handling" do
    it "raises FlexJSON::ParseError on truly unparseable input" do
      expect { FlexJSON.parse("this is not valid {json}") }.to raise_error(FlexJSON::ParseError)
    end

    it "raises FlexJSON::ParseError on unterminated string" do
      expect { FlexJSON.parse('"unterminated') }.to raise_error(FlexJSON::ParseError, /unterminated string/)
    end

    it "raises FlexJSON::ParseError on unterminated object" do
      expect { FlexJSON.parse('{"a": 1') }.to raise_error(FlexJSON::ParseError)
    end

    it "raises FlexJSON::ParseError on unterminated array" do
      expect { FlexJSON.parse("[1, 2, 3") }.to raise_error(FlexJSON::ParseError)
    end

    it "raises on a mismatched closing bracket in an array ([1, 2})" do
      expect { FlexJSON.parse("[1, 2}") }.to raise_error(FlexJSON::ParseError)
    end

    it 'raises on a mismatched closing bracket in an object ({"a": 1])' do
      expect { FlexJSON.parse('{"a": 1]') }.to raise_error(FlexJSON::ParseError)
    end

    it "raises on empty input" do
      expect { FlexJSON.parse("") }.to raise_error(FlexJSON::ParseError)
    end

    it "raises on whitespace-only input" do
      expect { FlexJSON.parse("    ") }.to raise_error(FlexJSON::ParseError)
    end

    it "raises on comment-only input (no value)" do
      expect { FlexJSON.parse("// just a comment\n") }.to raise_error(FlexJSON::ParseError)
    end

    it "raises FlexJSON::ParseError on bad escape sequence" do
      expect { FlexJSON.parse('"\q"') }.to raise_error(FlexJSON::ParseError, /escape/)
    end

    it "reports line and column on the error" do
      # A mismatched closing bracket on line 3 is genuinely unparseable.
      # (Note: `@` is NOT an error — it is a valid quoteless string.)

      FlexJSON.parse("{\n  \"a\": 1\n  ]")
      raise "expected ParseError"
    rescue FlexJSON::ParseError => e
      expect(e.line).to eq(3)
      expect(e.col).to be_a(Integer)
      expect(e.message).to match(/line/)
      expect(e.message).to match(/col/)
    end

    it 'parses {"a": @} as a quoteless string (not an error)' do
      expect(FlexJSON.parse('{"a": @}')).to eq({ "a" => "@" })
    end

    it "reports line and column on unterminated string" do
      FlexJSON.parse('"oops')
      raise "expected ParseError"
    rescue FlexJSON::ParseError => e
      expect(e.line).to eq(1)
      expect(e.col).to be > 1
    end
  end

  # ============================================================
  # parse_file
  # ============================================================

  describe "parse_file" do
    it "reads and parses a UTF-8 fixture file" do
      file = File.join(fixtures_dir, "json_pass1.json")
      result = FlexJSON.parse_file(file)
      expect(result).to be_a(Array)
      expect(result[0]).to eq("JSON Test Pattern pass1")
    end

    it "raises Errno::ENOENT for missing file" do
      expect { FlexJSON.parse_file("/nonexistent/path/to/file.json") }.to raise_error(Errno::ENOENT)
    end
  end

  # ============================================================
  # parse_many — multiple top-level values (JSONL / concatenated / streams)
  # ============================================================

  describe "parse_many" do
    it "returns a single-element array for one value" do
      expect(FlexJSON.parse_many('{"a": 1}')).to eq([{ "a" => 1 }])
    end

    it "wraps a top-level array as one element (no flattening)" do
      expect(FlexJSON.parse_many("[1, 2, 3]")).to eq([[1, 2, 3]])
    end

    it "parses newline-delimited JSON (JSONL/NDJSON)" do
      input = %({"event": 1}\n{"event": 2}\n{"event": 3}\n)
      expect(FlexJSON.parse_many(input)).to eq([{ "event" => 1 }, { "event" => 2 }, { "event" => 3 }])
    end

    it "parses concatenated objects with no separator" do
      expect(FlexJSON.parse_many('{"a":1}{"b":2}')).to eq([{ "a" => 1 }, { "b" => 2 }])
    end

    it "parses space-separated top-level values of mixed types" do
      expect(FlexJSON.parse_many('42 "x" true')).to eq([42, "x", true])
    end

    it "returns an empty array for empty input" do
      expect(FlexJSON.parse_many("")).to eq([])
    end

    it "returns an empty array for whitespace/comment-only input" do
      expect(FlexJSON.parse_many("  // just a comment\n  ")).to eq([])
    end
  end

  # ============================================================
  # Fixture-based integration tests
  # ============================================================

  describe "fixture-based integration" do
    it "parses comments_test.hjson with all comment styles and string values" do
      result = FlexJSON.parse_file(File.join(fixtures_dir, "comments_test.hjson"))
      expect(result["foo1"]).to eq("This is a string value.")   # quoteless, ends at " #"
      expect(result["foo2"]).to eq("This is a string value.")   # quoted
      expect(result["bar1"]).to eq("This is a string value.")   # quoteless, ends at " //"
      expect(result["bar2"]).to eq("This is a string value.")   # quoted
      expect(result["rem1"]).to eq("# test")                    # quoted, # is literal inside quotes
      expect(result["rem2"]).to eq("// test")                   # quoted
      expect(result["rem3"]).to eq("/* test */")                # quoted
      expect(result["num1"]).to eq(0)
      expect(result["num2"]).to eq(0.0)
      expect(result["num3"]).to eq(2)
      expect(result["true1"]).to eq(true)
      expect(result["false1"]).to eq(false)
      expect(result["null1"]).to be_nil
      expect(result["str1"]).to eq("00")                        # leading zero → string
      expect(result["str2"]).to eq("00.0")
      expect(result["str3"]).to eq("02")
    end

    it "parses strings_test.hjson and recognizes string-vs-literal distinction" do
      result = FlexJSON.parse_file(File.join(fixtures_dir, "strings_test.hjson"))
      expect(result["text1"]).to eq("This is a valid string value.")
      expect(result["text3"]).to eq("You need quotes\tfor escapes")
      expect(result["text4a"]).to eq(" untrimmed ")
      expect(result["not"]["number"]).to eq(5)
      expect(result["not"]["negative"]).to eq(-4.2)
      expect(result["not"]["yes"]).to eq(true)
      expect(result["not"]["no"]).to eq(false)
      expect(result["not"]["null"]).to be_nil
      expect(result["not"]["array"]).to eq([1, 2, 3, 4, 5, 6, 7, 8, 9, 0, -1, 0.5])
      expect(result["special"]["true"]).to eq("true") # quoted: stays a string
      expect(result["special"]["false"]).to eq("false")
      expect(result["special"]["null"]).to eq("null")
      expect(result["special"]["one"]).to eq("1")
      expect(result["special"]["minus"]).to eq("-3")
    end

    it "parses oa_test.hjson as a 7-element mixed array" do
      result = FlexJSON.parse_file(File.join(fixtures_dir, "oa_test.hjson"))
      expect(result.size).to eq(7)
      expect(result[0]).to eq("a")
      expect(result[1]).to eq({})
      expect(result[2]).to eq({})
      expect(result[3]).to eq([])
      expect(result[4]).to eq([])
      expect(result[5]).to eq({ "b" => 1, "c" => [], "d" => {} })
      expect(result[6]).to eq([])
    end

    it "parses root_test.hjson (implicit root + nested object)" do
      result = FlexJSON.parse_file(File.join(fixtures_dir, "root_test.hjson"))
      expect(result).to eq({ "database" => { "host" => "127.0.0.1", "port" => 555 } })
    end

    it "parses kan_test.hjson (mixed number/literal/string contexts)" do
      result = FlexJSON.parse_file(File.join(fixtures_dir, "kan_test.hjson"))
      # numbers context: recognized numbers (commas optional)
      expect(result["numbers"]).to eq([0, 0, -0, 42, 42.1, -5, -5.1, 1701.0, -1701.0, 12.345, -12.345])
      # native context: true/false/null
      expect(result["native"]).to eq([true, true, false, false, nil, nil])
      # strings context: quoteless strings (each whole-line value).
      expect(result["strings"]).to be_a(Array)
      expect(result["strings"]).to include("x 0", "00", "01", "0 0 0", "42 x", "42.1 asdf", "1.2.3",
                                           "true true", "false false", "null null", "x null")
      # DIVERGENCE from HJSON: flex_json adds JSON5's leading-decimal-point rule,
      # so `.0` is the number 0.0 (recognized literals win), not the string ".0".
      expect(result["strings"][1]).to eq(0.0)
    end

    it "parses empty_test.hjson with empty-string key" do
      result = FlexJSON.parse_file(File.join(fixtures_dir, "empty_test.hjson"))
      expect(result).to eq({ "" => "empty" })
    end

    it "raises on json_fail10.json trailing content (no silent data loss)" do
      input = File.read(File.join(fixtures_dir, "json_fail10.json"))
      # §3 row 21: `parse` returns exactly one value and raises if anything
      # follows it. The trailing "misplaced quoted value" must not be silently dropped.
      expect { FlexJSON.parse(input) }.to raise_error(FlexJSON::ParseError, /parse_many/)
    end

    it "recovers both values from json_fail10.json via parse_many" do
      input = File.read(File.join(fixtures_dir, "json_fail10.json"))
      result = FlexJSON.parse_many(input)
      expect(result).to eq([{ "Extra value after close" => true }, "misplaced quoted value"])
    end

    it "raises ParseError on oj_fail2.json (unclosed array)" do
      input = File.read(File.join(fixtures_dir, "oj_fail2.json"))
      expect { FlexJSON.parse(input) }.to raise_error(FlexJSON::ParseError)
    end

    it "parses oj_pass1.json (similar to json_pass1, with numeric overflow)" do
      result = FlexJSON.parse_file(File.join(fixtures_dir, "oj_pass1.json"))
      expect(result).to be_a(Array)
      expect(result[0]).to eq("JSON Test Pattern pass1")
      # 23456789012E666 overflows to Infinity (per §7.2 tentative)
      expect(result[8][""]).to eq(Float::INFINITY)
    end
  end

  # ============================================================
  # Control characters and escapes across quote styles
  # ============================================================

  describe "control characters and escapes" do
    it "keeps a raw tab byte literally inside a double-quoted string" do
      expect(FlexJSON.parse(%("a\tb"))).to eq("a\tb")
    end

    it "keeps a raw newline byte literally inside a double-quoted string" do
      expect(FlexJSON.parse(%("a\nb"))).to eq("a\nb")
    end

    it 'processes \\n escape inside a single-quoted string (same as double-quoted)' do
      # Ruby source "'a\\nb'" is the 5 chars  ' a \ n b ' → parser turns \n into a newline
      expect(FlexJSON.parse("'a\\nb'")).to eq("a\nb")
    end

    it 'processes \\t escape inside a single-quoted string' do
      expect(FlexJSON.parse("'a\\tb'")).to eq("a\tb")
    end
  end

  # ============================================================
  # Options (§5 API)
  # ============================================================

  describe "options" do
    describe "symbolize_keys" do
      it "returns symbol keys when symbolize_keys: true" do
        expect(FlexJSON.parse('{"a": 1, "b": 2}', symbolize_keys: true)).to eq({ a: 1, b: 2 })
      end

      it "symbolizes nested object keys" do
        expect(FlexJSON.parse('{"outer": {"inner": 1}}', symbolize_keys: true)).to eq({ outer: { inner: 1 } })
      end

      it "defaults to string keys" do
        expect(FlexJSON.parse('{"a": 1}')).to eq({ "a" => 1 })
      end
    end

    describe "max_depth" do
      it "raises when nesting exceeds the default (512)" do
        deep = ("[" * 1000) + ("]" * 1000)
        expect { FlexJSON.parse(deep) }.to raise_error(FlexJSON::ParseError, /depth|nest/i)
      end

      it "accepts nesting within an explicit max_depth" do
        expect(FlexJSON.parse("[[[1]]]", max_depth: 5)).to eq([[[1]]])
      end

      it "raises when nesting exceeds an explicit max_depth" do
        expect { FlexJSON.parse("[[[1]]]", max_depth: 2) }.to raise_error(FlexJSON::ParseError, /depth|nest/i)
      end
    end

    describe "duplicate_key" do
      it "last value wins by default" do
        expect(FlexJSON.parse('{"a": 1, "a": 2}')["a"]).to eq(2)
      end

      it "first value wins with duplicate_key: :first_wins" do
        expect(FlexJSON.parse('{"a": 1, "a": 2}', duplicate_key: :first_wins)["a"]).to eq(1)
      end

      it "raises with duplicate_key: :raise" do
        expect do
          FlexJSON.parse('{"a": 1, "a": 2}', duplicate_key: :raise)
        end.to raise_error(FlexJSON::ParseError, /duplicate/i)
      end
    end
  end

  # ============================================================
  # Whitespace semantics (Rails String#blank? / [[:space:]])
  # ============================================================

  describe "whitespace semantics ([[:space:]], same as Rails blank?)" do
    it "treats vertical tab (0x0B) as whitespace between tokens" do
      expect(FlexJSON.parse("[1,\x0B2,\x0B3]")).to eq([1, 2, 3])
    end

    it "treats form feed (0x0C) as whitespace between tokens" do
      expect(FlexJSON.parse("[1,\x0C2,\x0C3]")).to eq([1, 2, 3])
    end

    it "treats NBSP (U+00A0) as whitespace between tokens" do
      expect(FlexJSON.parse("[\u00A01\u00A0,\u00A02]")).to eq([1, 2])
    end

    it "trims NBSP (U+00A0) around a quoteless value" do
      expect(FlexJSON.parse("x:\u00A0value\u00A0")).to eq({ "x" => "value" })
    end
  end

  # ============================================================
  # Encoding errors (§3.1)
  # ============================================================

  describe "encoding errors" do
    it "raises FlexJSON::EncodingError on bytes invalid for the claimed encoding" do
      input = "\"bad\xFF byte\"".b.force_encoding("UTF-8") # 0xFF is not valid UTF-8
      expect { FlexJSON.parse(input) }.to raise_error(FlexJSON::EncodingError)
    end

    it "FlexJSON::EncodingError is a kind of ParseError" do
      expect(FlexJSON::EncodingError.ancestors).to include(FlexJSON::ParseError)
    end
  end

  # ============================================================
  # Out of scope — values returned as-is
  # ============================================================

  describe "out-of-scope values stay strings" do
    it "leaves a date string as a String (§3 row 22)" do
      expect(FlexJSON.parse('"2025-01-31"')).to eq("2025-01-31")
    end
  end
end
