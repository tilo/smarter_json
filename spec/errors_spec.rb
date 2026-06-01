# frozen_string_literal: true

require "smarter_json"
require "bigdecimal"

RSpec.describe "SmarterJSON error hierarchy" do
  it "ParseError is a kind of SmarterJSON::Error" do
    expect(SmarterJSON::ParseError.ancestors).to include(SmarterJSON::Error)
  end

  it "EncodingError is a kind of ParseError (and so a SmarterJSON::Error)" do
    expect(SmarterJSON::EncodingError.ancestors).to include(SmarterJSON::ParseError, SmarterJSON::Error)
  end

  it "GenerateError is a kind of SmarterJSON::Error" do
    expect(SmarterJSON::GenerateError.ancestors).to include(SmarterJSON::Error)
  end

  describe "rescuing SmarterJSON::Error catches everything the gem raises" do
    [true, false].each do |acceleration|
      it "catches a parse failure (acceleration: #{acceleration})" do
        expect { SmarterJSON.process('"unterminated', acceleration: acceleration) }.to raise_error(SmarterJSON::Error)
      end
    end

    it "catches a generate failure (unsupported type)" do
      expect { SmarterJSON.generate(Object.new) }.to raise_error(SmarterJSON::Error)
    end
  end

  describe "generate raises GenerateError specifically" do
    it "for an unsupported type" do
      expect { SmarterJSON.generate(Object.new) }.to raise_error(SmarterJSON::GenerateError)
    end

    it "for a non-finite Float" do
      expect { SmarterJSON.generate(Float::INFINITY) }.to raise_error(SmarterJSON::GenerateError)
      expect { SmarterJSON.generate(Float::NAN) }.to raise_error(SmarterJSON::GenerateError)
    end

    it "for a non-finite BigDecimal" do
      expect { SmarterJSON.generate(BigDecimal("Infinity")) }.to raise_error(SmarterJSON::GenerateError)
    end
  end
end
