# frozen_string_literal: true

require "smarter_json"

# Every lenient fix must report the SAME SmarterJSON::Warning (type, message, line,
# col) on the C extension and on the pure-Ruby parser. Most warnings already do,
# because they are emitted from shared Ruby code (the Recovery layer and the number
# path); empty_slot / empty_value / duplicate_key have SEPARATE emission sites in the
# C extension and in the Ruby parser, which is where message/column drift crept in.
#
# The pure-Ruby parser is the contract: it names the offending key, names the
# duplicate-key resolution strategy, and reports the line/col of the duplicate
# member's value. The C extension is brought up to match. (— is an em dash; the save hook keeps
# the spec ASCII, so the expected strings use the escape, which equals the parser's
# real em dash at run time.)
RSpec.describe SmarterJSON, "warning parity (C and Ruby emit identical warnings)" do
  def first_warning(input, **opts)
    seen = nil
    SmarterJSON.process(input, on_warning: ->(w) { seen ||= w }, **opts)
    seen
  end

  [true, false].each do |acceleration|
    context "acceleration: #{acceleration}" do
      it "empty_slot — names nothing, em dash, col at the extra comma" do
        w = first_warning("[1,,2]", acceleration: acceleration)
        expect([w.type, w.message, w.line, w.col])
          .to eq([:empty_slot, "extra comma — collapsed an empty slot", 1, 4])
      end

      it "empty_value — names the key" do
        w = first_warning('{"x":}', acceleration: acceleration)
        expect([w.type, w.message, w.line, w.col])
          .to eq([:empty_value, "key \"x\" had no value — used null", 1, 6])
      end

      it "duplicate_key — names the key and strategy (last_wins), col at the duplicate value" do
        w = first_warning('{"a":1,"a":2}', acceleration: acceleration)
        expect([w.type, w.message, w.line, w.col])
          .to eq([:duplicate_key, "duplicate key \"a\" — last_wins", 1, 13])
      end

      it "duplicate_key — names the first_wins strategy" do
        w = first_warning('{"a":1,"a":2}', duplicate_key: :first_wins, acceleration: acceleration)
        expect(w.message).to eq("duplicate key \"a\" — first_wins")
      end

      it "duplicate_key — inspects a symbolized key" do
        w = first_warning('{"a":1,"a":2}', symbolize_keys: true, acceleration: acceleration)
        expect(w.message).to eq("duplicate key :a — last_wins")
      end

      it "duplicate_key — multiline: line/col track the duplicate member's value, not the brace" do
        w = first_warning(%({\n  "a": 1,\n  "a": 2\n}), acceleration: acceleration)
        expect([w.type, w.message, w.line, w.col])
          .to eq([:duplicate_key, "duplicate key \"a\" — last_wins", 3, 9])
      end

      it "duplicate_key — nested object, col tracks the inner duplicate" do
        w = first_warning(%({\n  "outer": {\n    "k": 1,\n    "k": 2\n  }\n}), acceleration: acceleration)
        expect([w.line, w.col]).to eq([4, 11])
      end

      it "duplicate_key — trailing whitespace after the value is included, matching Ruby" do
        w = first_warning(%({\n  "a": 1,\n  "a": 2  \n}), acceleration: acceleration)
        expect([w.line, w.col]).to eq([3, 11])
      end
    end
  end

  # Belt-and-suspenders: for every warning type, the C path and the Ruby path must
  # produce a byte-identical Warning. This is the coverage that was missing — it would
  # have caught the message/column drift immediately, and locks all paths going forward.
  describe "every warning type is identical on the C and Ruby paths" do
    {
      "empty_slot (array)" => [:process, "[1,,2]"],
      "empty_slot (object)" => [:process, '{"a":1,,"b":2}'],
      "empty_value" => [:process, '{"x":}'],
      "duplicate_key" => [:process, '{"a":1,"a":2}'],
      "duplicate_key (multiline)" => [:process, "{\n  \"a\": 1,\n  \"a\": 2\n}"],
      "number_overflow" => [:process, "1e400"],
      "code_fence_stripped" => [:process, "```json\n{\"a\":1}\n```"],
      "prefix_text_ignored" => [:process, 'Here is the json: {"a":1}'],
      "suffix_text_ignored" => [:process, '{"a":1} thanks!'],
      "wrapper_tag_stripped" => [:process, "<json>{\"a\":1}</json>"],
      "extra_documents" => [:process_one, "{\"a\":1}\n{\"b\":2}"],
    }.each do |label, (meth, input)|
      it "#{label}: same (type, message, line, col) with and without the C extension" do
        tuple = lambda do |accel|
          w = nil
          SmarterJSON.public_send(meth, input, acceleration: accel, on_warning: ->(x) { w ||= x })
          [w.type, w.message, w.line, w.col]
        end
        expect(tuple.call(true)).to eq(tuple.call(false))
      end
    end
  end
end
