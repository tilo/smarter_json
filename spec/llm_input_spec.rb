# frozen_string_literal: true

require "smarter_json"
require "stringio"

RSpec.describe "LLM-style input recovery" do
  def collect
    warns = []
    [warns, ->(w) { warns << w }]
  end

  [true, false].each do |acceleration|
    context "acceleration: #{acceleration}" do
      describe "wrapper stripping / payload extraction" do
        it "strips markdown code fences automatically and emits a code_fence_stripped warning" do
          warns, handler = collect
          input = <<~TEXT
            ```json
            {
              "name": "Tilo",
              "active": true
            }
            ```
          TEXT

          expect(SmarterJSON.process(input, acceleration: acceleration, on_warning: handler)).to eq({ "name" => "Tilo", "active" => true })
          expect(warns.map(&:type)).to eq([:code_fence_stripped])
        end

        it "strips bare markdown code fences too, even when the fence is not tagged as json" do
          warns, handler = collect
          input = <<~TEXT
            ```
            {
              "name": "Tilo",
              "active": true
            }
            ```
          TEXT

          expect(SmarterJSON.process(input, acceleration: acceleration, on_warning: handler)).to eq({ "name" => "Tilo", "active" => true })
          expect(warns.map(&:type)).to eq([:code_fence_stripped])
        end

        it "ignores chatty prefix prose before a plain payload and emits a prefix_text_ignored warning" do
          warns, handler = collect
          input = <<~TEXT
            Here is the JSON you requested:

            {
              "name": "Tilo",
              "score": 42
            }
          TEXT

          expect(SmarterJSON.process(input, acceleration: acceleration, on_warning: handler)).to eq({ "name" => "Tilo", "score" => 42 })
          expect(warns.map(&:type)).to eq([:prefix_text_ignored])
        end

        it "ignores explanatory suffix prose after a plain payload and emits a suffix_text_ignored warning" do
          warns, handler = collect
          input = <<~TEXT
            {
              "name": "Tilo",
              "active": true
            }

            This means the user is active.
          TEXT

          expect(SmarterJSON.process(input, acceleration: acceleration, on_warning: handler)).to eq({ "name" => "Tilo", "active" => true })
          expect(warns.map(&:type)).to eq([:suffix_text_ignored])
        end

        it "ignores chatty prefix and suffix prose around a fenced payload and emits specific warnings in order" do
          warns, handler = collect
          input = <<~TEXT
            Here is the fixed payload:

            ```json
            {
              "user": "tilo",
              "admin": false
            }
            ```

            Let me know if you want YAML instead.
          TEXT

          expect(SmarterJSON.process(input, acceleration: acceleration, on_warning: handler)).to eq({ "user" => "tilo", "admin" => false })
          expect(warns.map(&:type)).to eq(%i[prefix_text_ignored code_fence_stripped suffix_text_ignored])
          messages = [
            "ignored non-JSON text before the payload",
            "stripped markdown code fences around the payload",
            "ignored non-JSON text after the payload"
          ]
          expect(warns.map(&:message)).to eq(messages)
          expect(warns.map { |w| [w.line, w.col] }).to eq([[4, 1], [4, 1], [4, 1]])
        end

        it "extracts an inline payload after a same-line label like JSON: and ignores the label" do
          warns, handler = collect
          input = <<~TEXT
            JSON: {"a": 1, "b": 2}
          TEXT

          expect(SmarterJSON.process(input, acceleration: acceleration, on_warning: handler)).to eq({ "a" => 1, "b" => 2 })
          expect(warns.map(&:type)).to eq([:prefix_text_ignored])
        end

        it "extracts an inline payload after prose like Final answer: and ignores the prefix" do
          warns, handler = collect
          input = <<~TEXT
            Final answer: {foo: 1, bar: 2}
          TEXT

          expect(SmarterJSON.process(input, acceleration: acceleration, on_warning: handler)).to eq({ "foo" => 1, "bar" => 2 })
          expect(warns.map(&:type)).to eq([:prefix_text_ignored])
        end

        it "extracts the JSON payload from XML-ish wrapper tags and emits a wrapper_tag_stripped warning" do
          warns, handler = collect
          input = <<~TEXT
            <json>
            {
              "id": 123
            }
            </json>
          TEXT

          expect(SmarterJSON.process(input, acceleration: acceleration, on_warning: handler)).to eq({ "id" => 123 })
          expect(warns.map(&:type)).to eq([:wrapper_tag_stripped])
        end

        it "extracts the payload from BEGIN_JSON / END_JSON wrappers too" do
          warns, handler = collect
          input = <<~TEXT
            BEGIN_JSON
            {
              "id": 123
            }
            END_JSON
          TEXT

          expect(SmarterJSON.process(input, acceleration: acceleration, on_warning: handler)).to eq({ "id" => 123 })
          expect(warns.map(&:type)).to eq([:wrapper_tag_stripped])
        end

        it "handles a realistic LLM blob with prose, code fences, JSON5-ish syntax, and trailing chatter" do
          warns, handler = collect
          input = <<~TEXT
            Sure — here is the result:

            ```json
            {
              user: "tilo",
              active: True,
              tags: ["a", "b",],
            }
            ```

            Hope this helps.
          TEXT

          expect(SmarterJSON.process(input, acceleration: acceleration, on_warning: handler)).to eq({
                                                                                                      "user" => "tilo",
                                                                                                      "active" => true,
                                                                                                      "tags" => ["a", "b"]
                                                                                                    })
          expect(warns.map(&:type)).to include(:prefix_text_ignored, :code_fence_stripped, :suffix_text_ignored)
        end

        it "returns all recovered payloads when prose surrounds multiple candidate payloads" do
          warns, handler = collect
          input = <<~TEXT
            The first attempt failed:
            {"ok": false, "reason": "timeout"}

            The corrected payload is:
            {"ok": true, "reason": null}
          TEXT

          expect(SmarterJSON.process(input, acceleration: acceleration, on_warning: handler)).to eq([
                                                                                                      { "ok" => false, "reason" => "timeout" },
                                                                                                      { "ok" => true, "reason" => nil }
                                                                                                    ])
          expect(warns.map(&:type)).to eq([:prefix_text_ignored])
          expect(warns.first.message).to eq("ignored non-JSON text before the payload")
          expect([warns.first.line, warns.first.col]).to eq([2, 1])
        end
      end

      describe "truncated input still raises" do
        it "raises on a truncated object" do
          input = <<~TEXT
            {
              "name": "Tilo",
              "items": [1, 2, 3],
              "meta": {
                "source": "llm"
              }
          TEXT

          expect { SmarterJSON.process(input, acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError, /unterminated|end of input/i)
        end

        it "raises on a truncated array" do
          input = <<~TEXT
            [
              {"id": 1},
              {"id": 2},
              {"id": 3},
          TEXT

          expect { SmarterJSON.process(input, acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError, /unterminated|end of input/i)
        end

        it "raises on a trailing incomplete key" do
          input = <<~TEXT
            {"a": 1, "b"
          TEXT

          expect { SmarterJSON.process(input, acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError, /expected ':'|unterminated|end of input/i)
        end

        it "raises on a trailing key whose colon is present but whose value never arrived" do
          input = <<~TEXT
            {"a": 1, "b":
          TEXT

          expect { SmarterJSON.process(input, acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError, /unterminated|end of input/i)
        end

        it "raises when truncation happens inside a nested object" do
          input = <<~TEXT
            {"a": 1, "b": {"c": 2, "d":
          TEXT

          expect { SmarterJSON.process(input, acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError, /unterminated|end of input/i)
        end

        it "raises on an incomplete trailing string value" do
          input = <<~TEXT
            {"a": 1, "b": "hel
          TEXT

          expect { SmarterJSON.process(input, acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError, /unterminated/i)
        end

        it "raises on an array with a trailing comma at EOF" do
          input = <<~TEXT
            [1, 2, 3,
          TEXT

          expect { SmarterJSON.process(input, acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError, /unterminated|end of input/i)
        end

        it "raises on an incomplete trailing string element from an array" do
          input = <<~TEXT
            [1, 2, "hel
          TEXT

          expect { SmarterJSON.process(input, acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError, /unterminated/i)
        end

        it "raises when an array tail is truncated inside a nested object" do
          input = <<~TEXT
            [{"id": 1}, {"id": 2
          TEXT

          expect { SmarterJSON.process(input, acceleration: acceleration) }.to raise_error(SmarterJSON::ParseError, /unterminated|end of input/i)
        end
      end

      describe "multi-line IO streaming recovery" do
        it "streams pretty-printed multi-line documents from IO instead of requiring NDJSON" do
          input = <<~TEXT
            {
              "id": 1,
              "name": "a"
            }

            {
              "id": 2,
              "name": "b"
            }
          TEXT

          docs = []
          rv = SmarterJSON.process(StringIO.new(input), acceleration: acceleration) { |doc| docs << doc }
          expect(docs).to eq([
                               { "id" => 1, "name" => "a" },
                               { "id" => 2, "name" => "b" }
                             ])
          expect(rv).to be_nil
        end

        it "streams pretty-printed multi-line documents with CRLF separators too" do
          input = "{\r\n  \"id\": 1,\r\n  \"name\": \"a\"\r\n}\r\n\r\n{\r\n  \"id\": 2,\r\n  \"name\": \"b\"\r\n}\r\n"

          docs = []
          rv = SmarterJSON.process(StringIO.new(input), acceleration: acceleration) { |doc| docs << doc }
          expect(docs).to eq([
                               { "id" => 1, "name" => "a" },
                               { "id" => 2, "name" => "b" }
                             ])
          expect(rv).to be_nil
        end

        it "streams pretty-printed documents with comment-only separators between them" do
          input = <<~TEXT
            {
              "id": 1,
              "name": "a"
            }

            # between docs
            // and another note

            {
              "id": 2,
              "name": "b"
            }
          TEXT

          docs = []
          rv = SmarterJSON.process(StringIO.new(input), acceleration: acceleration) { |doc| docs << doc }
          expect(docs).to eq([
                               { "id" => 1, "name" => "a" },
                               { "id" => 2, "name" => "b" }
                             ])
          expect(rv).to be_nil
        end

        it "streams top-level pretty-printed arrays as whole documents too" do
          input = <<~TEXT
            [
              1,
              2,
              3
            ]

            [
              4,
              5
            ]
          TEXT

          docs = []
          rv = SmarterJSON.process(StringIO.new(input), acceleration: acceleration) { |doc| docs << doc }
          expect(docs).to eq([
                               [1, 2, 3],
                               [4, 5]
                             ])
          expect(rv).to be_nil
        end

        it "streams a mix of pretty-printed multi-line and single-line documents" do
          input = <<~TEXT
            {
              "id": 1,
              "name": "a"
            }
            {"id": 2, "name": "b"}
            {
              "id": 3,
              "name": "c"
            }
          TEXT

          docs = []
          rv = SmarterJSON.process(StringIO.new(input), acceleration: acceleration) { |doc| docs << doc }
          expect(docs).to eq([
                               { "id" => 1, "name" => "a" },
                               { "id" => 2, "name" => "b" },
                               { "id" => 3, "name" => "c" }
                             ])
          expect(rv).to be_nil
        end
      end

      describe "framing markers split across chunk boundaries" do
        # The Framer reads the IO in fixed-size chunks and brackets documents with a
        # byte FSM. A multi-byte token (//, /*, ''') whose first byte lands on the last
        # byte of a chunk must still be recognized once the next chunk arrives — otherwise
        # a brace *inside* a comment/string gets miscounted and the document frames wrong.
        chunk = SmarterJSON::Framer::CHUNK_SIZE

        def stream(input, acceleration:)
          docs = []
          SmarterJSON.process(StringIO.new(input), acceleration: acceleration) { |d| docs << d }
          docs
        end

        it "recognizes a // comment (containing a brace) whose slashes straddle the boundary" do
          head = '{"a":1,'
          doc = head + (" " * (chunk - 1 - head.bytesize)) + "// } not real\n" + '"b":2}'
          expect(doc.index("//")).to eq(chunk - 1) # the two slashes sit on either side of the boundary
          expect(stream(doc + "\n", acceleration: acceleration)).to eq([{ "a" => 1, "b" => 2 }])
        end

        it "recognizes a /* */ comment (containing a brace) whose opening straddles the boundary" do
          head = '{"a":1,'
          doc = head + (" " * (chunk - 1 - head.bytesize)) + "/* } */" + '"b":2}'
          expect(doc.index("/*")).to eq(chunk - 1)
          expect(stream(doc + "\n", acceleration: acceleration)).to eq([{ "a" => 1, "b" => 2 }])
        end

        it "recognizes a /* */ comment (containing a brace) whose closing */ straddles the boundary" do
          prefix = '{"a":1, /* } '
          doc = prefix + (" " * (chunk - 1 - prefix.bytesize)) + "*/" + '"b":2}'
          expect(doc.index("*/")).to eq(chunk - 1)
          expect(stream(doc + "\n", acceleration: acceleration)).to eq([{ "a" => 1, "b" => 2 }])
        end

        it "recognizes a triple-quoted string (containing a brace) whose ''' straddles the boundary" do
          head = '{"a":'
          doc = head + (" " * (chunk - 2 - head.bytesize)) + "'''" + " } " + "'''" + ',"b":2}'
          expect(stream(doc + "\n", acceleration: acceleration)).to eq([{ "a" => " } ", "b" => 2 }])
        end

        it "frames a brace inside a double-quoted string that straddles the boundary" do
          head = '{"a":'
          doc = head + (" " * (chunk - 1 - head.bytesize)) + '"x}y"' + ',"b":2}'
          expect(stream(doc + "\n", acceleration: acceleration)).to eq([{ "a" => "x}y", "b" => 2 }])
        end

        it "streams a single document larger than one chunk" do
          big = "{" + (1..3000).map { |i| %("k#{i}":#{i}) }.join(",") + "}"
          expect(big.bytesize).to be > chunk
          docs = stream(big + "\n" + big, acceleration: acceleration)
          expect(docs.size).to eq(2)
          expect(docs.first.size).to eq(3000)
          expect(docs.first).to eq(docs.last)
        end
      end

      describe "wrapper warnings reflect actual stripping, not markers inside the payload" do
        it "does not emit code_fence_stripped when ``` appears only inside a string value of a complete payload" do
          warns, handler = collect
          expect(SmarterJSON.process('{"code":"```"}', acceleration: acceleration, on_warning: handler)).to eq({ "code" => "```" })
          expect(warns).to be_empty
        end

        it "does not emit wrapper_tag_stripped when <json> appears only inside a string value of a complete payload" do
          warns, handler = collect
          expect(SmarterJSON.process('{"note":"see <json> here"}', acceleration: acceleration, on_warning: handler)).to eq({ "note" => "see <json> here" })
          expect(warns).to be_empty
        end
      end
    end
  end
end
