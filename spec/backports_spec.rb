# frozen_string_literal: true

require "smarter_json/backports"

# Activate the refinement in THIS file regardless of Ruby version. The production
# `using` in parser.rb is guarded to Ruby < 2.7 (so on 2.7+ the native filter_map is
# used and the backport never runs) — which would otherwise leave the backport body
# uncovered on a modern Ruby. Activating it here exercises it on every Ruby, so the
# behavior is verified and the lines are covered. Refinements are lexically scoped, so
# this only affects this spec file.
using SmarterJSON::Backports

RSpec.describe SmarterJSON::Backports do
  describe "Array#filter_map backport" do
    it "maps each element and drops falsy results" do
      expect([1, 2, 3, 4, 5].filter_map { |n| n * 10 if n.even? }).to eq([20, 40])
    end

    it "keeps truthy values and drops nil and false" do
      expect([1, nil, 2, false, 3, nil].filter_map { |x| x }).to eq([1, 2, 3])
    end

    it "returns an Enumerator when called without a block" do
      # Just calling filter_map with no block runs the `return enum_for(:filter_map)`
      # line (what we need to cover). We don't iterate the Enumerator: its internal
      # re-dispatch of :filter_map happens outside this file's lexical scope, where the
      # refinement isn't active — so iterating would (correctly) not find the refined method.
      expect([1, 2, 3, 4].filter_map).to be_a(Enumerator)
    end

    it "returns an empty array for an empty receiver" do
      expect([].filter_map { |x| x }).to eq([])
    end

    it "matches native Array#filter_map behavior" do
      input = [0, 1, 2, "", "x", nil]
      # native result computed without the refinement (Array.instance_method dispatch)
      native = input.each_with_object([]) do |e, acc|
        v = (e.to_s.empty? ? nil : e)
        acc << v if v
      end
      expect(input.filter_map { |e| e.to_s.empty? ? nil : e }).to eq(native)
    end
  end
end
