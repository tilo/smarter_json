# frozen_string_literal: true

require "smarter_json"

RSpec.describe SmarterJSON::Options do
  describe ".process_options" do
    it "fills in the defaults for keys the caller did not provide" do
      opts = described_class.process_options(symbolize_keys: true)
      expect(opts[:symbolize_keys]).to be(true)
      expect(opts[:decimal_precision]).to eq(:auto)
      expect(opts[:duplicate_key]).to eq(:last_wins)
      expect(opts[:acceleration]).to be(true)
    end

    it "returns the defaults unchanged when given nothing" do
      expect(described_class.process_options).to eq(SmarterJSON::Options::DEFAULT_OPTIONS)
    end

    it "raises ArgumentError on an unknown option key — fail early so a typo is caught" do
      expect { described_class.process_options(no_such_option: 42) }
        .to raise_error(ArgumentError, /unknown option.*no_such_option/i)
    end

    it "names every unknown key when several are passed" do
      expect { described_class.process_options(foo: 1, bar: 2) }
        .to raise_error(ArgumentError, /foo.*bar|bar.*foo/m)
    end

    it "rejects a near-miss of a real option (symbolize_names instead of symbolize_keys)" do
      expect { described_class.process_options(symbolize_names: true) }
        .to raise_error(ArgumentError, /unknown option.*symbolize_names/i)
    end
  end

  describe "value validation (every option, valid and invalid)" do
    # One source of truth for the whole option/value matrix. Each option lists
    # values that must be ACCEPTED and values that must be REJECTED. For the
    # open-ended options (encoding accepts any String, on_warning any callable)
    # the valid samples are representative, not exhaustive.
    option_cases = {
      acceleration: { valid: [true, false], invalid: ["yes", 1, nil] },
      symbolize_keys: { valid: [true, false], invalid: ["yes", 0, nil] },
      decimal_precision: { valid: %i[auto float bigdecimal], invalid: [:nope, "auto", 1, nil] },
      duplicate_key: { valid: %i[last_wins first_wins], invalid: [:raise, "last_wins", nil] },
      encoding: { valid: [nil, "UTF-8", "ASCII-8BIT"], invalid: [123, :utf8] },
      on_warning: { valid: [nil, ->(w) { w }], invalid: ["nope", 42] },
      replace_char: { valid: ["?", "", "_", "??"], invalid: [nil, 1, :q] },
    }
    label = ->(v) { v.is_a?(Proc) ? "a callable" : v.inspect }

    it "the case table covers every known option (no option escapes the matrix)" do
      expect(option_cases.keys).to match_array(SmarterJSON::Options::DEFAULT_OPTIONS.keys)
    end

    option_cases.each do |key, cases|
      cases[:valid].each do |value|
        it "accepts #{key}: #{label.call(value)}" do
          expect { described_class.process_options(key => value) }.not_to raise_error
        end
      end

      cases[:invalid].each do |value|
        it "rejects #{key}: #{label.call(value)}" do
          expect { described_class.process_options(key => value) }
            .to raise_error(ArgumentError, /#{key}/)
        end
      end
    end

    it "reports multiple problems in one error" do
      expect { described_class.process_options(decimal_precision: :x, duplicate_key: :y) }
        .to raise_error(ArgumentError, /decimal_precision must be.*duplicate_key must be/m)
    end
  end

  it "is wired into SmarterJSON.process — bad options raise at the entry point" do
    expect { SmarterJSON.process("{}", decimal_precision: :bogus) }.to raise_error(ArgumentError)
  end
end
