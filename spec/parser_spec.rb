# frozen_string_literal: true

require "smarter_json"
require "stringio"
require "tempfile"
require "json"

RSpec.describe SmarterJSON do
  # Parity harness: each example runs on the C path (acceleration: true) and the
  # pure-Ruby path (acceleration: false). The option is passed straight into the
  # real SmarterJSON.process API — same pattern as smarter_csv's acceleration specs.
  [true, false].each do |acceleration|
    context "acceleration: #{acceleration}" do
      let(:fixtures_dir) { File.expand_path("fixtures", __dir__) }

      # ============================================================
      # Layer 1 — Strict JSON (RFC 8259)
      # ============================================================

      describe "strict JSON (Layer 1)" do
        describe "literals" do
          it "parses true" do
            expect(SmarterJSON.process("true", acceleration: acceleration)).to eq([true])
            expect(SmarterJSON.process_one("true", acceleration: acceleration)).to eq(true)
          end

          it "parses false" do
            expect(SmarterJSON.process("false", acceleration: acceleration)).to eq([false])
            expect(SmarterJSON.process_one("false", acceleration: acceleration)).to eq(false)
          end

          it "parses null as nil" do
            expect(SmarterJSON.process("null", acceleration: acceleration)).to eq([nil])
            expect(SmarterJSON.process_one("null", acceleration: acceleration)).to be_nil
          end
        end

        describe "numbers" do
          it "parses zero" do
            expect(SmarterJSON.process("0", acceleration: acceleration)).to eq([0])
            expect(SmarterJSON.process_one("0", acceleration: acceleration)).to eq(0)
          end

          it "parses positive integer" do
            expect(SmarterJSON.process("1234567890", acceleration: acceleration)).to eq([1_234_567_890])
            expect(SmarterJSON.process_one("1234567890", acceleration: acceleration)).to eq(1_234_567_890)
          end

          it "parses negative integer" do
            expect(SmarterJSON.process("-42", acceleration: acceleration)).to eq([-42])
            expect(SmarterJSON.process_one("-42", acceleration: acceleration)).to eq(-42)
          end

          it "parses float" do
            expect(SmarterJSON.process("-9876.543210", acceleration: acceleration)).to eq([-9876.543210])
            expect(SmarterJSON.process_one("-9876.543210", acceleration: acceleration)).to eq(-9876.543210)
          end

          it "parses scientific notation (lower e, negative exponent)" do
            expect(SmarterJSON.process("0.123456789e-12", acceleration: acceleration)).to eq([0.123456789e-12])
            expect(SmarterJSON.process_one("0.123456789e-12", acceleration: acceleration)).to eq(0.123456789e-12)
          end

          it "parses scientific notation (upper E, explicit +)" do
            expect(SmarterJSON.process("1.234567890E+34", acceleration: acceleration)).to eq([1.234567890E+34])
            expect(SmarterJSON.process_one("1.234567890E+34", acceleration: acceleration)).to eq(1.234567890E+34)
          end

          it "returns Infinity for numeric overflow (tentative §7.2)" do
            expect(SmarterJSON.process("1e500", acceleration: acceleration)).to eq([Float::INFINITY])
            expect(SmarterJSON.process_one("1e500", acceleration: acceleration)).to eq(Float::INFINITY)
          end
        end

        describe "strings" do
          it "parses simple double-quoted string" do
            expect(SmarterJSON.process('"hello"', acceleration: acceleration)).to eq(["hello"])
            expect(SmarterJSON.process_one('"hello"', acceleration: acceleration)).to eq("hello")
          end

          it "parses empty string" do
            expect(SmarterJSON.process('""', acceleration: acceleration)).to eq([""])
            expect(SmarterJSON.process_one('""', acceleration: acceleration)).to eq("")
          end

          it "parses string with escaped quote" do
            expect(SmarterJSON.process('"\""', acceleration: acceleration)).to eq(['"'])
            expect(SmarterJSON.process_one('"\""', acceleration: acceleration)).to eq('"')
          end

          it "parses string with backslash escape" do
            expect(SmarterJSON.process('"\\\\"', acceleration: acceleration)).to eq(["\\"])
            expect(SmarterJSON.process_one('"\\\\"', acceleration: acceleration)).to eq("\\")
          end

          it "parses string with control character escapes" do
            expect(SmarterJSON.process('"\b\f\n\r\t"', acceleration: acceleration)).to eq(["\b\f\n\r\t"])
            expect(SmarterJSON.process_one('"\b\f\n\r\t"', acceleration: acceleration)).to eq("\b\f\n\r\t")
          end

          it "parses string with forward-slash escape" do
            expect(SmarterJSON.process('"\/"', acceleration: acceleration)).to eq(["/"])
            expect(SmarterJSON.process_one('"\/"', acceleration: acceleration)).to eq("/")
          end

          it 'parses BMP \\uXXXX escape' do
            expect(SmarterJSON.process('"A"', acceleration: acceleration)).to eq(["A"])
            expect(SmarterJSON.process_one('"A"', acceleration: acceleration)).to eq("A")
          end

          it 'parses stand-in pair \\uD83D\\uDE00 (😀)' do
            expect(SmarterJSON.process('"😀"', acceleration: acceleration)).to eq(["\u{1F600}"])
            expect(SmarterJSON.process_one('"😀"', acceleration: acceleration)).to eq("\u{1F600}")
          end
        end

        describe "arrays" do
          it "parses empty array" do
            expect(SmarterJSON.process("[]", acceleration: acceleration)).to eq([[]])
            expect(SmarterJSON.process_one("[]", acceleration: acceleration)).to eq([])
          end

          it "parses array of integers" do
            expect(SmarterJSON.process("[1, 2, 3]", acceleration: acceleration)).to eq([[1, 2, 3]])
            expect(SmarterJSON.process_one("[1, 2, 3]", acceleration: acceleration)).to eq([1, 2, 3])
          end

          it "parses array of mixed types" do
            expect(SmarterJSON.process('[1, "two", true, null]', acceleration: acceleration)).to eq([[1, "two", true, nil]])
            expect(SmarterJSON.process_one('[1, "two", true, null]', acceleration: acceleration)).to eq([1, "two", true, nil])
          end

          it "parses nested array" do
            expect(SmarterJSON.process("[[1, 2], [3, 4]]", acceleration: acceleration)).to eq([[[1, 2], [3, 4]]])
            expect(SmarterJSON.process_one("[[1, 2], [3, 4]]", acceleration: acceleration)).to eq([[1, 2], [3, 4]])
          end
        end

        describe "objects" do
          it "parses empty object" do
            expect(SmarterJSON.process("{}", acceleration: acceleration)).to eq([{}])
            expect(SmarterJSON.process_one("{}", acceleration: acceleration)).to eq({})
          end

          it "parses single-key object" do
            expect(SmarterJSON.process('{"a": 1}', acceleration: acceleration)).to eq([{ "a" => 1 }])
            expect(SmarterJSON.process_one('{"a": 1}', acceleration: acceleration)).to eq({ "a" => 1 })
          end

          it "parses multi-key object" do
            expect(SmarterJSON.process('{"a": 1, "b": 2}', acceleration: acceleration)).to eq([{ "a" => 1, "b" => 2 }])
            expect(SmarterJSON.process_one('{"a": 1, "b": 2}', acceleration: acceleration)).to eq({ "a" => 1, "b" => 2 })
          end

          it "parses nested object" do
            expect(SmarterJSON.process('{"outer": {"inner": 42}}', acceleration: acceleration)).to eq([{ "outer" => { "inner" => 42 } }])
            expect(SmarterJSON.process_one('{"outer": {"inner": 42}}', acceleration: acceleration)).to eq({ "outer" => { "inner" => 42 } })
          end
        end

        describe "comprehensive fixture" do
          it "parses json_pass1.json end-to-end" do
            input = File.read(File.join(fixtures_dir, "json_pass1.json"))
            result = SmarterJSON.process_one(input, acceleration: acceleration)
            expect(SmarterJSON.process(input, acceleration: acceleration)).to eq([result])
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
            expect(SmarterJSON.process("// a comment\n42", acceleration: acceleration)).to eq([42])
            expect(SmarterJSON.process_one("// a comment\n42", acceleration: acceleration)).to eq(42)
          end

          it "accepts a line comment between object members" do
            expect(SmarterJSON.process('{"a": 1, // mid-line comment' + "\n" + '"b": 2}', acceleration: acceleration)).to eq([{ "a" => 1, "b" => 2 }])
            expect(SmarterJSON.process_one('{"a": 1, // mid-line comment' + "\n" + '"b": 2}', acceleration: acceleration)).to eq({ "a" => 1, "b" => 2 })
          end
        end

        describe "/* */ block comments" do
          it "accepts a block comment before a value" do
            expect(SmarterJSON.process("/* block comment */ 42", acceleration: acceleration)).to eq([42])
            expect(SmarterJSON.process_one("/* block comment */ 42", acceleration: acceleration)).to eq(42)
          end

          it "accepts a block comment inside an array" do
            expect(SmarterJSON.process("[1, /* mid */ 2, 3]", acceleration: acceleration)).to eq([[1, 2, 3]])
            expect(SmarterJSON.process_one("[1, /* mid */ 2, 3]", acceleration: acceleration)).to eq([1, 2, 3])
          end

          it "accepts a multi-line block comment" do
            expect(SmarterJSON.process("/*\nmulti\nline\n*/ 42", acceleration: acceleration)).to eq([42])
            expect(SmarterJSON.process_one("/*\nmulti\nline\n*/ 42", acceleration: acceleration)).to eq(42)
          end
        end

        describe "trailing comma" do
          it "accepts trailing comma in array" do
            expect(SmarterJSON.process("[1, 2, 3,]", acceleration: acceleration)).to eq([[1, 2, 3]])
            expect(SmarterJSON.process_one("[1, 2, 3,]", acceleration: acceleration)).to eq([1, 2, 3])
          end

          it "accepts trailing comma in object" do
            expect(SmarterJSON.process('{"a": 1, "b": 2,}', acceleration: acceleration)).to eq([{ "a" => 1, "b" => 2 }])
            expect(SmarterJSON.process_one('{"a": 1, "b": 2,}', acceleration: acceleration)).to eq({ "a" => 1, "b" => 2 })
          end
        end

        describe "unquoted keys (ECMAScript identifier names)" do
          it "accepts simple identifier key" do
            expect(SmarterJSON.process("{foo: 1}", acceleration: acceleration)).to eq([{ "foo" => 1 }])
            expect(SmarterJSON.process_one("{foo: 1}", acceleration: acceleration)).to eq({ "foo" => 1 })
          end

          it "accepts identifier with underscore prefix" do
            expect(SmarterJSON.process("{_bar: 2}", acceleration: acceleration)).to eq([{ "_bar" => 2 }])
            expect(SmarterJSON.process_one("{_bar: 2}", acceleration: acceleration)).to eq({ "_bar" => 2 })
          end

          it "accepts identifier with dollar sign" do
            expect(SmarterJSON.process("{$baz: 3}", acceleration: acceleration)).to eq([{ "$baz" => 3 }])
            expect(SmarterJSON.process_one("{$baz: 3}", acceleration: acceleration)).to eq({ "$baz" => 3 })
          end

          it "accepts identifier with digits after first char" do
            expect(SmarterJSON.process("{a1b2: 1}", acceleration: acceleration)).to eq([{ "a1b2" => 1 }])
            expect(SmarterJSON.process_one("{a1b2: 1}", acceleration: acceleration)).to eq({ "a1b2" => 1 })
          end
        end

        describe "single-quoted strings" do
          it "parses single-quoted string value" do
            expect(SmarterJSON.process("{a: 'bar'}", acceleration: acceleration)).to eq([{ "a" => "bar" }])
            expect(SmarterJSON.process_one("{a: 'bar'}", acceleration: acceleration)).to eq({ "a" => "bar" })
          end

          it "parses single-quoted string with escaped single quote" do
            expect(SmarterJSON.process("'it\\'s'", acceleration: acceleration)).to eq(["it's"])
            expect(SmarterJSON.process_one("'it\\'s'", acceleration: acceleration)).to eq("it's")
          end
        end

        describe "hex numbers" do
          it "parses 0xFF as 255" do
            expect(SmarterJSON.process("0xFF", acceleration: acceleration)).to eq([255])
            expect(SmarterJSON.process_one("0xFF", acceleration: acceleration)).to eq(255)
          end

          it "parses negative hex number" do
            expect(SmarterJSON.process("-0x10", acceleration: acceleration)).to eq([-16])
            expect(SmarterJSON.process_one("-0x10", acceleration: acceleration)).to eq(-16)
          end
        end

        describe "leading/trailing decimal points" do
          it "parses .5 as 0.5" do
            expect(SmarterJSON.process(".5", acceleration: acceleration)).to eq([0.5])
            expect(SmarterJSON.process_one(".5", acceleration: acceleration)).to eq(0.5)
          end

          it "parses 5. as 5.0" do
            expect(SmarterJSON.process("5.", acceleration: acceleration)).to eq([5.0])
            expect(SmarterJSON.process_one("5.", acceleration: acceleration)).to eq(5.0)
          end
        end

        describe "Infinity and NaN" do
          it "parses Infinity" do
            expect(SmarterJSON.process("Infinity", acceleration: acceleration)).to eq([Float::INFINITY])
            expect(SmarterJSON.process_one("Infinity", acceleration: acceleration)).to eq(Float::INFINITY)
          end

          it "parses -Infinity" do
            expect(SmarterJSON.process("-Infinity", acceleration: acceleration)).to eq([-Float::INFINITY])
            expect(SmarterJSON.process_one("-Infinity", acceleration: acceleration)).to eq(-Float::INFINITY)
          end

          it "parses NaN" do
            expect(SmarterJSON.process("NaN", acceleration: acceleration).first).to be_a(Float).and(be_nan)
            expect(SmarterJSON.process_one("NaN", acceleration: acceleration)).to be_a(Float).and(be_nan)
          end

          it "parses +Infinity at the top level" do
            expect(SmarterJSON.process("+Infinity", acceleration: acceleration)).to eq([Float::INFINITY])
            expect(SmarterJSON.process_one("+Infinity", acceleration: acceleration)).to eq(Float::INFINITY)
          end

          it "parses NaN and Infinity as array elements" do
            result = SmarterJSON.process_one("[1, NaN, Infinity, -Infinity]", acceleration: acceleration)
            expect(result[0]).to eq(1)
            expect(result[1]).to be_a(Float).and(be_nan)
            expect(result[2]).to eq(Float::INFINITY)
            expect(result[3]).to eq(-Float::INFINITY)
          end

          it "returns real Float objects (Float::INFINITY / Float::NAN), usable as numbers" do
            inf = SmarterJSON.process_one("Infinity", acceleration: acceleration)
            nan = SmarterJSON.process_one("NaN", acceleration: acceleration)
            expect(inf).to be_a(Float)
            expect(inf.infinite?).to eq(1) # +Infinity (Float#infinite? => 1)
            expect(inf + 1).to eq(Float::INFINITY) # arithmetic works
            expect(nan).to be_a(Float)
            expect(nan).to be_nan      # <-- the real check: did SmarterJSON return a true NaN?
            expect(nan).not_to eq(nan) # <-- just re-demonstrates IEEE behavior (NaN != itself), not OUR behavior
          end

          it "classifies recognized literals to their values alongside NaN/Infinity (recognized-literals-win)" do
            result = SmarterJSON.process_one(<<~JSON, acceleration: acceleration)
              {
                happy: True,
                sad: False,
                nothing: None,
                missing: undefined,
                score: Infinity,
                debt: -Infinity,
                ratio: NaN
              }
            JSON
            expect(result["happy"]).to be(true)
            expect(result["sad"]).to be(false)
            expect(result["nothing"]).to be_nil
            expect(result["missing"]).to be_nil
            expect(result["score"]).to eq(Float::INFINITY)
            expect(result["debt"]).to eq(-Float::INFINITY)
            expect(result["ratio"]).to be_a(Float).and(be_nan)
          end
        end

        describe "recognized-literal classification boundaries" do
          # The literal classification (true/True, false/False, null/None/undefined,
          # NaN, Infinity) applies ONLY to unquoted tokens, and matches exactly.

          it "keeps a QUOTED recognized literal as a string (classification is quoteless-only)" do
            expect(SmarterJSON.process_one('{"a": "True"}', acceleration: acceleration)).to eq({ "a" => "True" })
            expect(SmarterJSON.process_one('{"a": "NaN"}', acceleration: acceleration)).to eq({ "a" => "NaN" })
            expect(SmarterJSON.process_one('{"a": "Infinity"}', acceleration: acceleration)).to eq({ "a" => "Infinity" })
            expect(SmarterJSON.process_one('{"a": "None"}', acceleration: acceleration)).to eq({ "a" => "None" })
            expect(SmarterJSON.process_one('{"a": "null"}', acceleration: acceleration)).to eq({ "a" => "null" })
          end

          it "does not recognize wrong-case variants (exact match) — they stay quoteless strings" do
            expect(SmarterJSON.process_one("{a: TRUE}", acceleration: acceleration)).to eq({ "a" => "TRUE" })
            expect(SmarterJSON.process_one("{a: nan}", acceleration: acceleration)).to eq({ "a" => "nan" })
            expect(SmarterJSON.process_one("{a: infinity}", acceleration: acceleration)).to eq({ "a" => "infinity" })
            expect(SmarterJSON.process_one("{a: NONE}", acceleration: acceleration)).to eq({ "a" => "NONE" })
          end
        end

        describe "explicit + sign on numbers" do
          it "parses +5 as 5" do
            expect(SmarterJSON.process("+5", acceleration: acceleration)).to eq([5])
            expect(SmarterJSON.process_one("+5", acceleration: acceleration)).to eq(5)
          end
        end

        describe 'multi-line strings via \\-continuation' do
          it "joins lines via backslash continuation" do
            expect(SmarterJSON.process('"first\
second"', acceleration: acceleration)).to eq(["firstsecond"])
            expect(SmarterJSON.process_one('"first\
second"', acceleration: acceleration)).to eq("firstsecond")
          end
        end
      end

      # ============================================================
      # Layer 3 — HJSON-inspired additions
      # ============================================================

      describe "LLM-generated JSON and annotated output (robustness cases)" do
        it "parses JSON inside markdown code fences (```json ... ```) directly" do
          input = "
```json
{
  \"foo\": 1,
  \"bar\": \"baz\"
}
```
"
          expect(SmarterJSON.process(input, acceleration: acceleration)).to eq([{"foo" => 1, "bar" => "baz"}])
          expect(SmarterJSON.process_one(input, acceleration: acceleration)).to eq({"foo" => 1, "bar" => "baz"})
        end

        it "parses JSON with pervasive LLM-style comments and explanations" do
          input = <<~JSON
            {
              "foo": 123, // main value
              "bar": "baz"  # secondary label
              # This is an explanation line
              "baz": true /* always true */
            }
          JSON
          expect(SmarterJSON.process(input, acceleration: acceleration)).to eq([{"foo"=>123, "bar"=>"baz", "baz"=>true}])
          expect(SmarterJSON.process_one(input, acceleration: acceleration)).to eq({"foo"=>123, "bar"=>"baz", "baz"=>true})
        end

        it "accepts JSON objects/arrays abruptly truncated (returns prefix or raises cleanly)" do
          # Partial object (closed)
          expect(SmarterJSON.process('{"a":1, "b":2}', acceleration: acceleration)).to eq([{"a"=>1, "b"=>2}])
          expect(SmarterJSON.process_one('{"a":1, "b":2}', acceleration: acceleration)).to eq({"a"=>1, "b"=>2})
          # Partial object (truncated after key)
          expect { SmarterJSON.process('{"a":1, ', acceleration: acceleration) }
            .to raise_error(SmarterJSON::ParseError, /end of input|unterminated/i)
          expect { SmarterJSON.process_one('{"a":1, ', acceleration: acceleration) }
            .to raise_error(SmarterJSON::ParseError, /end of input|unterminated/i)
          # Partial array (closed)
          expect(SmarterJSON.process('[1, 2, 3]', acceleration: acceleration)).to eq([[1, 2, 3]])
          expect(SmarterJSON.process_one('[1, 2, 3]', acceleration: acceleration)).to eq([1, 2, 3])
          # Truncated array (no closing ]): warns or raises
          expect { SmarterJSON.process('[1, 2, ', acceleration: acceleration) }
            .to raise_error(SmarterJSON::ParseError, /end of input|unterminated/i)
          expect { SmarterJSON.process_one('[1, 2, ', acceleration: acceleration) }
            .to raise_error(SmarterJSON::ParseError, /end of input|unterminated/i)
        end

        it "tolerates duplicate keys, comments after values, python/JS literals in LLM output" do
          input = <<~JSON
            {
              foo: undefined, // should be null
              bar: True, # becomes true
              baz: False /* becomes false */
              val: None # becomes nil/null
              extra: NaN // becomes Float::NAN
              note: Infinity /* Float::INFINITY */
              trace: "Done" // ok
            }
          JSON
          result = SmarterJSON.process_one(input, acceleration: acceleration)
          expect(result).to include("foo"=>nil, "bar"=>true, "baz"=>false, "val"=>nil)
          expect(result["extra"]).to be_a(Float).and satisfy(&:nan?)
          expect(result["note"]).to eq(Float::INFINITY)
        end
      end

      describe "HJSON-inspired additions (Layer 3)" do
        describe "# line comments" do
          it "accepts # comment before a value" do
            expect(SmarterJSON.process("# comment\n42", acceleration: acceleration)).to eq([42])
            expect(SmarterJSON.process_one("# comment\n42", acceleration: acceleration)).to eq(42)
          end

          it "accepts # comment between object members" do
            expect(SmarterJSON.process("{a: 1 # comment\nb: 2}", acceleration: acceleration)).to eq([{ "a" => 1, "b" => 2 }])
            expect(SmarterJSON.process_one("{a: 1 # comment\nb: 2}", acceleration: acceleration)).to eq({ "a" => 1, "b" => 2 })
          end
        end

        describe "comment-marker whitespace rule" do
          it "preserves URL with // (no whitespace before //)" do
            expect(SmarterJSON.process("url: http://example.com", acceleration: acceleration)).to eq([{ "url" => "http://example.com" }])
            expect(SmarterJSON.process_one("url: http://example.com", acceleration: acceleration)).to eq({ "url" => "http://example.com" })
          end

          it "preserves identifier with mid-token #" do
            expect(SmarterJSON.process("method: Klass#meth", acceleration: acceleration)).to eq([{ "method" => "Klass#meth" }])
            expect(SmarterJSON.process_one("method: Klass#meth", acceleration: acceleration)).to eq({ "method" => "Klass#meth" })
          end

          it "preserves email with mid-token #" do
            expect(SmarterJSON.process("email: foo@bar#example.com", acceleration: acceleration)).to eq([{ "email" => "foo@bar#example.com" }])
            expect(SmarterJSON.process_one("email: foo@bar#example.com", acceleration: acceleration)).to eq({ "email" => "foo@bar#example.com" })
          end

          it "treats # after whitespace as a comment" do
            expect(SmarterJSON.process("name: Tilo # this is a comment", acceleration: acceleration)).to eq([{ "name" => "Tilo" }])
            expect(SmarterJSON.process_one("name: Tilo # this is a comment", acceleration: acceleration)).to eq({ "name" => "Tilo" })
          end

          it "treats // after whitespace as a comment" do
            expect(SmarterJSON.process("name: Tilo // this is a comment", acceleration: acceleration)).to eq([{ "name" => "Tilo" }])
            expect(SmarterJSON.process_one("name: Tilo // this is a comment", acceleration: acceleration)).to eq({ "name" => "Tilo" })
          end

          it "treats # at start of line as a comment" do
            expect(SmarterJSON.process("# top-level comment\nname: Tilo", acceleration: acceleration)).to eq([{ "name" => "Tilo" }])
            expect(SmarterJSON.process_one("# top-level comment\nname: Tilo", acceleration: acceleration)).to eq({ "name" => "Tilo" })
          end

          it "preserves URL with full URL + trailing comment" do
            expect(SmarterJSON.process("url: http://example.com/ # see this site", acceleration: acceleration)).to eq([{ "url" => "http://example.com/" }])
            expect(SmarterJSON.process_one("url: http://example.com/ # see this site", acceleration: acceleration)).to eq({ "url" => "http://example.com/" })
          end

          it "keeps /* as part of the token when not preceded by whitespace" do
            expect(SmarterJSON.process("path: a/*b/c", acceleration: acceleration)).to eq([{ "path" => "a/*b/c" }])
            expect(SmarterJSON.process_one("path: a/*b/c", acceleration: acceleration)).to eq({ "path" => "a/*b/c" })
          end

          it "treats /* after whitespace as a block comment" do
            expect(SmarterJSON.process("name: Tilo /* a comment */", acceleration: acceleration)).to eq([{ "name" => "Tilo" }])
            expect(SmarterJSON.process_one("name: Tilo /* a comment */", acceleration: acceleration)).to eq({ "name" => "Tilo" })
          end
        end

        describe "triple-quoted multi-line strings" do
          it "parses single-line triple-quoted string" do
            expect(SmarterJSON.process("'''hello'''", acceleration: acceleration)).to eq(["hello"])
            expect(SmarterJSON.process_one("'''hello'''", acceleration: acceleration)).to eq("hello")
          end

          it "parses an empty triple-quoted string" do
            expect(SmarterJSON.process("''''''", acceleration: acceleration)).to eq([""])
            expect(SmarterJSON.process_one("''''''", acceleration: acceleration)).to eq("")
          end

          it "parses multi-line content at column 0 (no stripping)" do
            expect(SmarterJSON.process("'''first\nsecond'''", acceleration: acceleration)).to eq(["first\nsecond"])
            expect(SmarterJSON.process_one("'''first\nsecond'''", acceleration: acceleration)).to eq("first\nsecond")
          end

          it "does not process escapes — backslashes and quotes are literal" do
            expect(SmarterJSON.process("'''a \\ b \"q\" c'''", acceleration: acceleration)).to eq(['a \\ b "q" c'])
            expect(SmarterJSON.process_one("'''a \\ b \"q\" c'''", acceleration: acceleration)).to eq('a \\ b "q" c')
          end

          describe "indentation stripping (based on opening ''' marker column)" do
            it "marker alone on its line: strips structural indent, preserves surplus" do
              # opening ''' at column 4; content at 8/10/8 → keeps 4/6/4
              input = "    '''\n        first line\n          indented line\n        last line\n    '''"
              expect(SmarterJSON.process(input, acceleration: acceleration)).to eq(["    first line\n      indented line\n    last line"])
              expect(SmarterJSON.process_one(input, acceleration: acceleration)).to eq("    first line\n      indented line\n    last line")
            end

            it "strips exactly to the marker column when content aligns with it" do
              # opening ''' at column 4; content also at 4 → fully stripped
              input = "    '''\n    first line\n      indented line\n    last line\n    '''"
              expect(SmarterJSON.process(input, acceleration: acceleration)).to eq(["first line\n  indented line\nlast line"])
              expect(SmarterJSON.process_one(input, acceleration: acceleration)).to eq("first line\n  indented line\nlast line")
            end

            it "text on the opening line is taken verbatim, later lines stripped" do
              input = "    '''first line\n      indented line\n    last line'''"
              expect(SmarterJSON.process(input, acceleration: acceleration)).to eq(["first line\n  indented line\nlast line"])
              expect(SmarterJSON.process_one(input, acceleration: acceleration)).to eq("first line\n  indented line\nlast line")
            end

            it "preserves a genuine blank line and the resulting trailing newline" do
              input = "    '''\n    first line\n    last line\n\n    '''"
              expect(SmarterJSON.process(input, acceleration: acceleration)).to eq(["first line\nlast line\n"])
              expect(SmarterJSON.process_one(input, acceleration: acceleration)).to eq("first line\nlast line\n")
            end

            it "never strips into the text when a line has less indent than the marker" do
              # opening ''' at column 4; a content line has only 2 leading spaces
              input = "    '''\n  short\n        deep\n    '''"
              expect(SmarterJSON.process(input, acceleration: acceleration)).to eq(["short\n    deep"])
              expect(SmarterJSON.process_one(input, acceleration: acceleration)).to eq("short\n    deep")
            end

            it 'normalizes CRLF line endings to \\n inside the content' do
              input = "    '''\r\n    a\r\n    b\r\n    '''"
              expect(SmarterJSON.process(input, acceleration: acceleration)).to eq(["a\nb"])
              expect(SmarterJSON.process_one(input, acceleration: acceleration)).to eq("a\nb")
            end

            it 'normalizes bare CR line endings to \\n inside the content' do
              input = "    '''\r    a\r    b\r    '''"
              expect(SmarterJSON.process(input, acceleration: acceleration)).to eq(["a\nb"])
              expect(SmarterJSON.process_one(input, acceleration: acceleration)).to eq("a\nb")
            end
          end

          it "raises on an unterminated triple-quoted string" do
            expect { SmarterJSON.process("'''never closed", acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError, /unterminated/)
            expect { SmarterJSON.process_one("'''never closed", acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError, /unterminated/)
          end
        end

        describe "quoteless single-line strings" do
          it "parses simple quoteless string value" do
            expect(SmarterJSON.process("name: Tilo", acceleration: acceleration)).to eq([{ "name" => "Tilo" }])
            expect(SmarterJSON.process_one("name: Tilo", acceleration: acceleration)).to eq({ "name" => "Tilo" })
          end

          it "trims surrounding whitespace from quoteless string" do
            expect(SmarterJSON.process("text:    hello world   ", acceleration: acceleration)).to eq([{ "text" => "hello world" }])
            expect(SmarterJSON.process_one("text:    hello world   ", acceleration: acceleration)).to eq({ "text" => "hello world" })
          end

          it "keeps a #, //, or /* that is NOT preceded by whitespace as part of the value" do
            # The quoteless fast path scans to a terminator; a comment marker only ends the
            # run when preceded by whitespace, so glued-on markers stay in the value.
            expect(SmarterJSON.process("{k: ab#cd}", acceleration: acceleration)).to eq([{ "k" => "ab#cd" }])
            expect(SmarterJSON.process("{k: a//b}", acceleration: acceleration)).to eq([{ "k" => "a//b" }])
            # ...but WITH preceding whitespace it does start a comment (value is just "ab"):
            expect(SmarterJSON.process("{k: ab #cd\n}", acceleration: acceleration)).to eq([{ "k" => "ab" }])
          end

          it "trims trailing multibyte whitespace (NBSP / U+3000) but keeps it interior" do
            # NBSP (U+00A0) and ideographic space (U+3000) are Unicode whitespace: trailing
            # ones are trimmed from a quoteless value, interior ones are part of the value.
            expect(SmarterJSON.process("a: hello 　", acceleration: acceleration)).to eq([{ "a" => "hello" }])
            expect(SmarterJSON.process("a: hello world　", acceleration: acceleration)).to eq([{ "a" => "hello world" }])
            expect(SmarterJSON.process("[ v　 , w  ]", acceleration: acceleration)).to eq([%w[v w]])
          end

          it "treats backslashes inside quoteless strings as literal (no escape processing)" do
            expect(SmarterJSON.process('text: a \ is just a \\', acceleration: acceleration).first.values.first).to eq('a \\ is just a \\')
            expect(SmarterJSON.process_one('text: a \ is just a \\', acceleration: acceleration).values.first).to eq('a \\ is just a \\')
          end

          it 'treats \\n inside a quoteless string as two literal characters' do
            # Ruby single-quoted source: the input is the 4 chars  a \ n b
            expect(SmarterJSON.process('x: a\nb', acceleration: acceleration)).to eq([{ "x" => 'a\nb' }])
            expect(SmarterJSON.process_one('x: a\nb', acceleration: acceleration)).to eq({ "x" => 'a\nb' })
          end

          it "terminates a quoteless value at }" do
            expect(SmarterJSON.process("{a: hello world}", acceleration: acceleration)).to eq([{ "a" => "hello world" }])
            expect(SmarterJSON.process_one("{a: hello world}", acceleration: acceleration)).to eq({ "a" => "hello world" })
          end

          it "terminates a quoteless value at ]" do
            expect(SmarterJSON.process("[hello world]", acceleration: acceleration)).to eq([["hello world"]])
            expect(SmarterJSON.process_one("[hello world]", acceleration: acceleration)).to eq(["hello world"])
          end

          it "treats a malformed number as a quoteless string (1.2.3)" do
            expect(SmarterJSON.process("{version: 1.2.3}", acceleration: acceleration)).to eq([{ "version" => "1.2.3" }])
            expect(SmarterJSON.process_one("{version: 1.2.3}", acceleration: acceleration)).to eq({ "version" => "1.2.3" })
          end

          it "treats a digit-led non-number token as a quoteless string (12abc)" do
            expect(SmarterJSON.process("{v: 12abc}", acceleration: acceleration)).to eq([{ "v" => "12abc" }])
            expect(SmarterJSON.process_one("{v: 12abc}", acceleration: acceleration)).to eq({ "v" => "12abc" })
          end
        end

        describe "bare leading-zero integers fall through to quoteless strings" do
          it 'parses 0080 as the string "0080"' do
            expect(SmarterJSON.process("port: 0080", acceleration: acceleration)).to eq([{ "port" => "0080" }])
            expect(SmarterJSON.process_one("port: 0080", acceleration: acceleration)).to eq({ "port" => "0080" })
          end

          it 'parses 00 as the string "00"' do
            expect(SmarterJSON.process("n: 00", acceleration: acceleration)).to eq([{ "n" => "00" }])
            expect(SmarterJSON.process_one("n: 00", acceleration: acceleration)).to eq({ "n" => "00" })
          end

          it 'parses 02 as the string "02"' do
            expect(SmarterJSON.process("n: 02", acceleration: acceleration)).to eq([{ "n" => "02" }])
            expect(SmarterJSON.process_one("n: 02", acceleration: acceleration)).to eq({ "n" => "02" })
          end
        end

        describe "leading-zero numbers with sign / dot / exponent parse as numbers" do
          # A leading-zero token carries numeric intent — and parses as a NUMBER — when it
          # has a sign, a decimal point, or an exponent. A BARE leading-zero integer stays a
          # string (block above) so zip / account / check numbers keep their zeros; IDs never
          # carry a sign, dot, or exponent.

          it "parses a signed leading-zero integer as a number" do
            expect(SmarterJSON.process_one("{a: +007, b: -007}", acceleration: acceleration)).to eq({ "a" => 7, "b" => -7 })
          end

          it "parses a leading-zero decimal as a number" do
            expect(SmarterJSON.process_one("{a: 00.00, b: -000023.5, c: 00001.5}", acceleration: acceleration)).to eq({ "a" => 0.0, "b" => -23.5, "c" => 1.5 })
          end

          it "parses leading-zero scientific notation as a number" do
            expect(SmarterJSON.process_one("{a: 00e5, b: 007e2, c: +00e5}", acceleration: acceleration)).to eq({ "a" => 0.0, "b" => 700.0, "c" => 0.0 })
          end

          it "applies in arrays and at the top level too" do
            expect(SmarterJSON.process_one("[000001, -000023.5, 007e2]", acceleration: acceleration)).to eq(["000001", -23.5, 700.0])
            expect(SmarterJSON.process_one("-000023.5", acceleration: acceleration)).to eq(-23.5)
            expect(SmarterJSON.process_one("+007", acceleration: acceleration)).to eq(7)
          end

          it "a bare leading-zero integer still has no top-level form (raises)" do
            expect { SmarterJSON.process_one("000001", acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
          end

          it "leaves single-zero and non-leading-zero numbers unchanged" do
            expect(SmarterJSON.process_one("{a: 0, b: 0.5, c: -0, d: 1.5e3}", acceleration: acceleration)).to eq({ "a" => 0, "b" => 0.5, "c" => 0, "d" => 1500.0 })
          end
        end

        describe "implicit root object" do
          it "parses key: value at top level without outer {}" do
            expect(SmarterJSON.process("host: localhost\nport: 5432", acceleration: acceleration)).to eq([{ "host" => "localhost", "port" => 5432 }])
            expect(SmarterJSON.process_one("host: localhost\nport: 5432", acceleration: acceleration)).to eq({ "host" => "localhost", "port" => 5432 })
          end

          it "parses nested object under implicit root" do
            input = "database:\n{\n  host: 127.0.0.1\n  port: 555\n}"
            expect(SmarterJSON.process(input, acceleration: acceleration)).to eq([{ "database" => { "host" => "127.0.0.1", "port" => 555 } }])
            expect(SmarterJSON.process_one(input, acceleration: acceleration)).to eq({ "database" => { "host" => "127.0.0.1", "port" => 555 } })
          end
        end

        describe "newline as separator" do
          it "separates object members on newlines without commas" do
            expect(SmarterJSON.process("{\n  a: 1\n  b: 2\n}", acceleration: acceleration)).to eq([{ "a" => 1, "b" => 2 }])
            expect(SmarterJSON.process_one("{\n  a: 1\n  b: 2\n}", acceleration: acceleration)).to eq({ "a" => 1, "b" => 2 })
          end

          it "separates array elements on newlines without commas" do
            expect(SmarterJSON.process("[\n  1\n  2\n  3\n]", acceleration: acceleration)).to eq([[1, 2, 3]])
            expect(SmarterJSON.process_one("[\n  1\n  2\n  3\n]", acceleration: acceleration)).to eq([1, 2, 3])
          end
        end

        describe "broader unquoted keys" do
          it "accepts {_var3: 1}" do
            expect(SmarterJSON.process("{_var3: 1}", acceleration: acceleration)).to eq([{ "_var3" => 1 }])
            expect(SmarterJSON.process_one("{_var3: 1}", acceleration: acceleration)).to eq({ "_var3" => 1 })
          end

          it "accepts {my-key: 1}" do
            expect(SmarterJSON.process("{my-key: 1}", acceleration: acceleration)).to eq([{ "my-key" => 1 }])
            expect(SmarterJSON.process_one("{my-key: 1}", acceleration: acceleration)).to eq({ "my-key" => 1 })
          end

          it "accepts {user-id-42: 1}" do
            expect(SmarterJSON.process("{user-id-42: 1}", acceleration: acceleration)).to eq([{ "user-id-42" => 1 }])
            expect(SmarterJSON.process_one("{user-id-42: 1}", acceleration: acceleration)).to eq({ "user-id-42" => 1 })
          end

          it "rejects key starting with a digit (123-foo)" do
            expect { SmarterJSON.process("{123-foo: 1}", acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
            expect { SmarterJSON.process_one("{123-foo: 1}", acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
          end
        end

        describe "recognized literals win in quoteless context" do
          it "parses [1, 2, 3] as three integers" do
            expect(SmarterJSON.process("[1, 2, 3]", acceleration: acceleration)).to eq([[1, 2, 3]])
            expect(SmarterJSON.process_one("[1, 2, 3]", acceleration: acceleration)).to eq([1, 2, 3])
          end

          it 'parses [1 2 3] as the single string "1 2 3"' do
            expect(SmarterJSON.process("[1 2 3]", acceleration: acceleration)).to eq([["1 2 3"]])
            expect(SmarterJSON.process_one("[1 2 3]", acceleration: acceleration)).to eq(["1 2 3"])
          end

          # Boundary cases for the container-number fast path: a number commits
          # only when it abuts a value terminator; anything else falls back to the
          # quoteless scanner, which must still produce the identical result.
          it "commits numbers that abut a delimiter (comma/bracket/brace/newline)" do
            expect(SmarterJSON.process("[1,2,3]", acceleration: acceleration)).to eq([[1, 2, 3]])
            expect(SmarterJSON.process_one("[1,2,3]", acceleration: acceleration)).to eq([1, 2, 3])
            expect(SmarterJSON.process('{"a":1,"b":2.5}', acceleration: acceleration)).to eq([{ "a" => 1, "b" => 2.5 }])
            expect(SmarterJSON.process_one('{"a":1,"b":2.5}', acceleration: acceleration)).to eq("a" => 1, "b" => 2.5)
            expect(SmarterJSON.process("[1.5e3,-7]", acceleration: acceleration)).to eq([[1500.0, -7]])
            expect(SmarterJSON.process_one("[1.5e3,-7]", acceleration: acceleration)).to eq([1500.0, -7])
            expect(SmarterJSON.process("[\n1\n,\n2\n]", acceleration: acceleration)).to eq([[1, 2]])
            expect(SmarterJSON.process_one("[\n1\n,\n2\n]", acceleration: acceleration)).to eq([1, 2])
          end

          it "still parses numbers correctly when whitespace separates them from the delimiter" do
            expect(SmarterJSON.process("[1 , 2]", acceleration: acceleration)).to eq([[1, 2]])
            expect(SmarterJSON.process_one("[1 , 2]", acceleration: acceleration)).to eq([1, 2])
            expect(SmarterJSON.process("[3 ]", acceleration: acceleration)).to eq([[3]])
            expect(SmarterJSON.process_one("[3 ]", acceleration: acceleration)).to eq([3])
            expect(SmarterJSON.process('{"a": 1 }', acceleration: acceleration)).to eq([{ "a" => 1 }])
            expect(SmarterJSON.process_one('{"a": 1 }', acceleration: acceleration)).to eq("a" => 1)
          end

          it "falls back to string/hex/Infinity for digit-led non-plain-numbers in containers" do
            expect(SmarterJSON.process("[0xFF]", acceleration: acceleration)).to eq([[255]])
            expect(SmarterJSON.process_one("[0xFF]", acceleration: acceleration)).to eq([255])
            expect(SmarterJSON.process("[-Infinity, 12]", acceleration: acceleration)).to eq([[-Float::INFINITY, 12]])
            expect(SmarterJSON.process_one("[-Infinity, 12]", acceleration: acceleration)).to eq([-Float::INFINITY, 12])
            expect(SmarterJSON.process("[1.2.3]", acceleration: acceleration)).to eq([["1.2.3"]])
            expect(SmarterJSON.process_one("[1.2.3]", acceleration: acceleration)).to eq(["1.2.3"])
            expect(SmarterJSON.process("[1_000, 2_000]", acceleration: acceleration)).to eq([[1000, 2000]])
            expect(SmarterJSON.process_one("[1_000, 2_000]", acceleration: acceleration)).to eq([1000, 2000])
          end

          it "parses [red green blue] as a single-element array with one string" do
            expect(SmarterJSON.process("[red green blue]", acceleration: acceleration)).to eq([["red green blue"]])
            expect(SmarterJSON.process_one("[red green blue]", acceleration: acceleration)).to eq(["red green blue"])
          end

          it "parses [red, green, blue] as three strings" do
            expect(SmarterJSON.process("[red, green, blue]", acceleration: acceleration)).to eq([%w[red green blue]])
            expect(SmarterJSON.process_one("[red, green, blue]", acceleration: acceleration)).to eq(%w[red green blue])
          end

          it "parses [true, false, null] as three literals" do
            expect(SmarterJSON.process("[true, false, null]", acceleration: acceleration)).to eq([[true, false, nil]])
            expect(SmarterJSON.process_one("[true, false, null]", acceleration: acceleration)).to eq([true, false, nil])
          end

          it 'parses [true false] as the string "true false"' do
            expect(SmarterJSON.process("[true false]", acceleration: acceleration)).to eq([["true false"]])
            expect(SmarterJSON.process_one("[true false]", acceleration: acceleration)).to eq(["true false"])
          end
        end
      end

      # ============================================================
      # Layer 4 — smarter_json-specific features
      # ============================================================

      describe "smarter_json features (Layer 4)" do
        describe "UTF-8 BOM" do
          it "strips UTF-8 BOM at start of input" do
            input = "\xEF\xBB\xBF{\"a\":1}".b.force_encoding("UTF-8")
            expect(SmarterJSON.process(input, acceleration: acceleration)).to eq([{ "a" => 1 }])
            expect(SmarterJSON.process_one(input, acceleration: acceleration)).to eq({ "a" => 1 })
          end
        end

        describe "smart / curly quotes" do
          # Quote codepoints used in the inputs below, written as \u escapes because the
          # glyphs are visually near-identical to straight quotes (and this file's save
          # hook rewrites any literal glyph back to its \u escape \u2014 so the Unicode NAME,
          # not a pasted glyph, is the reliable identifier):
          #   \u201C  LEFT  DOUBLE QUOTATION MARK   (open curly double)
          #   \u201D  RIGHT DOUBLE QUOTATION MARK   (close curly double)
          #   \u2018  LEFT  SINGLE QUOTATION MARK   (open curly single)
          #   \u2019  RIGHT SINGLE QUOTATION MARK   (close curly single, also the typographic apostrophe)
          #   \u00EF  LATIN SMALL LETTER I WITH DIAERESIS   (the i in the "naive" key)
          it "accepts curly double quotes as regular double quotes" do
            input = "{\"a\": \u201Chello\u201D}"
            expect(SmarterJSON.process(input, acceleration: acceleration)).to eq([{ "a" => "hello" }])
            expect(SmarterJSON.process_one(input, acceleration: acceleration)).to eq({ "a" => "hello" })
          end

          it "accepts curly single quotes as regular single quotes" do
            # U+2018 LEFT SINGLE QUOTATION MARK, U+2019 RIGHT SINGLE QUOTATION MARK
            input = "{a: \u2018hello\u2019}"
            expect(SmarterJSON.process(input, acceleration: acceleration)).to eq([{ "a" => "hello" }])
            expect(SmarterJSON.process_one(input, acceleration: acceleration)).to eq({ "a" => "hello" })
          end

          it "keeps curly quotes that appear INSIDE a straight-quoted string as content" do
            # {"quote": "Hello \u201cworld\u201d"} \u2014 the curly quotes (U+201C/U+201D) sit inside a
            # straight double-quoted value, so they are literal content, not delimiters.
            # Same principle as a col_sep inside a quoted CSV field in SmarterCSV: once a
            # string is open, only its own closer (here the straight ") ends it.
            input    = "{\"quote\": \"Hello \u201cworld\u201d\"}"
            expected = { "quote" => "Hello \u201cworld\u201d" }
            expect(SmarterJSON.process(input, acceleration: acceleration)).to eq([expected])
            expect(SmarterJSON.process_one(input, acceleration: acceleration)).to eq(expected)
          end

          # The word-processor paste curls the KEYS too, not just the values \u2014 these
          # are RED until smart quotes are accepted in key position (Ruby + C).
          describe "smart-quoted keys" do
            it "accepts a smart double-quoted key" do
              input = "{\u201cname\u201d: \"Tilo\"}"
              expect(SmarterJSON.process_one(input, acceleration: acceleration)).to eq({ "name" => "Tilo" })
            end

            it "accepts a smart single-quoted key" do
              input = "{\u2018name\u2019: \"Tilo\"}"
              expect(SmarterJSON.process_one(input, acceleration: acceleration)).to eq({ "name" => "Tilo" })
            end

            it "accepts smart quotes on BOTH key and value" do
              input = "{\u201cname\u201d: \u201cTilo\u201d}"
              expect(SmarterJSON.process_one(input, acceleration: acceleration)).to eq({ "name" => "Tilo" })
            end

            it "accepts a smart double key with a smart single value (mixed styles)" do
              input = "{\u201cname\u201d: \u2018Tilo\u2019}"
              expect(SmarterJSON.process_one(input, acceleration: acceleration)).to eq({ "name" => "Tilo" })
            end

            it "accepts multiple smart-quoted keys in one object" do
              input = "{\u201ca\u201d: 1, \u201cb\u201d: 2}"
              expect(SmarterJSON.process_one(input, acceleration: acceleration)).to eq({ "a" => 1, "b" => 2 })
            end

            it "accepts a smart-quoted key in a nested object" do
              input = "{\"outer\": {\u201cinner\u201d: 1}}"
              expect(SmarterJSON.process_one(input, acceleration: acceleration)).to eq({ "outer" => { "inner" => 1 } })
            end

            it "accepts a smart-quoted key containing spaces and multibyte characters" do
              input = "{\u201cna\u00efve key\u201d: 1}"
              expect(SmarterJSON.process_one(input, acceleration: acceleration)).to eq({ "na\u00efve key" => 1 })
            end

            it "is lenient about smart-quote direction on a key" do
              # opens with the RIGHT curly (U+201D), closes with the LEFT (U+201C)
              input = "{\u201dname\u201c: 1}"
              expect(SmarterJSON.process_one(input, acceleration: acceleration)).to eq({ "name" => 1 })
            end

            it "symbolizes a smart-quoted key when symbolize_keys: true" do
              input = "{\u201cname\u201d: 1}"
              expect(SmarterJSON.process_one(input, symbolize_keys: true, acceleration: acceleration)).to eq({ name: 1 })
            end

            it "accepts an empty smart-quoted key" do
              input = "{\u201c\u201d: 1}"
              expect(SmarterJSON.process_one(input, acceleration: acceleration)).to eq({ "" => 1 })
            end

            it "handles a smart-quoted key AND curly content inside a straight-quoted value" do
              input    = "{\u201cquote\u201d: \"Hello \u201cworld\u201d\"}"
              expected = { "quote" => "Hello \u201cworld\u201d" }
              expect(SmarterJSON.process_one(input, acceleration: acceleration)).to eq(expected)
            end

            it "raises on an unterminated smart-quoted key" do
              expect { SmarterJSON.process_one("{\u201cname: 1}", acceleration: acceleration) }
                .to raise_error(SmarterJSON::ParseError)
            end
          end

          # Smart quotes must behave identically in value position \u2014 these mirror the key
          # tests above, since both keys and values route through the same parse_smart_string.
          describe "smart-quoted values (parity with keys)" do
            it "accepts a smart-quoted value with spaces and multibyte characters" do
              input = "{\"k\": \u201cna\u00efve value\u201d}"
              expect(SmarterJSON.process_one(input, acceleration: acceleration)).to eq({ "k" => "na\u00efve value" })
            end

            it "is lenient about smart-quote direction on a value" do
              input = "{\"k\": \u201dhi\u201c}" # opens U+201D, closes U+201C
              expect(SmarterJSON.process_one(input, acceleration: acceleration)).to eq({ "k" => "hi" })
            end

            it "accepts an empty smart-quoted value" do
              input = "{\"k\": \u201c\u201d}"
              expect(SmarterJSON.process_one(input, acceleration: acceleration)).to eq({ "k" => "" })
            end

            it "accepts a smart single-quoted value" do
              input = "{\"k\": \u2018hi\u2019}"
              expect(SmarterJSON.process_one(input, acceleration: acceleration)).to eq({ "k" => "hi" })
            end
          end

          it "does not support triple-quoted keys (by design \u2014 a multi-line key has no use case)" do
            expect { SmarterJSON.process_one("{'''k''': 1}", acceleration: acceleration) }
              .to raise_error(SmarterJSON::ParseError)
          end

          # Regression guards: a smart quote that appears INSIDE an already-open string
          # is content, not a delimiter (the SmarterCSV "separator inside a quoted field"
          # principle). These are GREEN today and must stay green when keys change.
          describe "smart quotes stay content inside an already-open string" do
            it "keeps a smart apostrophe inside a straight-quoted string" do
              input = "{\"msg\": \"I don\u2019t know\"}"
              expect(SmarterJSON.process_one(input, acceleration: acceleration)).to eq({ "msg" => "I don\u2019t know" })
            end

            it "keeps a smart apostrophe inside a smart-quoted string" do
              input = "{\"msg\": \u201cI don\u2019t know\u201d}"
              expect(SmarterJSON.process_one(input, acceleration: acceleration)).to eq({ "msg" => "I don\u2019t know" })
            end

            it "keeps straight double quotes inside a smart-quoted string" do
              input = "{\"msg\": \u201cHe said \"hi\" loudly\u201d}"
              expect(SmarterJSON.process_one(input, acceleration: acceleration)).to eq({ "msg" => "He said \"hi\" loudly" })
            end
          end
        end

        describe "Null / NULL (SQL / R / PHP / YAML null)" do
          # Null and NULL join null / None / undefined as recognized spellings of nil
          # (SQL / R / PHP var_export / YAML / DB-derived input). TRUE/FALSE are intentionally
          # NOT added — uppercase booleans have far thinner precedent (see CHANGELOG/discussion).

          it "parses Null as nil (top level)" do
            expect(SmarterJSON.process("Null", acceleration: acceleration)).to eq([nil])
            expect(SmarterJSON.process_one("Null", acceleration: acceleration)).to be_nil
          end

          it "parses NULL as nil (top level)" do
            expect(SmarterJSON.process("NULL", acceleration: acceleration)).to eq([nil])
            expect(SmarterJSON.process_one("NULL", acceleration: acceleration)).to be_nil
          end

          it "recognizes Null / NULL as object value and array element" do
            expect(SmarterJSON.process_one("{a: Null, b: NULL}", acceleration: acceleration)).to eq({ "a" => nil, "b" => nil })
            expect(SmarterJSON.process_one("[Null, NULL]", acceleration: acceleration)).to eq([nil, nil])
          end

          it "recognizes Null / NULL surrounded by whitespace" do
            expect(SmarterJSON.process_one("{ a:   Null   , b:  NULL  }", acceleration: acceleration)).to eq({ "a" => nil, "b" => nil })
          end

          it "keeps a QUOTED Null / NULL as a string (classification is quoteless-only)" do
            expect(SmarterJSON.process_one('{"a": "Null"}', acceleration: acceleration)).to eq({ "a" => "Null" })
            expect(SmarterJSON.process_one('{"a": "NULL"}', acceleration: acceleration)).to eq({ "a" => "NULL" })
          end

          it "does NOT recognize Null / NULL embedded in a larger token (stays a string)" do
            expect(SmarterJSON.process_one("{a: NULL Island}", acceleration: acceleration)).to eq({ "a" => "NULL Island" })
            expect(SmarterJSON.process_one("{a: Null and void}", acceleration: acceleration)).to eq({ "a" => "Null and void" })
            expect(SmarterJSON.process_one("{a: Nullable}", acceleration: acceleration)).to eq({ "a" => "Nullable" })
          end

          it "leaves None / null / undefined unchanged (still nil)" do
            expect(SmarterJSON.process_one("{a: None, b: null, c: undefined}", acceleration: acceleration)).to eq({ "a" => nil, "b" => nil, "c" => nil })
          end
        end

        describe "Python literals" do
          it "parses True as true" do
            expect(SmarterJSON.process("True", acceleration: acceleration)).to eq([true])
            expect(SmarterJSON.process_one("True", acceleration: acceleration)).to eq(true)
          end

          it "parses False as false" do
            expect(SmarterJSON.process("False", acceleration: acceleration)).to eq([false])
            expect(SmarterJSON.process_one("False", acceleration: acceleration)).to eq(false)
          end

          it "parses None as nil" do
            expect(SmarterJSON.process("None", acceleration: acceleration)).to eq([nil])
            expect(SmarterJSON.process_one("None", acceleration: acceleration)).to be_nil
          end
        end

        describe "number overflow warning (:number_overflow)" do
          it "warns when a finite literal overflows Float range to Infinity" do
            types = []
            SmarterJSON.process("[1e400]", on_warning: ->(w) { types << w.type }, acceleration: acceleration)
            expect(types).to eq([:number_overflow])
          end

          it "warns for negative overflow too" do
            types = []
            SmarterJSON.process("[-1e400]", on_warning: ->(w) { types << w.type }, acceleration: acceleration)
            expect(types).to eq([:number_overflow])
          end

          it "still returns Infinity — the change is reported, not silent" do
            expect(SmarterJSON.process_one("[1e400]", acceleration: acceleration)).to eq([Float::INFINITY])
          end

          it "does NOT warn on a literal Infinity / -Infinity / NaN (intentional, not an overflow)" do
            types = []
            SmarterJSON.process("[Infinity, -Infinity, NaN]", on_warning: ->(w) { types << w.type }, acceleration: acceleration)
            expect(types).to eq([])
          end

          it "does NOT warn in :bigdecimal mode — the value is preserved, no overflow" do
            types = []
            v = SmarterJSON.process_one("[1e400]", decimal_precision: :bigdecimal,
                                                   on_warning: ->(w) { types << w.type }, acceleration: acceleration)
            expect(types).to eq([])
            expect(v.first).to be_a(BigDecimal)
            expect(v.first.finite?).to be(true)
          end
        end

        describe "JavaScript undefined" do
          it "parses undefined as nil" do
            expect(SmarterJSON.process("undefined", acceleration: acceleration)).to eq([nil])
            expect(SmarterJSON.process_one("undefined", acceleration: acceleration)).to be_nil
          end

          it "parses undefined as a value (object value, array element) as nil" do
            expect(SmarterJSON.process('{"a": undefined}', acceleration: acceleration)).to eq([{ "a" => nil }])
            expect(SmarterJSON.process_one('{"a": undefined}', acceleration: acceleration)).to eq({ "a" => nil })
            expect(SmarterJSON.process("[undefined]", acceleration: acceleration)).to eq([[nil]])
            expect(SmarterJSON.process_one("[undefined]", acceleration: acceleration)).to eq([nil])
          end

          # As a *key*, undefined is the string "undefined" — object keys are always
          # strings, and recognized-literal-wins does not apply in key position.
          # (Resolves the design-doc §7.3 open question.)
          it "parses undefined as an object key as the string \"undefined\"" do
            expect(SmarterJSON.process("{undefined: 1}", acceleration: acceleration)).to eq([{ "undefined" => 1 }])
            expect(SmarterJSON.process_one("{undefined: 1}", acceleration: acceleration)).to eq({ "undefined" => 1 })
            expect(SmarterJSON.process('{"undefined": 1}', acceleration: acceleration)).to eq([{ "undefined" => 1 }])
            expect(SmarterJSON.process_one('{"undefined": 1}', acceleration: acceleration)).to eq({ "undefined" => 1 })
          end
        end

        describe "underscores in numeric literals" do
          it "parses 1_000_000 as 1000000" do
            expect(SmarterJSON.process("1_000_000", acceleration: acceleration)).to eq([1_000_000])
            expect(SmarterJSON.process_one("1_000_000", acceleration: acceleration)).to eq(1_000_000)
          end

          it "parses 1_000.5 as 1000.5" do
            expect(SmarterJSON.process("1_000.5", acceleration: acceleration)).to eq([1000.5])
            expect(SmarterJSON.process_one("1_000.5", acceleration: acceleration)).to eq(1000.5)
          end
        end

        describe "line ending normalization" do
          it "accepts CRLF line endings" do
            expect(SmarterJSON.process("{\r\n  a: 1\r\n  b: 2\r\n}", acceleration: acceleration)).to eq([{ "a" => 1, "b" => 2 }])
            expect(SmarterJSON.process_one("{\r\n  a: 1\r\n  b: 2\r\n}", acceleration: acceleration)).to eq({ "a" => 1, "b" => 2 })
          end

          it "accepts CR-only line endings (classic Mac)" do
            expect(SmarterJSON.process("{\r  a: 1\r  b: 2\r}", acceleration: acceleration)).to eq([{ "a" => 1, "b" => 2 }])
            expect(SmarterJSON.process_one("{\r  a: 1\r  b: 2\r}", acceleration: acceleration)).to eq({ "a" => 1, "b" => 2 })
          end

          it "accepts mixed line endings in one document" do
            expect(SmarterJSON.process("{\n  a: 1\r\n  b: 2\r  c: 3\n}", acceleration: acceleration)).to eq([{ "a" => 1, "b" => 2, "c" => 3 }])
            expect(SmarterJSON.process_one("{\n  a: 1\r\n  b: 2\r  c: 3\n}", acceleration: acceleration)).to eq({ "a" => 1, "b" => 2, "c" => 3 })
          end

          it "accepts # comments across CR-only line endings" do
            expect(SmarterJSON.process("a: 1\r# note\rb: 2", acceleration: acceleration)).to eq([{ "a" => 1, "b" => 2 }])
            expect(SmarterJSON.process_one("a: 1\r# note\rb: 2", acceleration: acceleration)).to eq({ "a" => 1, "b" => 2 })
          end

          it "accepts // comments across CR-only line endings" do
            expect(SmarterJSON.process("a: 1\r// note\rb: 2", acceleration: acceleration)).to eq([{ "a" => 1, "b" => 2 }])
            expect(SmarterJSON.process_one("a: 1\r// note\rb: 2", acceleration: acceleration)).to eq({ "a" => 1, "b" => 2 })
          end
        end

        describe "duplicate keys" do
          it "last value wins by default" do
            expect(SmarterJSON.process('{"dup": 1, "dup": 2}', acceleration: acceleration).first["dup"]).to eq(2)
            expect(SmarterJSON.process_one('{"dup": 1, "dup": 2}', acceleration: acceleration)["dup"]).to eq(2)
          end
        end
      end

      # ============================================================
      # Top-level scalars (RFC 8259)
      # ============================================================

      describe "top-level scalars" do
        it "parses bare integer at top level" do
          expect(SmarterJSON.process("42", acceleration: acceleration)).to eq([42])
          expect(SmarterJSON.process_one("42", acceleration: acceleration)).to eq(42)
        end

        it "parses bare float at top level" do
          expect(SmarterJSON.process("3.14", acceleration: acceleration)).to eq([3.14])
          expect(SmarterJSON.process_one("3.14", acceleration: acceleration)).to eq(3.14)
        end

        it "parses bare string at top level" do
          expect(SmarterJSON.process('"hello"', acceleration: acceleration)).to eq(["hello"])
          expect(SmarterJSON.process_one('"hello"', acceleration: acceleration)).to eq("hello")
        end

        it "parses bare true at top level" do
          expect(SmarterJSON.process("true", acceleration: acceleration)).to eq([true])
          expect(SmarterJSON.process_one("true", acceleration: acceleration)).to eq(true)
        end

        it "parses bare null at top level" do
          expect(SmarterJSON.process("null", acceleration: acceleration)).to eq([nil])
          expect(SmarterJSON.process_one("null", acceleration: acceleration)).to be_nil
        end
      end

      # ============================================================
      # Encoding handling (§3.1)
      # ============================================================

      # ============================================================
      # Array string-element dispatch coverage. Locks the behavior of
      # every path the per-element array dispatch in fj_parse_iter
      # touches, so the inline `"`-string short-circuit cannot regress
      # it. Strict cases are cross-checked against JSON.parse; all cases
      # run on both the C and pure-Ruby paths.
      # ============================================================

      describe "array string elements (dispatch coverage)" do
        {
          "plain strings" => '["a", "b", "c"]',
          "single empty string" => '[""]',
          "several empty strings" => '["", "", ""]',
          "escapes (quote / newline / tab)" => '["a\"b", "line\nbreak", "tab\there"]',
          "escapes (backslash / slash)" => '["\\\\", "\/"]',
          "unicode escape + surrogate pair" => '["é", "😀"]',
          "strings beside numbers/literals" => '["a", 1, true, false, null, "z"]',
          "string in a nested array" => '[["a", "b"], ["c"]]',
          "string as object value in array" => '[{"s": "x"}, "y"]',
          "whitespace around elements" => '[ "a" , "b" ]',
        }.each do |label, input|
          it "matches JSON.parse for #{label}" do
            expected = JSON.parse(input)
            expect(SmarterJSON.process_one(input, acceleration: acceleration)).to eq(expected)
            expect(SmarterJSON.process(input, acceleration: acceleration)).to eq([expected])
          end
        end

        it "preserves multibyte UTF-8 string elements (content, encoding, bytesize)" do
          input    = '["café", "Zürich", "日本語", "😀"]'.dup.force_encoding("UTF-8")
          expected = ["café", "Zürich", "日本語", "😀"]
          [SmarterJSON.process_one(input, acceleration: acceleration),
           SmarterJSON.process(input, acceleration: acceleration).first].each do |got|
            expect(got).to eq(expected)
            got.each_with_index do |s, i|
              expect(s.encoding).to eq(Encoding::UTF_8)
              expect(s.bytesize).to eq(expected[i].bytesize)
            end
          end
        end

        it "parses a large all-strings array (string_array.json shape)" do
          elems = Array.new(5_000) { |i| "item ##{i} café" }
          input = JSON.generate(elems)
          expect(SmarterJSON.process_one(input, acceleration: acceleration)).to eq(elems)
          expect(SmarterJSON.process(input, acceleration: acceleration)).to eq([elems])
        end

        it "still routes single-quoted string elements through the full dispatch" do
          expect(SmarterJSON.process_one("['x', 'y']", acceleration: acceleration)).to eq(["x", "y"])
        end

        it "still routes quoteless string elements through the full dispatch" do
          expect(SmarterJSON.process_one("[red green blue]", acceleration: acceleration)).to eq(["red green blue"])
          expect(SmarterJSON.process_one("[red, green, blue]", acceleration: acceleration)).to eq(["red", "green", "blue"])
        end

        it "still collapses an empty slot (and warns) next to string elements" do
          warnings = []
          result = SmarterJSON.process_one('["a",, "b"]', acceleration: acceleration, on_warning: ->(w) { warnings << w.type })
          expect(result).to eq(["a", "b"])
          expect(warnings).to include(:empty_slot)
        end

        it "still accepts a trailing comma after a string element" do
          expect(SmarterJSON.process_one('["a", "b",]', acceleration: acceleration)).to eq(["a", "b"])
        end

        it "raises on an unterminated string element / array" do
          expect { SmarterJSON.process_one('["a', acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
          expect { SmarterJSON.process_one('["a"', acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
        end
      end

      # Coverage for the parse_string scan (the byteindex bulk-scan target). Inputs are
      # generated with JSON.generate so the JSON is guaranteed valid and we assert we parse
      # back to the exact value — no hand-escaping. Exercises closing-quote detection,
      # backslash/escape handling, multibyte content, and long runs (the bulk-jump path).
      describe "string scan coverage" do
        [
          "hello world",
          "",
          "a\"b",                          # embedded (escaped) quote
          "a\\b",                          # embedded backslash
          "\\",                            # lone backslash
          "a\\",                           # backslash immediately before the closing quote
          "\"",                            # lone quote
          "tab\there and a\nnewline",
          "café 日本語 😀 multibyte",
          "#{"x" * 5000}\n#{"y" * 5000}",  # long, with a late escape
          "z" * 8000                       # long, no escapes (pure bulk jump)
        ].each do |value|
          it "round-trips #{value.inspect[0, 28]}" do
            input = JSON.generate(value)
            expect(SmarterJSON.process_one(input, acceleration: acceleration)).to eq(value)
            expect(SmarterJSON.process(input, acceleration: acceleration)).to eq([value])
          end
        end

        it "scans a single-quoted string with an escaped quote" do
          expect(SmarterJSON.process_one(%q{'a\'b'}, acceleration: acceleration)).to eq("a'b")
        end

        it "raises on an unterminated string (no closing quote)" do
          expect { SmarterJSON.process_one('"abc', acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError, /unterminated string/)
        end

        it "raises on a trailing backslash (unterminated escape)" do
          expect { SmarterJSON.process_one('"abc\\', acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError, /unterminated/)
        end
      end

      describe "encoding handling" do
        it "preserves input string encoding (UTF-8)" do
          input = '{"name": "café"}'.dup.force_encoding("UTF-8")
          result = SmarterJSON.process_one(input, acceleration: acceleration)
          expect(result["name"]).to eq("café")
          expect(result["name"].encoding).to eq(Encoding::UTF_8)
          expect(SmarterJSON.process(input, acceleration: acceleration).first["name"].encoding).to eq(Encoding::UTF_8)
        end

        it "preserves Latin-1 input encoding without transcoding" do
          # "café" in Latin-1: 0x63 0x61 0x66 0xE9
          input = "{\"name\": \"caf\xE9\"}".b.force_encoding("ISO-8859-1")
          result = SmarterJSON.process_one(input, acceleration: acceleration)
          expect(result["name"].encoding).to eq(Encoding::ISO_8859_1)
          expect(result["name"].bytes).to eq([0x63, 0x61, 0x66, 0xE9])
          expect(SmarterJSON.process(input, acceleration: acceleration).first["name"].encoding).to eq(Encoding::ISO_8859_1)
        end

        describe "default encoding — ASCII-8BIT input treated as UTF-8 (the HTTP-body case)" do
          it "relabels a valid-UTF-8 body tagged ASCII-8BIT to UTF-8, so equality works" do
            # How Net::HTTP and many HTTP libraries hand you response.body: correct
            # UTF-8 bytes, but tagged ASCII-8BIT. Left as BINARY, result["name"] would
            # compare unequal to a UTF-8 literal even though the bytes match.
            input = '{"name":"café","city":"Zürich"}'.dup.force_encoding("ASCII-8BIT")
            result = SmarterJSON.process_one(input, acceleration: acceleration)
            expect(result["name"].encoding).to eq(Encoding::UTF_8)
            expect(result["name"]).to eq("café")
            expect(result["city"]).to eq("Zürich")
            expect(SmarterJSON.process(input, acceleration: acceleration).first["name"].encoding).to eq(Encoding::UTF_8)
          end

          it "relabels a pure-ASCII body tagged ASCII-8BIT to UTF-8" do
            input = '{"a":"x"}'.dup.force_encoding("ASCII-8BIT")
            result = SmarterJSON.process_one(input, acceleration: acceleration)
            expect(result["a"].encoding).to eq(Encoding::UTF_8)
            expect(result["a"]).to eq("x")
          end

          it "raises EncodingError when an ASCII-8BIT body is not valid UTF-8" do
            # 0xFF is not valid UTF-8. JSON's interchange encoding is UTF-8, so we raise
            # rather than silently return BINARY strings or guess a legacy encoding —
            # pass an explicit encoding: for genuinely-Latin-1 input (next example).
            input = "{\"name\":\"caf\xFF\"}".dup.force_encoding("ASCII-8BIT")
            expect { SmarterJSON.process_one(input, acceleration: acceleration) }.to raise_error(SmarterJSON::EncodingError)
            expect { SmarterJSON.process(input, acceleration: acceleration) }.to raise_error(SmarterJSON::EncodingError)
          end

          it "respects an explicit encoding: on ASCII-8BIT input (no smart default)" do
            # Latin-1 "café" (0xE9), tagged BINARY, but the caller declares ISO-8859-1.
            input = "{\"name\":\"caf\xE9\"}".dup.force_encoding("ASCII-8BIT")
            result = SmarterJSON.process_one(input, encoding: "ISO-8859-1", acceleration: acceleration)
            expect(result["name"].encoding).to eq(Encoding::ISO_8859_1)
            expect(result["name"].bytes).to eq([0x63, 0x61, 0x66, 0xE9])
          end
        end

        it "parse_file accepts :encoding option" do
          file = File.join(fixtures_dir, "json_pass1.json")
          result = SmarterJSON.process_file(file, encoding: "UTF-8", acceleration: acceleration)
          expect(result.length).to eq(1) # always-array: one document (a top-level array)
          expect(result[0][0]).to eq("JSON Test Pattern pass1")
        end
      end

      # ============================================================
      # Error handling
      # ============================================================

      describe "error handling" do
        it "raises SmarterJSON::ParseError on truly unparseable input" do
          expect { SmarterJSON.process("this is not valid {json}", acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
          expect { SmarterJSON.process_one("this is not valid {json}", acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
        end

        it "raises SmarterJSON::ParseError on unterminated string" do
          expect { SmarterJSON.process('"unterminated', acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError, /unterminated string/)
          expect { SmarterJSON.process_one('"unterminated', acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError, /unterminated string/)
        end

        it "raises SmarterJSON::ParseError on unterminated object" do
          expect { SmarterJSON.process('{"a": 1', acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
          expect { SmarterJSON.process_one('{"a": 1', acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
        end

        it "raises SmarterJSON::ParseError on unterminated array" do
          expect { SmarterJSON.process("[1, 2, 3", acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
          expect { SmarterJSON.process_one("[1, 2, 3", acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
        end

        it "raises on a mismatched closing bracket in an array ([1, 2})" do
          expect { SmarterJSON.process("[1, 2}", acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
          expect { SmarterJSON.process_one("[1, 2}", acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
        end

        it 'raises on a mismatched closing bracket in an object ({"a": 1])' do
          expect { SmarterJSON.process('{"a": 1]', acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
          expect { SmarterJSON.process_one('{"a": 1]', acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
        end

        it "returns nil for empty input (zero documents)" do
          expect(SmarterJSON.process("", acceleration: acceleration)).to eq([])
          expect(SmarterJSON.process_one("", acceleration: acceleration)).to be_nil
        end

        it "returns nil for whitespace-only input (zero documents)" do
          expect(SmarterJSON.process("    ", acceleration: acceleration)).to eq([])
          expect(SmarterJSON.process_one("    ", acceleration: acceleration)).to be_nil
        end

        it "returns nil for comment-only input (zero documents)" do
          expect(SmarterJSON.process("// just a comment\n", acceleration: acceleration)).to eq([])
          expect(SmarterJSON.process_one("// just a comment\n", acceleration: acceleration)).to be_nil
        end

        it "raises SmarterJSON::ParseError on bad escape sequence" do
          expect { SmarterJSON.process('"\q"', acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError, /escape/)
          expect { SmarterJSON.process_one('"\q"', acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError, /escape/)
        end

        it "reports line and column on the error" do
          # A mismatched closing bracket on line 3 is genuinely unparseable.
          # (Note: `@` is NOT an error — it is a valid quoteless string.)
          expect { SmarterJSON.process("{\n  \"a\": 1\n  ]", acceleration: acceleration) }
            .to raise_error(SmarterJSON::ParseError) { |err| expect(err.line).to eq(3) }

          SmarterJSON.process_one("{\n  \"a\": 1\n  ]", acceleration: acceleration)
          raise "expected ParseError"
        rescue SmarterJSON::ParseError => e
          expect(e.line).to eq(3)
          expect(e.col).to be_a(Integer)
          expect(e.message).to match(/line/)
          expect(e.message).to match(/col/)
        end

        it 'parses {"a": @} as a quoteless string (not an error)' do
          expect(SmarterJSON.process('{"a": @}', acceleration: acceleration)).to eq([{ "a" => "@" }])
          expect(SmarterJSON.process_one('{"a": @}', acceleration: acceleration)).to eq({ "a" => "@" })
        end

        it "reports line and column on unterminated string" do
          expect { SmarterJSON.process('"oops', acceleration: acceleration) }
            .to raise_error(SmarterJSON::ParseError) { |err| expect(err.line).to eq(1) }

          SmarterJSON.process_one('"oops', acceleration: acceleration)
          raise "expected ParseError"
        rescue SmarterJSON::ParseError => e
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
          result = SmarterJSON.process_file(file, acceleration: acceleration)
          expect(result.length).to eq(1) # always-array: one document (a top-level array)
          expect(result[0][0]).to eq("JSON Test Pattern pass1")
        end

        it "raises Errno::ENOENT for missing file" do
          expect { SmarterJSON.process_file("/nonexistent/path/to/file.json", acceleration: acceleration) }.to raise_error(Errno::ENOENT)
        end
      end

      # ============================================================
      # parse with a block — yields each top-level value (JSONL / concatenated / streams)
      # ============================================================

      describe "parse with a block (multiple top-level values)" do
        # Collect the values yielded by the block form of SmarterJSON.process.
        def parse_values(input, **opts)
          values = []
          SmarterJSON.process(input, **opts) { |v| values << v }
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

        it "yields each value with leading, trailing, and repeated LF blank lines between documents" do
          input = "\n\n{\"event\": 1}\n\n{\"event\": 2}\n\n"
          expect(parse_values(input, acceleration: acceleration)).to eq([{ "event" => 1 }, { "event" => 2 }])
        end

        it "yields each value with leading, trailing, and repeated CRLF blank lines between documents" do
          input = "\r\n\r\n{\"event\": 1}\r\n\r\n{\"event\": 2}\r\n\r\n"
          expect(parse_values(input, acceleration: acceleration)).to eq([{ "event" => 1 }, { "event" => 2 }])
        end

        it "yields each value with leading, trailing, and repeated CR-only blank lines between documents" do
          input = "\r\r{\"event\": 1}\r\r{\"event\": 2}\r\r"
          expect(parse_values(input, acceleration: acceleration)).to eq([{ "event" => 1 }, { "event" => 2 }])
        end

        it "yields each of concatenated objects with no separator" do
          expect(parse_values('{"a":1}{"b":2}', acceleration: acceleration)).to eq([{ "a" => 1 }, { "b" => 2 }])
        end

        it "raises on a top-level bare run via the block form (a space is not a separator)" do
          expect { parse_values('42 "x" true', acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
        end

        it "yields nothing for empty input" do
          expect(parse_values("", acceleration: acceleration)).to eq([])
        end

        it "yields nothing for whitespace/comment-only input" do
          expect(parse_values("  // just a comment\n  ", acceleration: acceleration)).to eq([])
        end

        it "returns the document count from the block form" do
          expect(SmarterJSON.process('{"a": 1}', acceleration: acceleration) { |_v| }).to eq(1)
        end
      end

      # ============================================================
      # parse without a block — auto: nil / single value / Array of documents
      # (no option, no flag; the count is detected for free)
      # ============================================================

      describe "process: String / IO / block streaming" do
        it "process(String) with a block yields each top-level document and returns the document count" do
          out = []
          rv = SmarterJSON.process(%({"id":1}\n{"id":2}\n{"id":3}), acceleration: acceleration) { |v| out << v }
          expect(out).to eq([{ "id" => 1 }, { "id" => 2 }, { "id" => 3 }])
          expect(rv).to eq(out.length) # block form returns the document count (== values yielded)
        end

        it "process(IO) with a block streams each document from the IO" do
          io = StringIO.new(%({"id":1}\n{"id":2}\n{"id":3}\n))
          out = []
          rv = SmarterJSON.process(io, acceleration: acceleration) { |v| out << v }
          expect(out).to eq([{ "id" => 1 }, { "id" => 2 }, { "id" => 3 }])
          expect(rv).to eq(out.length) # block form returns the document count (== values yielded)
        end

        it "process(IO) with a block ignores leading, trailing, and repeated LF blank lines" do
          io = StringIO.new("\n\n{\"id\":1}\n\n{\"id\":2}\n\n")
          out = []
          rv = SmarterJSON.process(io, acceleration: acceleration) { |v| out << v }
          expect(out).to eq([{ "id" => 1 }, { "id" => 2 }])
          expect(rv).to eq(out.length) # block form returns the document count (== values yielded)
        end

        it "process(IO) with a block ignores leading, trailing, and repeated CRLF blank lines" do
          io = StringIO.new("\r\n\r\n{\"id\":1}\r\n\r\n{\"id\":2}\r\n\r\n")
          out = []
          rv = SmarterJSON.process(io, acceleration: acceleration) { |v| out << v }
          expect(out).to eq([{ "id" => 1 }, { "id" => 2 }])
          expect(rv).to eq(out.length) # block form returns the document count (== values yielded)
        end

        it "process(IO) with a block handles CR-only blank lines and CR-only document separators" do
          io = StringIO.new("\r\r{\"id\":1}\r\r{\"id\":2}\r\r")
          out = []
          rv = SmarterJSON.process(io, acceleration: acceleration) { |v| out << v }
          expect(out).to eq([{ "id" => 1 }, { "id" => 2 }])
          expect(rv).to eq(out.length) # block form returns the document count (== values yielded)
        end

        it "process(IO) with a block handles mixed newline styles between documents" do
          io = StringIO.new("\n{\"id\":1}\r\n\r{\"id\":2}\n\n{\"id\":3}\r")
          out = []
          rv = SmarterJSON.process(io, acceleration: acceleration) { |v| out << v }
          expect(out).to eq([{ "id" => 1 }, { "id" => 2 }, { "id" => 3 }])
          expect(rv).to eq(out.length) # block form returns the document count (== values yielded)
        end

        it "process(IO) with a block skips comment-only records between documents" do
          io = StringIO.new("{\"id\":1}\n# note\n\n// note\n{\"id\":2}\n")
          out = []
          rv = SmarterJSON.process(io, acceleration: acceleration) { |v| out << v }
          expect(out).to eq([{ "id" => 1 }, { "id" => 2 }])
          expect(rv).to eq(out.length) # block form returns the document count (== values yielded)
        end

        it "process(IO) without a block returns an Array of documents" do
          expect(SmarterJSON.process(StringIO.new('{"a":1}'), acceleration: acceleration)).to eq([{ "a" => 1 }])
          expect(SmarterJSON.process(StringIO.new(%({"a":1}\n{"b":2})), acceleration: acceleration)).to eq([{ "a" => 1 }, { "b" => 2 }])
        end

        it "process(IO) without a block ignores LF / CRLF / CR-only blank lines around documents" do
          expect(SmarterJSON.process(StringIO.new("\n\n{\"a\":1}\n\n{\"b\":2}\n\n"), acceleration: acceleration)).to eq([{ "a" => 1 }, { "b" => 2 }])
          expect(SmarterJSON.process(StringIO.new("\r\n\r\n{\"a\":1}\r\n\r\n{\"b\":2}\r\n\r\n"), acceleration: acceleration)).to eq([{ "a" => 1 }, { "b" => 2 }])
          expect(SmarterJSON.process(StringIO.new("\r\r{\"a\":1}\r\r{\"b\":2}\r\r"), acceleration: acceleration)).to eq([{ "a" => 1 }, { "b" => 2 }])
        end

        it "process(IO) without a block handles mixed newline styles between documents" do
          io = StringIO.new("\n{\"a\":1}\r\n\r{\"b\":2}\n\n{\"c\":3}\r")
          expect(SmarterJSON.process(io, acceleration: acceleration)).to eq([{ "a" => 1 }, { "b" => 2 }, { "c" => 3 }])
        end

        it "process(IO) without a block skips comment-only records between documents" do
          io = StringIO.new("{\"a\":1}\n# note\n\n// note\n{\"b\":2}\n")
          expect(SmarterJSON.process(io, acceleration: acceleration)).to eq([{ "a" => 1 }, { "b" => 2 }])
        end

        it "process raises ArgumentError for neither a String nor an IO" do
          expect { SmarterJSON.process(42, acceleration: acceleration) }.to raise_error(ArgumentError)
        end

        it "process_file with a block streams each document from disk and returns the document count" do
          out = []
          rv = SmarterJSON.process_file(File.join(fixtures_dir, "multi_doc.ndjson"), acceleration: acceleration) { |v| out << v }
          expect(out).to eq([{ "id" => 1 }, { "id" => 2 }, { "id" => 3 }])
          expect(rv).to eq(out.length) # block form returns the document count (== values yielded)
        end

        it "process_file with a block handles LF / CRLF / CR blank lines around documents" do
          ["\n\n{\"id\":1}\n\n{\"id\":2}\n\n", "\r\n\r\n{\"id\":1}\r\n\r\n{\"id\":2}\r\n\r\n", "\r\r{\"id\":1}\r\r{\"id\":2}\r\r"].each do |content|
            out = []
            Tempfile.create(["multi-doc", ".txt"]) do |f|
              f.binmode
              f.write(content)
              f.flush
              rv = SmarterJSON.process_file(f.path, acceleration: acceleration) { |v| out << v }
              expect(rv).to eq(out.length) # block form returns the document count (== values yielded)
            end
            expect(out).to eq([{ "id" => 1 }, { "id" => 2 }])
          end
        end

        it "process_file with a block handles mixed newline styles and comment-only records" do
          out = []
          Tempfile.create(["multi-doc-mixed", ".txt"]) do |f|
            f.binmode
            f.write("\n{\"id\":1}\r\n# note\r// note\n\n{\"id\":2}\r")
            f.flush
            rv = SmarterJSON.process_file(f.path, acceleration: acceleration) { |v| out << v }
            expect(rv).to eq(out.length) # block form returns the document count (== values yielded)
          end
          expect(out).to eq([{ "id" => 1 }, { "id" => 2 }])
        end

        it "process_file without a block returns an Array of the documents" do
          expect(SmarterJSON.process_file(File.join(fixtures_dir, "multi_doc.ndjson"), acceleration: acceleration)).to eq([{ "id" => 1 }, { "id" => 2 }, { "id" => 3 }])
        end

        it "process_file without a block handles LF / CRLF / CR blank lines around documents" do
          ["\n\n{\"a\":1}\n\n{\"b\":2}\n\n", "\r\n\r\n{\"a\":1}\r\n\r\n{\"b\":2}\r\n\r\n", "\r\r{\"a\":1}\r\r{\"b\":2}\r\r"].each do |content|
            Tempfile.create(["multi-doc", ".txt"]) do |f|
              f.binmode
              f.write(content)
              f.flush
              expect(SmarterJSON.process_file(f.path, acceleration: acceleration)).to eq([{ "a" => 1 }, { "b" => 2 }])
            end
          end
        end

        it "process_file without a block handles mixed newline styles and comment-only records" do
          Tempfile.create(["multi-doc-mixed", ".txt"]) do |f|
            f.binmode
            f.write("\n{\"a\":1}\r\n# note\r// note\n\n{\"b\":2}\r")
            f.flush
            expect(SmarterJSON.process_file(f.path, acceleration: acceleration)).to eq([{ "a" => 1 }, { "b" => 2 }])
          end
        end
      end

      describe "parse without a block (auto nil / value / Array)" do
        it "returns [] for empty input (zero documents)" do
          expect(SmarterJSON.process("", acceleration: acceleration)).to eq([])
        end

        it "returns a one-element Array for a single document" do
          expect(SmarterJSON.process('{"a": 1}', acceleration: acceleration)).to eq([{ "a" => 1 }])
        end

        it "wraps a bare scalar in a one-element Array (single document)" do
          expect(SmarterJSON.process("42", acceleration: acceleration)).to eq([42])
        end

        it "wraps a single top-level array (one document, not flattened)" do
          expect(SmarterJSON.process("[1, 2, 3]", acceleration: acceleration)).to eq([[1, 2, 3]])
        end

        it "returns an Array of documents for newline-delimited JSON (NDJSON / JSONL)" do
          input = %({"event": 1}\n{"event": 2}\n{"event": 3}\n)
          expect(SmarterJSON.process(input, acceleration: acceleration)).to eq([{ "event" => 1 }, { "event" => 2 }, { "event" => 3 }])
        end

        it "returns an Array of documents with leading, trailing, and repeated LF blank lines" do
          input = "\n\n{\"event\": 1}\n\n{\"event\": 2}\n\n"
          expect(SmarterJSON.process(input, acceleration: acceleration)).to eq([{ "event" => 1 }, { "event" => 2 }])
        end

        it "returns an Array of documents with leading, trailing, and repeated CRLF blank lines" do
          input = "\r\n\r\n{\"event\": 1}\r\n\r\n{\"event\": 2}\r\n\r\n"
          expect(SmarterJSON.process(input, acceleration: acceleration)).to eq([{ "event" => 1 }, { "event" => 2 }])
        end

        it "returns an Array of documents with leading, trailing, and repeated CR-only blank lines" do
          input = "\r\r{\"event\": 1}\r\r{\"event\": 2}\r\r"
          expect(SmarterJSON.process(input, acceleration: acceleration)).to eq([{ "event" => 1 }, { "event" => 2 }])
        end

        it "returns an Array of documents with mixed newline styles between documents" do
          input = "\n{\"event\": 1}\r\n\r{\"event\": 2}\n\n{\"event\": 3}\r"
          expect(SmarterJSON.process(input, acceleration: acceleration)).to eq([{ "event" => 1 }, { "event" => 2 }, { "event" => 3 }])
        end

        it "returns an Array of documents with blank and comment-only separators between documents" do
          input = "{\"event\": 1}\n# note\n\n// note\n{\"event\": 2}\n"
          expect(SmarterJSON.process(input, acceleration: acceleration)).to eq([{ "event" => 1 }, { "event" => 2 }])
        end

        it "returns an Array for concatenated objects with no separator" do
          expect(SmarterJSON.process('{"a":1}{"b":2}', acceleration: acceleration)).to eq([{ "a" => 1 }, { "b" => 2 }])
        end

        it "raises on a top-level bare run (a space is not a separator)" do
          expect { SmarterJSON.process('42 "x" true', acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
        end

        it "returns an Array of arrays for newline-separated top-level arrays" do
          expect(SmarterJSON.process("[1,2]\n[3,4]", acceleration: acceleration)).to eq([[1, 2], [3, 4]])
        end

        # Top-level commas separate documents (collapsing, like the in-container rule) —
        # NOT an implicit root array: `1, 2, 3` is three documents [1, 2, 3], which stays
        # distinct from the single array document `[1, 2, 3]` -> [[1, 2, 3]].
        it "separates a bracketless comma list into top-level documents" do
          expect(SmarterJSON.process("1, 2, 3", acceleration: acceleration)).to eq([1, 2, 3])
        end

        it "raises on bracketless comma-separated bare words (each is a bare top-level word)" do
          expect { SmarterJSON.process("red, green, blue", acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
        end
      end

      describe "parser edge cases (coverage)" do
        it "parses undefined as nil" do
          expect(SmarterJSON.process("undefined", acceleration: acceleration)).to eq([nil])
          expect(SmarterJSON.process_one("undefined", acceleration: acceleration)).to be_nil
        end

        it "raises on truncated input (unterminated container)" do
          expect { SmarterJSON.process("[1, 2", acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
          expect { SmarterJSON.process_one("[1, 2", acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
          expect { SmarterJSON.process('{"a":', acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
          expect { SmarterJSON.process_one('{"a":', acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
        end

        it "treats rare Unicode whitespace (U+1680 Ogham, U+205F math space) as whitespace" do
          ws = [0x1680, 0x205f].pack("U*")
          expect(SmarterJSON.process("#{ws}42", acceleration: acceleration)).to eq([42])
          expect(SmarterJSON.process_one("#{ws}42", acceleration: acceleration)).to eq(42)
        end

        it "treats the ideographic space (U+3000) as whitespace between tokens" do
          expect(SmarterJSON.process("　{}　", acceleration: acceleration)).to eq([{}])
          expect(SmarterJSON.process_one("　{}　", acceleration: acceleration)).to eq({})
        end

        # A '#' starts a comment only when preceded by whitespace. Here the
        # preceding whitespace is a multibyte char (NBSP, U+00A0) with no ASCII
        # space between it and the '#', exercising the rare walk-back-over-
        # continuation-bytes branch of preceded_by_ws_or_start?.
        it "applies the comment-marker rule when the preceding whitespace is a multibyte Unicode space" do
          expect(SmarterJSON.process("42 # trailing comment\n", acceleration: acceleration)).to eq([42])
          expect(SmarterJSON.process_one("42 # trailing comment\n", acceleration: acceleration)).to eq(42)
        end

        it "raises on an unterminated smart-quoted string" do
          expect { SmarterJSON.process("[“unclosed", acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
          expect { SmarterJSON.process_one("[“unclosed", acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
        end

        it "classifies a quoteless 'undefined' value as nil" do
          expect(SmarterJSON.process("{a: undefined}", acceleration: acceleration)).to eq([{ "a" => nil }])
          expect(SmarterJSON.process_one("{a: undefined}", acceleration: acceleration)).to eq({ "a" => nil })
        end

        it "classifies a quoteless 'NaN' value as Float::NAN" do
          result = SmarterJSON.process_one("{a: NaN}", acceleration: acceleration)
          expect(result["a"]).to be_a(Float)
          expect(result["a"]).to be_nan
          expect(SmarterJSON.process("{a: NaN}", acceleration: acceleration).first["a"]).to be_a(Float).and(be_nan)
        end

        it "classifies a quoteless 'Infinity' / '+Infinity' value as Float::INFINITY" do
          expect(SmarterJSON.process("{a: Infinity}", acceleration: acceleration)).to eq([{ "a" => Float::INFINITY }])
          expect(SmarterJSON.process_one("{a: Infinity}", acceleration: acceleration)).to eq({ "a" => Float::INFINITY })
          expect(SmarterJSON.process("{a: +Infinity}", acceleration: acceleration)).to eq([{ "a" => Float::INFINITY }])
          expect(SmarterJSON.process_one("{a: +Infinity}", acceleration: acceleration)).to eq({ "a" => Float::INFINITY })
        end

        # JSON5 line continuation: a backslash immediately before a CRLF emits
        # nothing, joining the two lines (the CR branch must also swallow the LF).
        it "treats a backslash before CRLF inside a string as a line continuation" do
          expect(SmarterJSON.process(%("a\\\r\nb"), acceleration: acceleration)).to eq(["ab"])
          expect(SmarterJSON.process_one(%("a\\\r\nb"), acceleration: acceleration)).to eq("ab")
        end

        it "decodes a valid UTF-16 stand-in pair (\\uD83D\\uDE00 -> grinning face)" do
          expect(SmarterJSON.process('"😀"', acceleration: acceleration)).to eq(["\u{1F600}"])
          expect(SmarterJSON.process(%q{"\uD83D\uDE00"}, acceleration: acceleration)).to eq(["\u{1F600}"])
          expect(SmarterJSON.process_one(%q{"\uD83D\uDE00"}, acceleration: acceleration)).to eq("\u{1F600}")
        end

        it "raises on a high stand-in not followed by a \\u escape" do
          expect { SmarterJSON.process('"\uD800x"', acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
          expect { SmarterJSON.process_one('"\uD800x"', acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
        end

        it "raises on a high stand-in followed by an invalid low-stand-in \\u escape" do
          expect { SmarterJSON.process('"\uD800\uZZZZ"', acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
          expect { SmarterJSON.process_one('"\uD800\uZZZZ"', acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
        end

        it "raises on a high stand-in followed by a non-low-stand-in code point" do
          expect { SmarterJSON.process('"\uD800A"', acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
          expect { SmarterJSON.process_one('"\uD800\u0041"', acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
        end

        # Regression (found by fuzzing): a \\u escape whose next 4 bytes split a raw
        # multibyte character must raise a clean ParseError, not leak ArgumentError
        # ("invalid byte sequence in UTF-8") from the Ruby path's hex check.
        it "raises ParseError (not ArgumentError) when a backslash-u escape is followed by bytes splitting a multibyte char" do
          expect { SmarterJSON.process('"' + "\\uaaa" + [0x3042].pack("U") + '"', acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
          input = '"' + "\\uaaa" + [0x3042].pack("U") + '"' # "\\uaaa<3-byte char>"
          expect { SmarterJSON.process_one(input, acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
        end

        # Commas are collapsing separators: empty slots around / between commas are
        # skipped, in both arrays and objects. An explicit `null` is still a value.
        it "skips empty array slots from leading / interior / trailing commas" do
          expect(SmarterJSON.process("[,]", acceleration: acceleration)).to eq([[]])
          expect(SmarterJSON.process_one("[,]", acceleration: acceleration)).to eq([])
          expect(SmarterJSON.process("[,,,]", acceleration: acceleration)).to eq([[]])
          expect(SmarterJSON.process_one("[,,,]", acceleration: acceleration)).to eq([])
          expect(SmarterJSON.process("[,1]", acceleration: acceleration)).to eq([[1]])
          expect(SmarterJSON.process_one("[,1]", acceleration: acceleration)).to eq([1])
          expect(SmarterJSON.process("[1,]", acceleration: acceleration)).to eq([[1]])
          expect(SmarterJSON.process_one("[1,]", acceleration: acceleration)).to eq([1])
          expect(SmarterJSON.process("[1,2,]", acceleration: acceleration)).to eq([[1, 2]])
          expect(SmarterJSON.process_one("[1,2,]", acceleration: acceleration)).to eq([1, 2])
          expect(SmarterJSON.process("[1,,2]", acceleration: acceleration)).to eq([[1, 2]])
          expect(SmarterJSON.process_one("[1,,2]", acceleration: acceleration)).to eq([1, 2])
          expect(SmarterJSON.process("[,1,,2,]", acceleration: acceleration)).to eq([[1, 2]])
          expect(SmarterJSON.process_one("[,1,,2,]", acceleration: acceleration)).to eq([1, 2])
        end

        it "keeps an explicit null as a value (only truly empty slots are skipped)" do
          expect(SmarterJSON.process("[null]", acceleration: acceleration)).to eq([[nil]])
          expect(SmarterJSON.process_one("[null]", acceleration: acceleration)).to eq([nil])
          expect(SmarterJSON.process("[1,null,2]", acceleration: acceleration)).to eq([[1, nil, 2]])
          expect(SmarterJSON.process_one("[1,null,2]", acceleration: acceleration)).to eq([1, nil, 2])
        end

        it "skips empty object members from leading / interior / trailing commas" do
          expect(SmarterJSON.process("{}", acceleration: acceleration)).to eq([{}])
          expect(SmarterJSON.process_one("{}", acceleration: acceleration)).to eq({})
          expect(SmarterJSON.process('{,"a":1}', acceleration: acceleration)).to eq([{ "a" => 1 }])
          expect(SmarterJSON.process_one('{,"a":1}', acceleration: acceleration)).to eq({ "a" => 1 })
          expect(SmarterJSON.process('{"a":1,,"b":2}', acceleration: acceleration)).to eq([{ "a" => 1, "b" => 2 }])
          expect(SmarterJSON.process_one('{"a":1,,"b":2}', acceleration: acceleration)).to eq({ "a" => 1, "b" => 2 })
          expect(SmarterJSON.process('{"a":1,}', acceleration: acceleration)).to eq([{ "a" => 1 }])
          expect(SmarterJSON.process_one('{"a":1,}', acceleration: acceleration)).to eq({ "a" => 1 })
        end

        # A key WITH a colon but no value is different from an empty comma-slot: the key
        # is present, so the value is null (not "" and not skipped).
        it "interprets an empty hash value (key, colon, no value) as null" do
          expect(SmarterJSON.process("{a:}", acceleration: acceleration)).to eq([{ "a" => nil }])
          expect(SmarterJSON.process_one("{a:}", acceleration: acceleration)).to eq({ "a" => nil })
          expect(SmarterJSON.process('{"a":}', acceleration: acceleration)).to eq([{ "a" => nil }])
          expect(SmarterJSON.process_one('{"a":}', acceleration: acceleration)).to eq({ "a" => nil })
          expect(SmarterJSON.process("{a:,b:2}", acceleration: acceleration)).to eq([{ "a" => nil, "b" => 2 }])
          expect(SmarterJSON.process_one("{a:,b:2}", acceleration: acceleration)).to eq({ "a" => nil, "b" => 2 })
          expect(SmarterJSON.process('{"":}', acceleration: acceleration)).to eq([{ "" => nil }])
          expect(SmarterJSON.process_one('{"":}', acceleration: acceleration)).to eq({ "" => nil })
        end

        it "raises 'invalid number' on a lone sign with no digits" do
          expect { SmarterJSON.process("-", acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
          expect { SmarterJSON.process_one("-", acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
          expect { SmarterJSON.process("+", acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
          expect { SmarterJSON.process_one("+", acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
        end

        it "parses a hex number with lowercase a-f digits" do
          expect(SmarterJSON.process("0xabc", acceleration: acceleration)).to eq([0xabc])
          expect(SmarterJSON.process_one("0xabc", acceleration: acceleration)).to eq(0xabc)
        end

        # Regression (found by fuzzing): a token that is an exponent with no mantissa
        # digit (e.g. "-e695881", "e399855") is NOT a number — it's a quoteless string.
        # The Ruby path used to read it as 0.0 because DEC_RE made the mantissa optional.
        it "treats a mantissa-less exponent token as a quoteless string, not 0.0" do
          expect(SmarterJSON.process("[-e695881]", acceleration: acceleration)).to eq([["-e695881"]])
          expect(SmarterJSON.process_one("[-e695881]", acceleration: acceleration)).to eq(["-e695881"])
          expect(SmarterJSON.process("[e399855]", acceleration: acceleration)).to eq([["e399855"]])
          expect(SmarterJSON.process_one("[e399855]", acceleration: acceleration)).to eq(["e399855"])
        end

        it "still parses valid numbers with exponents and leading/trailing dots" do
          expect(SmarterJSON.process("[1e5]", acceleration: acceleration)).to eq([[1e5]])
          expect(SmarterJSON.process_one("[1e5]", acceleration: acceleration)).to eq([1e5])
          expect(SmarterJSON.process("[.5]", acceleration: acceleration)).to eq([[0.5]])
          expect(SmarterJSON.process_one("[.5]", acceleration: acceleration)).to eq([0.5])
          expect(SmarterJSON.process("[5.]", acceleration: acceleration)).to eq([[5.0]])
          expect(SmarterJSON.process_one("[5.]", acceleration: acceleration)).to eq([5.0])
          expect(SmarterJSON.process("[-1.5e-3]", acceleration: acceleration)).to eq([[-1.5e-3]])
          expect(SmarterJSON.process_one("[-1.5e-3]", acceleration: acceleration)).to eq([-1.5e-3])
          expect(SmarterJSON.process("[.5e3]", acceleration: acceleration)).to eq([[500.0]])
          expect(SmarterJSON.process_one("[.5e3]", acceleration: acceleration)).to eq([500.0])
        end

        it "raises 'unexpected character' on a non-printable control byte" do
          expect { SmarterJSON.process("\x07", acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
          expect { SmarterJSON.process_one("\x07", acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
        end
      end

      # ============================================================
      # Fixture-based integration tests
      # ============================================================

      describe "fixture-based integration" do
        it "parses comments_test.hjson with all comment styles and string values" do
          result = SmarterJSON.process_file(File.join(fixtures_dir, "comments_test.hjson"), acceleration: acceleration).first # single-document fixture
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
          expect(result["str1"]).to eq("00")                        # bare leading zero -> string (same case as an account number)
          expect(result["str2"]).to eq(0.0)                         # leading zero + dot -> number
          expect(result["str3"]).to eq("02")                        # bare leading zero -> string (same case as an account number)
        end

        it "parses strings_test.hjson and recognizes string-vs-literal distinction" do
          result = SmarterJSON.process_file(File.join(fixtures_dir, "strings_test.hjson"), acceleration: acceleration).first # single-document fixture
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
          result = SmarterJSON.process_file(File.join(fixtures_dir, "oa_test.hjson"), acceleration: acceleration).first # single-document fixture
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
          result = SmarterJSON.process_file(File.join(fixtures_dir, "root_test.hjson"), acceleration: acceleration).first # single-document fixture
          expect(result).to eq({ "database" => { "host" => "127.0.0.1", "port" => 555 } })
        end

        it "parses kan_test.hjson (mixed number/literal/string contexts)" do
          result = SmarterJSON.process_file(File.join(fixtures_dir, "kan_test.hjson"), acceleration: acceleration).first # single-document fixture
          # numbers context: recognized numbers (commas optional)
          expect(result["numbers"]).to eq([0, 0, -0, 42, 42.1, -5, -5.1, 1701.0, -1701.0, 12.345, -12.345])
          # native context: true/false/null
          expect(result["native"]).to eq([true, true, false, false, nil, nil])
          # strings context: quoteless strings (each whole-line value).
          expect(result["strings"]).to be_a(Array)
          expect(result["strings"]).to include("x 0", "00", "01", "0 0 0", "42 x", "42.1 asdf", "1.2.3",
                                               "true true", "false false", "null null", "x null")
          # DIVERGENCE from HJSON: smarter_json adds JSON5's leading-decimal-point rule,
          # so `.0` is the number 0.0 (recognized literals win), not the string ".0".
          expect(result["strings"][1]).to eq(0.0)
        end

        it "parses empty_test.hjson with empty-string key" do
          result = SmarterJSON.process_file(File.join(fixtures_dir, "empty_test.hjson"), acceleration: acceleration).first # single-document fixture
          expect(result).to eq({ "" => "empty" })
        end

        it "parses json_fail10.json (object + trailing value) as two documents → Array" do
          input = File.read(File.join(fixtures_dir, "json_fail10.json"))
          # smarter_json is lenient: two valid top-level values (an object, then a
          # string) parse as a 2-element Array with no block needed — no data is
          # dropped. (Strict JSON rejects this; smarter_json does not.)
          expect(SmarterJSON.process(input, acceleration: acceleration)).to eq([{ "Extra value after close" => true }, "misplaced quoted value"])
        end

        it "recovers both values from json_fail10.json via the block form" do
          input = File.read(File.join(fixtures_dir, "json_fail10.json"))
          result = []
          SmarterJSON.process(input, acceleration: acceleration) { |v| result << v }
          expect(result).to eq([{ "Extra value after close" => true }, "misplaced quoted value"])
        end

        it "raises ParseError on oj_fail2.json (unclosed array)" do
          input = File.read(File.join(fixtures_dir, "oj_fail2.json"))
          expect { SmarterJSON.process(input, acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError)
        end

        it "parses oj_pass1.json (similar to json_pass1, with numeric overflow)" do
          result = SmarterJSON.process_file(File.join(fixtures_dir, "oj_pass1.json"), acceleration: acceleration).first # single-document fixture (a top-level array)
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
          expect(SmarterJSON.process(%("a\tb"), acceleration: acceleration)).to eq(["a\tb"])
          expect(SmarterJSON.process_one(%("a\tb"), acceleration: acceleration)).to eq("a\tb")
        end

        it "keeps a raw newline byte literally inside a double-quoted string" do
          expect(SmarterJSON.process(%("a\nb"), acceleration: acceleration)).to eq(["a\nb"])
          expect(SmarterJSON.process_one(%("a\nb"), acceleration: acceleration)).to eq("a\nb")
        end

        it 'processes \\n escape inside a single-quoted string (same as double-quoted)' do
          expect(SmarterJSON.process("'a\\nb'", acceleration: acceleration)).to eq(["a\nb"])
          # Ruby source "'a\\nb'" is the 5 chars  ' a \ n b ' → parser turns \n into a newline
          expect(SmarterJSON.process_one("'a\\nb'", acceleration: acceleration)).to eq("a\nb")
        end

        it 'processes \\t escape inside a single-quoted string' do
          expect(SmarterJSON.process("'a\\tb'", acceleration: acceleration)).to eq(["a\tb"])
          expect(SmarterJSON.process_one("'a\\tb'", acceleration: acceleration)).to eq("a\tb")
        end
      end

      # ============================================================
      # Options (§5 API)
      # ============================================================

      describe "options" do
        describe "symbolize_keys" do
          it "returns symbol keys when symbolize_keys: true" do
            expect(SmarterJSON.process('{"a": 1, "b": 2}', symbolize_keys: true, acceleration: acceleration)).to eq([{ a: 1, b: 2 }])
            expect(SmarterJSON.process_one('{"a": 1, "b": 2}', symbolize_keys: true, acceleration: acceleration)).to eq({ a: 1, b: 2 })
          end

          it "symbolizes nested object keys" do
            expect(SmarterJSON.process('{"outer": {"inner": 1}}', symbolize_keys: true, acceleration: acceleration)).to eq([{ outer: { inner: 1 } }])
            expect(SmarterJSON.process_one('{"outer": {"inner": 1}}', symbolize_keys: true, acceleration: acceleration)).to eq({ outer: { inner: 1 } })
          end

          it "defaults to string keys" do
            expect(SmarterJSON.process('{"a": 1}', acceleration: acceleration)).to eq([{ "a" => 1 }])
            expect(SmarterJSON.process_one('{"a": 1}', acceleration: acceleration)).to eq({ "a" => 1 })
          end
        end

        describe "deep nesting" do
          it "parses deeply nested input without stack overflow (iterative parser, both paths)" do
            deep = ("[" * 1000) + ("]" * 1000)
            result = SmarterJSON.process_one(deep, acceleration: acceleration)
            expect(result).to be_a(Array)
            expect(SmarterJSON.process(deep, acceleration: acceleration).first).to be_a(Array)
          end
        end

        describe "duplicate_key" do
          it "last value wins by default" do
            expect(SmarterJSON.process('{"a": 1, "a": 2}', acceleration: acceleration).first["a"]).to eq(2)
            expect(SmarterJSON.process_one('{"a": 1, "a": 2}', acceleration: acceleration)["a"]).to eq(2)
          end

          it "first value wins with duplicate_key: :first_wins" do
            expect(SmarterJSON.process('{"a": 1, "a": 2}', duplicate_key: :first_wins, acceleration: acceleration).first["a"]).to eq(1)
            expect(SmarterJSON.process_one('{"a": 1, "a": 2}', duplicate_key: :first_wins, acceleration: acceleration)["a"]).to eq(1)
          end
        end

        describe "decimal_precision (Oj-compatible; default :auto)" do
          it "loads a >16-significant-digit decimal as BigDecimal by default (:auto)" do
            expect(SmarterJSON.process("0.12345678901234567", acceleration: acceleration)).to eql([BigDecimal("0.12345678901234567")])
            expect(SmarterJSON.process_one("0.12345678901234567", acceleration: acceleration)).to eql(BigDecimal("0.12345678901234567"))
          end

          it "keeps a 16-significant-digit decimal as Float (:auto)" do
            expect(SmarterJSON.process("0.1234567890123456", acceleration: acceleration)).to eql([0.1234567890123456])
            expect(SmarterJSON.process_one("0.1234567890123456", acceleration: acceleration)).to eql(0.1234567890123456)
          end

          it "keeps a 20-digit integer as Integer, never BigDecimal (:auto)" do
            expect(SmarterJSON.process("12345678901234567890", acceleration: acceleration)).to eql([12_345_678_901_234_567_890])
            expect(SmarterJSON.process_one("12345678901234567890", acceleration: acceleration)).to eql(12_345_678_901_234_567_890)
          end

          it "forces Float with decimal_precision: :float even for high precision" do
            expect(SmarterJSON.process("0.12345678901234567", decimal_precision: :float, acceleration: acceleration).first).to be_a(Float)
            expect(SmarterJSON.process_one("0.12345678901234567", decimal_precision: :float, acceleration: acceleration)).to be_a(Float)
          end

          it "forces BigDecimal for any decimal with decimal_precision: :bigdecimal" do
            expect(SmarterJSON.process("3.14", decimal_precision: :bigdecimal, acceleration: acceleration)).to eql([BigDecimal("3.14")])
            expect(SmarterJSON.process_one("3.14", decimal_precision: :bigdecimal, acceleration: acceleration)).to eql(BigDecimal("3.14"))
          end

          it "applies in array/member position too" do
            result = SmarterJSON.process_one("[0.12345678901234567, 1.5]", acceleration: acceleration)
            expect(result[0]).to eql(BigDecimal("0.12345678901234567"))
            expect(result[1]).to eql(1.5)
            expect(SmarterJSON.process("[0.12345678901234567, 1.5]", acceleration: acceleration).first).to eql(result)
          end

          it "normalizes a trailing-dot decimal under :bigdecimal" do
            result = SmarterJSON.process_one("5.", decimal_precision: :bigdecimal, acceleration: acceleration)
            expect(result).to be_a(BigDecimal)
            expect(result).to eq(BigDecimal("5"))
            expect(SmarterJSON.process("5.", decimal_precision: :bigdecimal, acceleration: acceleration).first).to be_a(BigDecimal)
          end
        end

        describe "high-precision float fallback corners (guards the single-pass number scan)" do
          # These exercise the paths the Float converter falls back to strtod /
          # rb_cstr_to_dbl for: >18 mantissa digits, the subnormal range, extreme
          # exponents, and -0.0. The single-pass rewrite must extract identical
          # mantissa/exponent parts, so the resulting Float stays bit-identical to
          # Ruby's own String#to_f.

          it "matches String#to_f for a >18-significant-digit float (strtod fallback)" do
            s = "1.2345678901234567890" # 20 sig digits — beyond the 18-digit Eisel-Lemire fast path
            expect(SmarterJSON.process(s, decimal_precision: :float, acceleration: acceleration)).to eql([s.to_f])
            expect(SmarterJSON.process_one(s, decimal_precision: :float, acceleration: acceleration)).to eql(s.to_f)
          end

          it "matches String#to_f for a subnormal-range float" do
            s = "1e-310" # mantissa_digits + exponent < -307 — subnormal fallback
            expect(SmarterJSON.process(s, acceleration: acceleration)).to eql([s.to_f])
            expect(SmarterJSON.process_one(s, acceleration: acceleration)).to eql(s.to_f)
          end

          it "returns Infinity for an extreme positive exponent" do
            expect(SmarterJSON.process("1e2000000", acceleration: acceleration)).to eql([Float::INFINITY])
            expect(SmarterJSON.process_one("1e2000000", acceleration: acceleration)).to eql(Float::INFINITY)
          end

          it "returns 0.0 for an extreme negative exponent" do
            expect(SmarterJSON.process("1e-2000000", acceleration: acceleration)).to eql([0.0])
            expect(SmarterJSON.process_one("1e-2000000", acceleration: acceleration)).to eql(0.0)
          end

          it "preserves negative zero (-0.0, distinct from 0.0)" do
            result = SmarterJSON.process_one("-0.0", acceleration: acceleration)
            expect(result).to eql(-0.0)
            expect(1.0 / result).to eql(-Float::INFINITY) # sign bit preserved
            expect(SmarterJSON.process("-0.0", acceleration: acceleration).first).to eql(-0.0)
          end

          it "matches String#to_f for a >18-digit float carrying underscores" do
            s = "1.234_567_890_123_456_789" # underscores + >18 digits — strip then strtod fallback
            expect(SmarterJSON.process(s, decimal_precision: :float, acceleration: acceleration)).to eql([s.delete("_").to_f])
            expect(SmarterJSON.process_one(s, decimal_precision: :float, acceleration: acceleration)).to eql(s.delete("_").to_f)
          end
        end
      end

      # ============================================================
      # Whitespace semantics (Rails String#blank? / [[:space:]])
      # ============================================================

      describe "whitespace semantics ([[:space:]], same as Rails blank?)" do
        it "treats vertical tab (0x0B) as whitespace between tokens" do
          expect(SmarterJSON.process("[1,\x0B2,\x0B3]", acceleration: acceleration)).to eq([[1, 2, 3]])
          expect(SmarterJSON.process_one("[1,\x0B2,\x0B3]", acceleration: acceleration)).to eq([1, 2, 3])
        end

        it "treats form feed (0x0C) as whitespace between tokens" do
          expect(SmarterJSON.process("[1,\x0C2,\x0C3]", acceleration: acceleration)).to eq([[1, 2, 3]])
          expect(SmarterJSON.process_one("[1,\x0C2,\x0C3]", acceleration: acceleration)).to eq([1, 2, 3])
        end

        it "treats NBSP (U+00A0) as whitespace between tokens" do
          expect(SmarterJSON.process("[ 1 , 2]", acceleration: acceleration)).to eq([[1, 2]])
          expect(SmarterJSON.process_one("[\u00A01\u00A0,\u00A02]", acceleration: acceleration)).to eq([1, 2])
        end

        it "trims NBSP (U+00A0) around a quoteless value" do
          expect(SmarterJSON.process("x: value ", acceleration: acceleration)).to eq([{ "x" => "value" }])
          expect(SmarterJSON.process_one("x:\u00A0value\u00A0", acceleration: acceleration)).to eq({ "x" => "value" })
        end
      end

      # ============================================================
      # Encoding errors (§3.1)
      # ============================================================

      describe "encoding errors" do
        it "raises SmarterJSON::EncodingError on bytes invalid for the claimed encoding" do
          expect { SmarterJSON.process("\"bad\xFF byte\"".b.force_encoding("UTF-8"), acceleration: acceleration) }.to raise_error(SmarterJSON::EncodingError)
          input = "\"bad\xFF byte\"".b.force_encoding("UTF-8") # 0xFF is not valid UTF-8
          expect { SmarterJSON.process_one(input, acceleration: acceleration) }.to raise_error(SmarterJSON::EncodingError)
        end

        it "SmarterJSON::EncodingError is a kind of ParseError" do
          expect(SmarterJSON::EncodingError.ancestors).to include(SmarterJSON::ParseError)
        end
      end

      # ============================================================
      # Out of scope — values returned as-is
      # ============================================================

      describe "out-of-scope values stay strings" do
        it "leaves a date string as a String (§3 row 22)" do
          expect(SmarterJSON.process('"2025-01-31"', acceleration: acceleration)).to eq(["2025-01-31"])
          expect(SmarterJSON.process_one('"2025-01-31"', acceleration: acceleration)).to eq("2025-01-31")
        end
      end
    end
  end

  # Ruby-path only: force scan_string_delimiter's getbyte-loop fallback (the portable
  # path for JRuby / TruffleRuby / MRI < 3.2, where String#byteindex is absent) by
  # stubbing BYTEINDEX_AVAILABLE, and prove it parses byte-identically to the byteindex
  # fast path. Covers parser.rb's scan_string_delimiter else-branch.
  describe "portable string scan fallback (no String#byteindex)" do
    let(:strings) { '["ab", "c\nd", "", "café", "x\"y", "a\\\\b"]' }

    it "parses byte-identically to the byteindex path" do
      fast = SmarterJSON.process(strings, acceleration: false)
      stub_const("SmarterJSON::Parser::BYTEINDEX_AVAILABLE", false)
      portable = SmarterJSON.process(strings, acceleration: false)
      expect(portable).to eq(fast)
    end

    it "still raises on an unterminated string (the nil-return branch)" do
      stub_const("SmarterJSON::Parser::BYTEINDEX_AVAILABLE", false)
      expect { SmarterJSON.process('["ab', acceleration: false) }.to raise_error(SmarterJSON::ParseError)
    end
  end
end
