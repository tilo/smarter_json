# frozen_string_literal: true

require "flex_json"

RSpec.describe FlexJSON do
  # Parity harness: each example runs on the C path (acceleration: true) and the
  # pure-Ruby path (acceleration: false). The option is passed straight into the
  # real FlexJSON.parse API — same pattern as smarter_csv's acceleration specs.
  [true, false].each do |acceleration|
    context "acceleration: #{acceleration}" do
      let(:fixtures_dir) { File.expand_path("fixtures", __dir__) }

      # ============================================================
      # Layer 1 — Strict JSON (RFC 8259)
      # ============================================================

      describe "strict JSON (Layer 1)" do
        describe "literals" do
          it "parses true" do
            expect(FlexJSON.parse("true", acceleration: acceleration)).to eq(true)
          end

          it "parses false" do
            expect(FlexJSON.parse("false", acceleration: acceleration)).to eq(false)
          end

          it "parses null as nil" do
            expect(FlexJSON.parse("null", acceleration: acceleration)).to be_nil
          end
        end

        describe "numbers" do
          it "parses zero" do
            expect(FlexJSON.parse("0", acceleration: acceleration)).to eq(0)
          end

          it "parses positive integer" do
            expect(FlexJSON.parse("1234567890", acceleration: acceleration)).to eq(1_234_567_890)
          end

          it "parses negative integer" do
            expect(FlexJSON.parse("-42", acceleration: acceleration)).to eq(-42)
          end

          it "parses float" do
            expect(FlexJSON.parse("-9876.543210", acceleration: acceleration)).to eq(-9876.543210)
          end

          it "parses scientific notation (lower e, negative exponent)" do
            expect(FlexJSON.parse("0.123456789e-12", acceleration: acceleration)).to eq(0.123456789e-12)
          end

          it "parses scientific notation (upper E, explicit +)" do
            expect(FlexJSON.parse("1.234567890E+34", acceleration: acceleration)).to eq(1.234567890E+34)
          end

          it "returns Infinity for numeric overflow (tentative §7.2)" do
            expect(FlexJSON.parse("1e500", acceleration: acceleration)).to eq(Float::INFINITY)
          end
        end

        describe "strings" do
          it "parses simple double-quoted string" do
            expect(FlexJSON.parse('"hello"', acceleration: acceleration)).to eq("hello")
          end

          it "parses empty string" do
            expect(FlexJSON.parse('""', acceleration: acceleration)).to eq("")
          end

          it "parses string with escaped quote" do
            expect(FlexJSON.parse('"\""', acceleration: acceleration)).to eq('"')
          end

          it "parses string with backslash escape" do
            expect(FlexJSON.parse('"\\\\"', acceleration: acceleration)).to eq("\\")
          end

          it "parses string with control character escapes" do
            expect(FlexJSON.parse('"\b\f\n\r\t"', acceleration: acceleration)).to eq("\b\f\n\r\t")
          end

          it "parses string with forward-slash escape" do
            expect(FlexJSON.parse('"\/"', acceleration: acceleration)).to eq("/")
          end

          it 'parses BMP \\uXXXX escape' do
            expect(FlexJSON.parse('"A"', acceleration: acceleration)).to eq("A")
          end

          it 'parses surrogate pair \\uD83D\\uDE00 (😀)' do
            expect(FlexJSON.parse('"😀"', acceleration: acceleration)).to eq("\u{1F600}")
          end
        end

        describe "arrays" do
          it "parses empty array" do
            expect(FlexJSON.parse("[]", acceleration: acceleration)).to eq([])
          end

          it "parses array of integers" do
            expect(FlexJSON.parse("[1, 2, 3]", acceleration: acceleration)).to eq([1, 2, 3])
          end

          it "parses array of mixed types" do
            expect(FlexJSON.parse('[1, "two", true, null]', acceleration: acceleration)).to eq([1, "two", true, nil])
          end

          it "parses nested array" do
            expect(FlexJSON.parse("[[1, 2], [3, 4]]", acceleration: acceleration)).to eq([[1, 2], [3, 4]])
          end
        end

        describe "objects" do
          it "parses empty object" do
            expect(FlexJSON.parse("{}", acceleration: acceleration)).to eq({})
          end

          it "parses single-key object" do
            expect(FlexJSON.parse('{"a": 1}', acceleration: acceleration)).to eq({ "a" => 1 })
          end

          it "parses multi-key object" do
            expect(FlexJSON.parse('{"a": 1, "b": 2}', acceleration: acceleration)).to eq({ "a" => 1, "b" => 2 })
          end

          it "parses nested object" do
            expect(FlexJSON.parse('{"outer": {"inner": 42}}', acceleration: acceleration)).to eq({ "outer" => { "inner" => 42 } })
          end
        end

        describe "comprehensive fixture" do
          it "parses json_pass1.json end-to-end" do
            input = File.read(File.join(fixtures_dir, "json_pass1.json"))
            result = FlexJSON.parse(input, acceleration: acceleration)
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
            expect(FlexJSON.parse("// a comment\n42", acceleration: acceleration)).to eq(42)
          end

          it "accepts a line comment between object members" do
            expect(FlexJSON.parse('{"a": 1, // mid-line comment' + "\n" + '"b": 2}', acceleration: acceleration)).to eq({ "a" => 1, "b" => 2 })
          end
        end

        describe "/* */ block comments" do
          it "accepts a block comment before a value" do
            expect(FlexJSON.parse("/* block comment */ 42", acceleration: acceleration)).to eq(42)
          end

          it "accepts a block comment inside an array" do
            expect(FlexJSON.parse("[1, /* mid */ 2, 3]", acceleration: acceleration)).to eq([1, 2, 3])
          end

          it "accepts a multi-line block comment" do
            expect(FlexJSON.parse("/*\nmulti\nline\n*/ 42", acceleration: acceleration)).to eq(42)
          end
        end

        describe "trailing comma" do
          it "accepts trailing comma in array" do
            expect(FlexJSON.parse("[1, 2, 3,]", acceleration: acceleration)).to eq([1, 2, 3])
          end

          it "accepts trailing comma in object" do
            expect(FlexJSON.parse('{"a": 1, "b": 2,}', acceleration: acceleration)).to eq({ "a" => 1, "b" => 2 })
          end
        end

        describe "unquoted keys (ECMAScript identifier names)" do
          it "accepts simple identifier key" do
            expect(FlexJSON.parse("{foo: 1}", acceleration: acceleration)).to eq({ "foo" => 1 })
          end

          it "accepts identifier with underscore prefix" do
            expect(FlexJSON.parse("{_bar: 2}", acceleration: acceleration)).to eq({ "_bar" => 2 })
          end

          it "accepts identifier with dollar sign" do
            expect(FlexJSON.parse("{$baz: 3}", acceleration: acceleration)).to eq({ "$baz" => 3 })
          end

          it "accepts identifier with digits after first char" do
            expect(FlexJSON.parse("{a1b2: 1}", acceleration: acceleration)).to eq({ "a1b2" => 1 })
          end
        end

        describe "single-quoted strings" do
          it "parses single-quoted string value" do
            expect(FlexJSON.parse("{a: 'bar'}", acceleration: acceleration)).to eq({ "a" => "bar" })
          end

          it "parses single-quoted string with escaped single quote" do
            expect(FlexJSON.parse("'it\\'s'", acceleration: acceleration)).to eq("it's")
          end
        end

        describe "hex numbers" do
          it "parses 0xFF as 255" do
            expect(FlexJSON.parse("0xFF", acceleration: acceleration)).to eq(255)
          end

          it "parses negative hex number" do
            expect(FlexJSON.parse("-0x10", acceleration: acceleration)).to eq(-16)
          end
        end

        describe "leading/trailing decimal points" do
          it "parses .5 as 0.5" do
            expect(FlexJSON.parse(".5", acceleration: acceleration)).to eq(0.5)
          end

          it "parses 5. as 5.0" do
            expect(FlexJSON.parse("5.", acceleration: acceleration)).to eq(5.0)
          end
        end

        describe "Infinity and NaN" do
          it "parses Infinity" do
            expect(FlexJSON.parse("Infinity", acceleration: acceleration)).to eq(Float::INFINITY)
          end

          it "parses -Infinity" do
            expect(FlexJSON.parse("-Infinity", acceleration: acceleration)).to eq(-Float::INFINITY)
          end

          it "parses NaN" do
            expect(FlexJSON.parse("NaN", acceleration: acceleration)).to be_a(Float).and(be_nan)
          end
        end

        describe "explicit + sign on numbers" do
          it "parses +5 as 5" do
            expect(FlexJSON.parse("+5", acceleration: acceleration)).to eq(5)
          end
        end

        describe 'multi-line strings via \\-continuation' do
          it "joins lines via backslash continuation" do
            expect(FlexJSON.parse('"first\
second"', acceleration: acceleration)).to eq("firstsecond")
          end
        end
      end

      # ============================================================
      # Layer 3 — HJSON-inspired additions
      # ============================================================

      describe "HJSON-inspired additions (Layer 3)" do
        describe "# line comments" do
          it "accepts # comment before a value" do
            expect(FlexJSON.parse("# comment\n42", acceleration: acceleration)).to eq(42)
          end

          it "accepts # comment between object members" do
            expect(FlexJSON.parse("{a: 1 # comment\nb: 2}", acceleration: acceleration)).to eq({ "a" => 1, "b" => 2 })
          end
        end

        describe "comment-marker whitespace rule" do
          it "preserves URL with // (no whitespace before //)" do
            expect(FlexJSON.parse("url: http://example.com", acceleration: acceleration)).to eq({ "url" => "http://example.com" })
          end

          it "preserves identifier with mid-token #" do
            expect(FlexJSON.parse("method: Klass#meth", acceleration: acceleration)).to eq({ "method" => "Klass#meth" })
          end

          it "preserves email with mid-token #" do
            expect(FlexJSON.parse("email: foo@bar#example.com", acceleration: acceleration)).to eq({ "email" => "foo@bar#example.com" })
          end

          it "treats # after whitespace as a comment" do
            expect(FlexJSON.parse("name: Tilo # this is a comment", acceleration: acceleration)).to eq({ "name" => "Tilo" })
          end

          it "treats // after whitespace as a comment" do
            expect(FlexJSON.parse("name: Tilo // this is a comment", acceleration: acceleration)).to eq({ "name" => "Tilo" })
          end

          it "treats # at start of line as a comment" do
            expect(FlexJSON.parse("# top-level comment\nname: Tilo", acceleration: acceleration)).to eq({ "name" => "Tilo" })
          end

          it "preserves URL with full URL + trailing comment" do
            expect(FlexJSON.parse("url: http://example.com/ # see this site", acceleration: acceleration)).to eq({ "url" => "http://example.com/" })
          end

          it "keeps /* as part of the token when not preceded by whitespace" do
            expect(FlexJSON.parse("path: a/*b/c", acceleration: acceleration)).to eq({ "path" => "a/*b/c" })
          end

          it "treats /* after whitespace as a block comment" do
            expect(FlexJSON.parse("name: Tilo /* a comment */", acceleration: acceleration)).to eq({ "name" => "Tilo" })
          end
        end

        describe "triple-quoted multi-line strings" do
          it "parses single-line triple-quoted string" do
            expect(FlexJSON.parse("'''hello'''", acceleration: acceleration)).to eq("hello")
          end

          it "parses an empty triple-quoted string" do
            expect(FlexJSON.parse("''''''", acceleration: acceleration)).to eq("")
          end

          it "parses multi-line content at column 0 (no stripping)" do
            expect(FlexJSON.parse("'''first\nsecond'''", acceleration: acceleration)).to eq("first\nsecond")
          end

          it "does not process escapes — backslashes and quotes are literal" do
            expect(FlexJSON.parse("'''a \\ b \"q\" c'''", acceleration: acceleration)).to eq('a \\ b "q" c')
          end

          describe "indentation stripping (based on opening ''' marker column)" do
            it "marker alone on its line: strips structural indent, preserves surplus" do
              # opening ''' at column 4; content at 8/10/8 → keeps 4/6/4
              input = "    '''\n        first line\n          indented line\n        last line\n    '''"
              expect(FlexJSON.parse(input, acceleration: acceleration)).to eq("    first line\n      indented line\n    last line")
            end

            it "strips exactly to the marker column when content aligns with it" do
              # opening ''' at column 4; content also at 4 → fully stripped
              input = "    '''\n    first line\n      indented line\n    last line\n    '''"
              expect(FlexJSON.parse(input, acceleration: acceleration)).to eq("first line\n  indented line\nlast line")
            end

            it "text on the opening line is taken verbatim, later lines stripped" do
              input = "    '''first line\n      indented line\n    last line'''"
              expect(FlexJSON.parse(input, acceleration: acceleration)).to eq("first line\n  indented line\nlast line")
            end

            it "preserves a genuine blank line and the resulting trailing newline" do
              input = "    '''\n    first line\n    last line\n\n    '''"
              expect(FlexJSON.parse(input, acceleration: acceleration)).to eq("first line\nlast line\n")
            end

            it "never strips into the text when a line has less indent than the marker" do
              # opening ''' at column 4; a content line has only 2 leading spaces
              input = "    '''\n  short\n        deep\n    '''"
              expect(FlexJSON.parse(input, acceleration: acceleration)).to eq("short\n    deep")
            end

            it 'normalizes CRLF line endings to \\n inside the content' do
              input = "    '''\r\n    a\r\n    b\r\n    '''"
              expect(FlexJSON.parse(input, acceleration: acceleration)).to eq("a\nb")
            end
          end

          it "raises on an unterminated triple-quoted string" do
            expect { FlexJSON.parse("'''never closed", acceleration: acceleration) }.to raise_error(FlexJSON::ParseError, /unterminated/)
          end
        end

        describe "quoteless single-line strings" do
          it "parses simple quoteless string value" do
            expect(FlexJSON.parse("name: Tilo", acceleration: acceleration)).to eq({ "name" => "Tilo" })
          end

          it "trims surrounding whitespace from quoteless string" do
            expect(FlexJSON.parse("text:    hello world   ", acceleration: acceleration)).to eq({ "text" => "hello world" })
          end

          it "treats backslashes inside quoteless strings as literal (no escape processing)" do
            expect(FlexJSON.parse('text: a \ is just a \\', acceleration: acceleration).values.first).to eq('a \\ is just a \\')
          end

          it 'treats \\n inside a quoteless string as two literal characters' do
            # Ruby single-quoted source: the input is the 4 chars  a \ n b
            expect(FlexJSON.parse('x: a\nb', acceleration: acceleration)).to eq({ "x" => 'a\nb' })
          end

          it "terminates a quoteless value at }" do
            expect(FlexJSON.parse("{a: hello world}", acceleration: acceleration)).to eq({ "a" => "hello world" })
          end

          it "terminates a quoteless value at ]" do
            expect(FlexJSON.parse("[hello world]", acceleration: acceleration)).to eq(["hello world"])
          end

          it "treats a malformed number as a quoteless string (1.2.3)" do
            expect(FlexJSON.parse("{version: 1.2.3}", acceleration: acceleration)).to eq({ "version" => "1.2.3" })
          end

          it "treats a digit-led non-number token as a quoteless string (12abc)" do
            expect(FlexJSON.parse("{v: 12abc}", acceleration: acceleration)).to eq({ "v" => "12abc" })
          end
        end

        describe "leading-zero numbers fall through to quoteless strings" do
          it 'parses 0080 as the string "0080"' do
            expect(FlexJSON.parse("port: 0080", acceleration: acceleration)).to eq({ "port" => "0080" })
          end

          it 'parses 00 as the string "00"' do
            expect(FlexJSON.parse("n: 00", acceleration: acceleration)).to eq({ "n" => "00" })
          end

          it 'parses 02 as the string "02"' do
            expect(FlexJSON.parse("n: 02", acceleration: acceleration)).to eq({ "n" => "02" })
          end
        end

        describe "implicit root object" do
          it "parses key: value at top level without outer {}" do
            expect(FlexJSON.parse("host: localhost\nport: 5432", acceleration: acceleration)).to eq({ "host" => "localhost", "port" => 5432 })
          end

          it "parses nested object under implicit root" do
            input = "database:\n{\n  host: 127.0.0.1\n  port: 555\n}"
            expect(FlexJSON.parse(input, acceleration: acceleration)).to eq({ "database" => { "host" => "127.0.0.1", "port" => 555 } })
          end
        end

        describe "newline as separator" do
          it "separates object members on newlines without commas" do
            expect(FlexJSON.parse("{\n  a: 1\n  b: 2\n}", acceleration: acceleration)).to eq({ "a" => 1, "b" => 2 })
          end

          it "separates array elements on newlines without commas" do
            expect(FlexJSON.parse("[\n  1\n  2\n  3\n]", acceleration: acceleration)).to eq([1, 2, 3])
          end
        end

        describe "broader unquoted keys" do
          it "accepts {_var3: 1}" do
            expect(FlexJSON.parse("{_var3: 1}", acceleration: acceleration)).to eq({ "_var3" => 1 })
          end

          it "accepts {my-key: 1}" do
            expect(FlexJSON.parse("{my-key: 1}", acceleration: acceleration)).to eq({ "my-key" => 1 })
          end

          it "accepts {user-id-42: 1}" do
            expect(FlexJSON.parse("{user-id-42: 1}", acceleration: acceleration)).to eq({ "user-id-42" => 1 })
          end

          it "rejects key starting with a digit (123-foo)" do
            expect { FlexJSON.parse("{123-foo: 1}", acceleration: acceleration) }.to raise_error(FlexJSON::ParseError)
          end
        end

        describe "recognized literals win in quoteless context" do
          it "parses [1, 2, 3] as three integers" do
            expect(FlexJSON.parse("[1, 2, 3]", acceleration: acceleration)).to eq([1, 2, 3])
          end

          it 'parses [1 2 3] as the single string "1 2 3"' do
            expect(FlexJSON.parse("[1 2 3]", acceleration: acceleration)).to eq(["1 2 3"])
          end

          # Boundary cases for the container-number fast path: a number commits
          # only when it abuts a value terminator; anything else falls back to the
          # quoteless scanner, which must still produce the identical result.
          it "commits numbers that abut a delimiter (comma/bracket/brace/newline)" do
            expect(FlexJSON.parse("[1,2,3]", acceleration: acceleration)).to eq([1, 2, 3])
            expect(FlexJSON.parse('{"a":1,"b":2.5}', acceleration: acceleration)).to eq("a" => 1, "b" => 2.5)
            expect(FlexJSON.parse("[1.5e3,-7]", acceleration: acceleration)).to eq([1500.0, -7])
            expect(FlexJSON.parse("[\n1\n,\n2\n]", acceleration: acceleration)).to eq([1, 2])
          end

          it "still parses numbers correctly when whitespace separates them from the delimiter" do
            expect(FlexJSON.parse("[1 , 2]", acceleration: acceleration)).to eq([1, 2])
            expect(FlexJSON.parse("[3 ]", acceleration: acceleration)).to eq([3])
            expect(FlexJSON.parse('{"a": 1 }', acceleration: acceleration)).to eq("a" => 1)
          end

          it "falls back to string/hex/Infinity for digit-led non-plain-numbers in containers" do
            expect(FlexJSON.parse("[0xFF]", acceleration: acceleration)).to eq([255])
            expect(FlexJSON.parse("[-Infinity, 12]", acceleration: acceleration)).to eq([-Float::INFINITY, 12])
            expect(FlexJSON.parse("[1.2.3]", acceleration: acceleration)).to eq(["1.2.3"])
            expect(FlexJSON.parse("[1_000, 2_000]", acceleration: acceleration)).to eq([1000, 2000])
          end

          it "parses [red green blue] as a single-element array with one string" do
            expect(FlexJSON.parse("[red green blue]", acceleration: acceleration)).to eq(["red green blue"])
          end

          it "parses [red, green, blue] as three strings" do
            expect(FlexJSON.parse("[red, green, blue]", acceleration: acceleration)).to eq(%w[red green blue])
          end

          it "parses [true, false, null] as three literals" do
            expect(FlexJSON.parse("[true, false, null]", acceleration: acceleration)).to eq([true, false, nil])
          end

          it 'parses [true false] as the string "true false"' do
            expect(FlexJSON.parse("[true false]", acceleration: acceleration)).to eq(["true false"])
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
            expect(FlexJSON.parse(input, acceleration: acceleration)).to eq({ "a" => 1 })
          end
        end

        describe "smart / curly quotes" do
          it "accepts curly double quotes as regular double quotes" do
            # U+201C LEFT DOUBLE QUOTATION MARK, U+201D RIGHT DOUBLE QUOTATION MARK
            input = "{\"a\": \u201Chello\u201D}"
            expect(FlexJSON.parse(input, acceleration: acceleration)).to eq({ "a" => "hello" })
          end

          it "accepts curly single quotes as regular single quotes" do
            # U+2018 LEFT SINGLE QUOTATION MARK, U+2019 RIGHT SINGLE QUOTATION MARK
            input = "{a: \u2018hello\u2019}"
            expect(FlexJSON.parse(input, acceleration: acceleration)).to eq({ "a" => "hello" })
          end
        end

        describe "Python literals" do
          it "parses True as true" do
            expect(FlexJSON.parse("True", acceleration: acceleration)).to eq(true)
          end

          it "parses False as false" do
            expect(FlexJSON.parse("False", acceleration: acceleration)).to eq(false)
          end

          it "parses None as nil" do
            expect(FlexJSON.parse("None", acceleration: acceleration)).to be_nil
          end
        end

        describe "JavaScript undefined" do
          it "parses undefined as nil" do
            expect(FlexJSON.parse("undefined", acceleration: acceleration)).to be_nil
          end
        end

        describe "underscores in numeric literals" do
          it "parses 1_000_000 as 1000000" do
            expect(FlexJSON.parse("1_000_000", acceleration: acceleration)).to eq(1_000_000)
          end

          it "parses 1_000.5 as 1000.5" do
            expect(FlexJSON.parse("1_000.5", acceleration: acceleration)).to eq(1000.5)
          end
        end

        describe "line ending normalization" do
          it "accepts CRLF line endings" do
            expect(FlexJSON.parse("{\r\n  a: 1\r\n  b: 2\r\n}", acceleration: acceleration)).to eq({ "a" => 1, "b" => 2 })
          end

          it "accepts CR-only line endings (classic Mac)" do
            expect(FlexJSON.parse("{\r  a: 1\r  b: 2\r}", acceleration: acceleration)).to eq({ "a" => 1, "b" => 2 })
          end

          it "accepts mixed line endings in one document" do
            expect(FlexJSON.parse("{\n  a: 1\r\n  b: 2\r  c: 3\n}", acceleration: acceleration)).to eq({ "a" => 1, "b" => 2, "c" => 3 })
          end
        end

        describe "duplicate keys" do
          it "last value wins by default" do
            expect(FlexJSON.parse('{"dup": 1, "dup": 2}', acceleration: acceleration)["dup"]).to eq(2)
          end
        end
      end

      # ============================================================
      # Top-level scalars (RFC 8259)
      # ============================================================

      describe "top-level scalars" do
        it "parses bare integer at top level" do
          expect(FlexJSON.parse("42", acceleration: acceleration)).to eq(42)
        end

        it "parses bare float at top level" do
          expect(FlexJSON.parse("3.14", acceleration: acceleration)).to eq(3.14)
        end

        it "parses bare string at top level" do
          expect(FlexJSON.parse('"hello"', acceleration: acceleration)).to eq("hello")
        end

        it "parses bare true at top level" do
          expect(FlexJSON.parse("true", acceleration: acceleration)).to eq(true)
        end

        it "parses bare null at top level" do
          expect(FlexJSON.parse("null", acceleration: acceleration)).to be_nil
        end
      end

      # ============================================================
      # Encoding handling (§3.1)
      # ============================================================

      describe "encoding handling" do
        it "preserves input string encoding (UTF-8)" do
          input = '{"name": "café"}'.dup.force_encoding("UTF-8")
          result = FlexJSON.parse(input, acceleration: acceleration)
          expect(result["name"]).to eq("café")
          expect(result["name"].encoding).to eq(Encoding::UTF_8)
        end

        it "preserves Latin-1 input encoding without transcoding" do
          # "café" in Latin-1: 0x63 0x61 0x66 0xE9
          input = "{\"name\": \"caf\xE9\"}".b.force_encoding("ISO-8859-1")
          result = FlexJSON.parse(input, acceleration: acceleration)
          expect(result["name"].encoding).to eq(Encoding::ISO_8859_1)
          expect(result["name"].bytes).to eq([0x63, 0x61, 0x66, 0xE9])
        end

        it "parse_file accepts :encoding option" do
          file = File.join(fixtures_dir, "json_pass1.json")
          result = FlexJSON.parse_file(file, encoding: "UTF-8", acceleration: acceleration)
          expect(result).to be_a(Array)
          expect(result[0]).to eq("JSON Test Pattern pass1")
        end
      end

      # ============================================================
      # Error handling
      # ============================================================

      describe "error handling" do
        it "raises FlexJSON::ParseError on truly unparseable input" do
          expect { FlexJSON.parse("this is not valid {json}", acceleration: acceleration) }.to raise_error(FlexJSON::ParseError)
        end

        it "raises FlexJSON::ParseError on unterminated string" do
          expect { FlexJSON.parse('"unterminated', acceleration: acceleration) }.to raise_error(FlexJSON::ParseError, /unterminated string/)
        end

        it "raises FlexJSON::ParseError on unterminated object" do
          expect { FlexJSON.parse('{"a": 1', acceleration: acceleration) }.to raise_error(FlexJSON::ParseError)
        end

        it "raises FlexJSON::ParseError on unterminated array" do
          expect { FlexJSON.parse("[1, 2, 3", acceleration: acceleration) }.to raise_error(FlexJSON::ParseError)
        end

        it "raises on a mismatched closing bracket in an array ([1, 2})" do
          expect { FlexJSON.parse("[1, 2}", acceleration: acceleration) }.to raise_error(FlexJSON::ParseError)
        end

        it 'raises on a mismatched closing bracket in an object ({"a": 1])' do
          expect { FlexJSON.parse('{"a": 1]', acceleration: acceleration) }.to raise_error(FlexJSON::ParseError)
        end

        it "raises on empty input" do
          expect { FlexJSON.parse("", acceleration: acceleration) }.to raise_error(FlexJSON::ParseError)
        end

        it "raises on whitespace-only input" do
          expect { FlexJSON.parse("    ", acceleration: acceleration) }.to raise_error(FlexJSON::ParseError)
        end

        it "raises on comment-only input (no value)" do
          expect { FlexJSON.parse("// just a comment\n", acceleration: acceleration) }.to raise_error(FlexJSON::ParseError)
        end

        it "raises FlexJSON::ParseError on bad escape sequence" do
          expect { FlexJSON.parse('"\q"', acceleration: acceleration) }.to raise_error(FlexJSON::ParseError, /escape/)
        end

        it "reports line and column on the error" do
          # A mismatched closing bracket on line 3 is genuinely unparseable.
          # (Note: `@` is NOT an error — it is a valid quoteless string.)

          FlexJSON.parse("{\n  \"a\": 1\n  ]", acceleration: acceleration)
          raise "expected ParseError"
        rescue FlexJSON::ParseError => e
          expect(e.line).to eq(3)
          expect(e.col).to be_a(Integer)
          expect(e.message).to match(/line/)
          expect(e.message).to match(/col/)
        end

        it 'parses {"a": @} as a quoteless string (not an error)' do
          expect(FlexJSON.parse('{"a": @}', acceleration: acceleration)).to eq({ "a" => "@" })
        end

        it "reports line and column on unterminated string" do
          FlexJSON.parse('"oops', acceleration: acceleration)
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
          result = FlexJSON.parse_file(file, acceleration: acceleration)
          expect(result).to be_a(Array)
          expect(result[0]).to eq("JSON Test Pattern pass1")
        end

        it "raises Errno::ENOENT for missing file" do
          expect { FlexJSON.parse_file("/nonexistent/path/to/file.json", acceleration: acceleration) }.to raise_error(Errno::ENOENT)
        end
      end

      # ============================================================
      # parse with a block — yields each top-level value (JSONL / concatenated / streams)
      # ============================================================

      describe "parse with a block (multiple top-level values)" do
        # Collect the values yielded by the block form of FlexJSON.parse.
        def parse_values(input, **opts)
          values = []
          FlexJSON.parse(input, **opts) { |v| values << v }
          values
        end

        it "yields a single value for one document" do
          expect(parse_values('{"a": 1}', acceleration: acceleration)).to eq([{ "a" => 1 }])
        end

        it "yields a top-level array as one value (no flattening)" do
          expect(parse_values("[1, 2, 3]", acceleration: acceleration)).to eq([[1, 2, 3]])
        end

        it "yields each value of newline-delimited JSON (JSONL/NDJSON)" do
          input = %({"event": 1}\n{"event": 2}\n{"event": 3}\n)
          expect(parse_values(input, acceleration: acceleration)).to eq([{ "event" => 1 }, { "event" => 2 }, { "event" => 3 }])
        end

        it "yields each of concatenated objects with no separator" do
          expect(parse_values('{"a":1}{"b":2}', acceleration: acceleration)).to eq([{ "a" => 1 }, { "b" => 2 }])
        end

        it "yields space-separated top-level values of mixed types" do
          expect(parse_values('42 "x" true', acceleration: acceleration)).to eq([42, "x", true])
        end

        it "yields nothing for empty input" do
          expect(parse_values("", acceleration: acceleration)).to eq([])
        end

        it "yields nothing for whitespace/comment-only input" do
          expect(parse_values("  // just a comment\n  ", acceleration: acceleration)).to eq([])
        end

        it "returns nil from the block form" do
          expect(FlexJSON.parse('{"a": 1}', acceleration: acceleration) { |_v| }).to be_nil
        end
      end

      # ============================================================
      # Fixture-based integration tests
      # ============================================================

      describe "fixture-based integration" do
        it "parses comments_test.hjson with all comment styles and string values" do
          result = FlexJSON.parse_file(File.join(fixtures_dir, "comments_test.hjson"), acceleration: acceleration)
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
          result = FlexJSON.parse_file(File.join(fixtures_dir, "strings_test.hjson"), acceleration: acceleration)
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
          result = FlexJSON.parse_file(File.join(fixtures_dir, "oa_test.hjson"), acceleration: acceleration)
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
          result = FlexJSON.parse_file(File.join(fixtures_dir, "root_test.hjson"), acceleration: acceleration)
          expect(result).to eq({ "database" => { "host" => "127.0.0.1", "port" => 555 } })
        end

        it "parses kan_test.hjson (mixed number/literal/string contexts)" do
          result = FlexJSON.parse_file(File.join(fixtures_dir, "kan_test.hjson"), acceleration: acceleration)
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
          result = FlexJSON.parse_file(File.join(fixtures_dir, "empty_test.hjson"), acceleration: acceleration)
          expect(result).to eq({ "" => "empty" })
        end

        it "raises on json_fail10.json trailing content (no silent data loss)" do
          input = File.read(File.join(fixtures_dir, "json_fail10.json"))
          # §3 row 21: `parse` returns exactly one value and raises if anything
          # follows it. The trailing "misplaced quoted value" must not be silently dropped.
          # The message points the caller at the block form.
          expect { FlexJSON.parse(input, acceleration: acceleration) }.to raise_error(FlexJSON::ParseError, /block/)
        end

        it "recovers both values from json_fail10.json via the block form" do
          input = File.read(File.join(fixtures_dir, "json_fail10.json"))
          result = []
          FlexJSON.parse(input, acceleration: acceleration) { |v| result << v }
          expect(result).to eq([{ "Extra value after close" => true }, "misplaced quoted value"])
        end

        it "raises ParseError on oj_fail2.json (unclosed array)" do
          input = File.read(File.join(fixtures_dir, "oj_fail2.json"))
          expect { FlexJSON.parse(input, acceleration: acceleration) }.to raise_error(FlexJSON::ParseError)
        end

        it "parses oj_pass1.json (similar to json_pass1, with numeric overflow)" do
          result = FlexJSON.parse_file(File.join(fixtures_dir, "oj_pass1.json"), acceleration: acceleration)
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
          expect(FlexJSON.parse(%("a\tb"), acceleration: acceleration)).to eq("a\tb")
        end

        it "keeps a raw newline byte literally inside a double-quoted string" do
          expect(FlexJSON.parse(%("a\nb"), acceleration: acceleration)).to eq("a\nb")
        end

        it 'processes \\n escape inside a single-quoted string (same as double-quoted)' do
          # Ruby source "'a\\nb'" is the 5 chars  ' a \ n b ' → parser turns \n into a newline
          expect(FlexJSON.parse("'a\\nb'", acceleration: acceleration)).to eq("a\nb")
        end

        it 'processes \\t escape inside a single-quoted string' do
          expect(FlexJSON.parse("'a\\tb'", acceleration: acceleration)).to eq("a\tb")
        end
      end

      # ============================================================
      # Options (§5 API)
      # ============================================================

      describe "options" do
        describe "symbolize_keys" do
          it "returns symbol keys when symbolize_keys: true" do
            expect(FlexJSON.parse('{"a": 1, "b": 2}', symbolize_keys: true, acceleration: acceleration)).to eq({ a: 1, b: 2 })
          end

          it "symbolizes nested object keys" do
            expect(FlexJSON.parse('{"outer": {"inner": 1}}', symbolize_keys: true, acceleration: acceleration)).to eq({ outer: { inner: 1 } })
          end

          it "defaults to string keys" do
            expect(FlexJSON.parse('{"a": 1}', acceleration: acceleration)).to eq({ "a" => 1 })
          end
        end

        describe "deep nesting" do
          it "parses deeply nested input without stack overflow (iterative parser, both paths)" do
            deep = ("[" * 1000) + ("]" * 1000)
            result = FlexJSON.parse(deep, acceleration: acceleration)
            expect(result).to be_a(Array)
          end
        end

        describe "duplicate_key" do
          it "last value wins by default" do
            expect(FlexJSON.parse('{"a": 1, "a": 2}', acceleration: acceleration)["a"]).to eq(2)
          end

          it "first value wins with duplicate_key: :first_wins" do
            expect(FlexJSON.parse('{"a": 1, "a": 2}', duplicate_key: :first_wins, acceleration: acceleration)["a"]).to eq(1)
          end

          it "raises with duplicate_key: :raise" do
            expect do
              FlexJSON.parse('{"a": 1, "a": 2}', duplicate_key: :raise, acceleration: acceleration)
            end.to raise_error(FlexJSON::ParseError, /duplicate/i)
          end
        end

        describe "bigdecimal_load (Oj-compatible; default :auto)" do
          it "loads a >16-significant-digit decimal as BigDecimal by default (:auto)" do
            expect(FlexJSON.parse("0.12345678901234567", acceleration: acceleration)).to eql(BigDecimal("0.12345678901234567"))
          end

          it "keeps a 16-significant-digit decimal as Float (:auto)" do
            expect(FlexJSON.parse("0.1234567890123456", acceleration: acceleration)).to eql(0.1234567890123456)
          end

          it "keeps a 20-digit integer as Integer, never BigDecimal (:auto)" do
            expect(FlexJSON.parse("12345678901234567890", acceleration: acceleration)).to eql(12_345_678_901_234_567_890)
          end

          it "forces Float with bigdecimal_load: :float even for high precision" do
            expect(FlexJSON.parse("0.12345678901234567", bigdecimal_load: :float, acceleration: acceleration)).to be_a(Float)
          end

          it "forces BigDecimal for any decimal with bigdecimal_load: :bigdecimal" do
            expect(FlexJSON.parse("3.14", bigdecimal_load: :bigdecimal, acceleration: acceleration)).to eql(BigDecimal("3.14"))
          end

          it "applies in array/member position too" do
            result = FlexJSON.parse("[0.12345678901234567, 1.5]", acceleration: acceleration)
            expect(result[0]).to eql(BigDecimal("0.12345678901234567"))
            expect(result[1]).to eql(1.5)
          end

          it "normalizes a trailing-dot decimal under :bigdecimal" do
            result = FlexJSON.parse("5.", bigdecimal_load: :bigdecimal, acceleration: acceleration)
            expect(result).to be_a(BigDecimal)
            expect(result).to eq(BigDecimal("5"))
          end
        end

        describe "Ryū float fallback corners (guards the single-pass number scan)" do
          # These exercise the paths the Float converter falls back to strtod /
          # rb_cstr_to_dbl for: >17 mantissa digits, the subnormal range, extreme
          # exponents, and -0.0. The single-pass rewrite must extract identical
          # mantissa/exponent parts, so the resulting Float stays bit-identical to
          # Ruby's own String#to_f.

          it "matches String#to_f for a >17-significant-digit float (strtod fallback)" do
            s = "1.2345678901234567890" # 20 sig digits — beyond Ryū's 17-digit fast path
            expect(FlexJSON.parse(s, bigdecimal_load: :float, acceleration: acceleration)).to eql(s.to_f)
          end

          it "matches String#to_f for a subnormal-range float" do
            s = "1e-310" # mantissa_digits + exponent < -307 — subnormal fallback
            expect(FlexJSON.parse(s, acceleration: acceleration)).to eql(s.to_f)
          end

          it "returns Infinity for an extreme positive exponent" do
            expect(FlexJSON.parse("1e2000000", acceleration: acceleration)).to eql(Float::INFINITY)
          end

          it "returns 0.0 for an extreme negative exponent" do
            expect(FlexJSON.parse("1e-2000000", acceleration: acceleration)).to eql(0.0)
          end

          it "preserves negative zero (-0.0, distinct from 0.0)" do
            result = FlexJSON.parse("-0.0", acceleration: acceleration)
            expect(result).to eql(-0.0)
            expect(1.0 / result).to eql(-Float::INFINITY) # sign bit preserved
          end

          it "matches String#to_f for a >17-digit float carrying underscores" do
            s = "1.234_567_890_123_456_789" # underscores + >17 digits — strip then strtod fallback
            expect(FlexJSON.parse(s, bigdecimal_load: :float, acceleration: acceleration)).to eql(s.delete("_").to_f)
          end
        end
      end

      # ============================================================
      # Whitespace semantics (Rails String#blank? / [[:space:]])
      # ============================================================

      describe "whitespace semantics ([[:space:]], same as Rails blank?)" do
        it "treats vertical tab (0x0B) as whitespace between tokens" do
          expect(FlexJSON.parse("[1,\x0B2,\x0B3]", acceleration: acceleration)).to eq([1, 2, 3])
        end

        it "treats form feed (0x0C) as whitespace between tokens" do
          expect(FlexJSON.parse("[1,\x0C2,\x0C3]", acceleration: acceleration)).to eq([1, 2, 3])
        end

        it "treats NBSP (U+00A0) as whitespace between tokens" do
          expect(FlexJSON.parse("[\u00A01\u00A0,\u00A02]", acceleration: acceleration)).to eq([1, 2])
        end

        it "trims NBSP (U+00A0) around a quoteless value" do
          expect(FlexJSON.parse("x:\u00A0value\u00A0", acceleration: acceleration)).to eq({ "x" => "value" })
        end
      end

      # ============================================================
      # Encoding errors (§3.1)
      # ============================================================

      describe "encoding errors" do
        it "raises FlexJSON::EncodingError on bytes invalid for the claimed encoding" do
          input = "\"bad\xFF byte\"".b.force_encoding("UTF-8") # 0xFF is not valid UTF-8
          expect { FlexJSON.parse(input, acceleration: acceleration) }.to raise_error(FlexJSON::EncodingError)
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
          expect(FlexJSON.parse('"2025-01-31"', acceleration: acceleration)).to eq("2025-01-31")
        end
      end
    end
  end
end
