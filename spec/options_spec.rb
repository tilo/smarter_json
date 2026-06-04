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

    it "ignores unknown keys — an unrecognized option simply has no effect" do
      expect { described_class.process_options(no_such_option: 42) }.not_to raise_error
    end
  end

  describe "validation" do
    it "accepts every valid value" do
      expect do
        described_class.process_options(
          decimal_precision: :float, duplicate_key: :first_wins,
          on_warning: ->(w) { w }, encoding: "UTF-8", symbolize_keys: true, acceleration: false
        )
      end.not_to raise_error
    end

    it "raises ArgumentError on an invalid decimal_precision" do
      expect { described_class.process_options(decimal_precision: :nope) }
        .to raise_error(ArgumentError, /decimal_precision must be :auto, :float, or :bigdecimal/)
    end

    it "raises ArgumentError on an invalid duplicate_key (including the removed :raise)" do
      expect { described_class.process_options(duplicate_key: :raise) }
        .to raise_error(ArgumentError, /duplicate_key must be :last_wins or :first_wins/)
    end

    it "raises ArgumentError when on_warning is not callable" do
      expect { described_class.process_options(on_warning: "nope") }
        .to raise_error(ArgumentError, /on_warning must be nil or a callable/)
    end

    it "raises ArgumentError when encoding is neither nil nor a String" do
      expect { described_class.process_options(encoding: 123) }
        .to raise_error(ArgumentError, /encoding must be nil or a String/)
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
