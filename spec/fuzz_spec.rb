# frozen_string_literal: true

require "smarter_json"
require "json"

# Property / fuzz tests: throw generated, mutated, and random input at the parser and
# assert the invariants that must ALWAYS hold, no matter the input —
#   * the C path and the pure-Ruby path agree (same value, or both raise ParseError);
#   * every valid JSON parses to the same value as the stdlib `json` gem;
#   * a round-trip through `generate` is stable;
#   * nothing crashes, hangs, or raises anything other than SmarterJSON::ParseError.
#
# Reproducible: the seed is printed in each example name and failure message. Replay a
# run (or hunt deeper) with `FUZZ_SEED=<n> FUZZ_ITER=<n> bundle exec rspec spec/fuzz_spec.rb`.
RSpec.describe "fuzz / property tests" do
  seed = Integer(ENV.fetch("FUZZ_SEED", "20260601")) # fixed default → deterministic CI
  iter = Integer(ENV.fetch("FUZZ_ITER", "1000"))

  # Parse on one path. Returns :error for a clean ParseError, or [:ok, value] otherwise.
  # Anything else (a crash, a hang, a non-ParseError exception) escapes and fails loudly.
  def outcome(input, acceleration)
    [:ok, SmarterJSON.process(input, acceleration: acceleration, decimal_precision: :float)]
  rescue SmarterJSON::ParseError
    :error
  end

  # Like outcome, but with an on_warning: collector — captures [result, warning-type
  # sequence]. (Compares warning *types*/order, not line/col, since dup-key positions
  # legitimately differ between paths.) Also exercises the C per-member object-build
  # path, which only runs when a handler is present.
  def warned_outcome(input, acceleration)
    types = []
    result = SmarterJSON.process(input, acceleration: acceleration, decimal_precision: :float,
                                        on_warning: ->(w) { types << w.type })
    [:ok, result, types]
  rescue SmarterJSON::ParseError
    :error
  end

  def random_string(rng)
    Array.new(rng.rand(0..8)) do
      cp = rng.rand(0x00..0x2fff)             # include control chars (force escaping) + multibyte
      (0xd800..0xdfff).cover?(cp) ? 0x20 : cp # skip the UTF-16 surrogate range (not scalar values)
    end.pack("U*")
  end

  def random_value(rng, depth = 0)
    if depth >= 4 || (depth.positive? && rng.rand < 0.35)
      case rng.rand(6)
      when 0 then rng.rand(-1_000_000..1_000_000)
      when 1 then (rng.rand * 2 - 1) * (10.0**rng.rand(-6..6))
      when 2 then random_string(rng)
      when 3 then true
      when 4 then false
      end # else -> nil
    elsif rng.rand < 0.5
      Array.new(rng.rand(0..5)) { random_value(rng, depth + 1) }
    else
      Array.new(rng.rand(0..5)).each_with_object({}) { |_, h| h[random_string(rng)] = random_value(rng, depth + 1) }
    end
  end

  def mutate(rng, json)
    bytes = json.bytes
    rng.rand(1..3).times do
      next if bytes.empty?

      i = rng.rand(bytes.size)
      case rng.rand(3)
      when 0 then bytes[i] = rng.rand(0x20..0x7e) # flip
      when 1 then bytes.insert(i, rng.rand(0x20..0x7e)) # insert
      else bytes.delete_at(i) # delete
      end
    end
    bytes.pack("C*").force_encoding("UTF-8")
  end

  it "parses valid JSON the same as stdlib json, on both paths (seed=#{seed})" do
    rng = Random.new(seed)
    iter.times do
      json = JSON.generate(random_value(rng))
      ref  = JSON.parse(json)
      [true, false].each do |accel|
        got = SmarterJSON.process(json, acceleration: accel, decimal_precision: :float)
        expect(got).to(eq(ref), "mismatch (accel=#{accel}) for #{json.inspect}\n got: #{got.inspect}\n ref: #{ref.inspect}\n seed=#{seed}")
      end
    end
  end

  it "C and Ruby paths agree on random ASCII garbage (seed=#{seed})" do
    rng = Random.new(seed + 1)
    iter.times do
      input = Array.new(rng.rand(0..40)) { rng.rand(0x20..0x7e) }.pack("C*").force_encoding("UTF-8")
      c = outcome(input, true)
      r = outcome(input, false)
      expect(c).to(eq(r), "C/Ruby divergence for #{input.inspect}\n C: #{c.inspect}\n Ruby: #{r.inspect}\n seed=#{seed}")
    end
  end

  it "C and Ruby paths agree on mutated valid JSON (seed=#{seed})" do
    rng = Random.new(seed + 2)
    iter.times do
      input = mutate(rng, JSON.generate(random_value(rng)))
      c = outcome(input, true)
      r = outcome(input, false)
      expect(c).to(eq(r), "C/Ruby divergence for #{input.inspect}\n C: #{c.inspect}\n Ruby: #{r.inspect}\n seed=#{seed}")
    end
  end

  it "C and Ruby paths agree on warnings for mutated valid JSON (seed=#{seed})" do
    rng = Random.new(seed + 4)
    iter.times do
      input = mutate(rng, JSON.generate(random_value(rng)))
      c = warned_outcome(input, true)
      r = warned_outcome(input, false)
      expect(c).to(eq(r), "C/Ruby warnings divergence for #{input.inspect}\n C: #{c.inspect}\n Ruby: #{r.inspect}\n seed=#{seed}")
    end
  end

  it "C and Ruby paths agree on warnings for random ASCII garbage (seed=#{seed})" do
    rng = Random.new(seed + 5)
    iter.times do
      input = Array.new(rng.rand(0..40)) { rng.rand(0x20..0x7e) }.pack("C*").force_encoding("UTF-8")
      c = warned_outcome(input, true)
      r = warned_outcome(input, false)
      expect(c).to(eq(r), "C/Ruby warnings divergence for #{input.inspect}\n C: #{c.inspect}\n Ruby: #{r.inspect}\n seed=#{seed}")
    end
  end

  it "round-trips: process(generate(value)) == value, on both paths (seed=#{seed})" do
    rng = Random.new(seed + 3)
    iter.times do
      value = random_value(rng)
      json  = SmarterJSON.generate(value)
      [true, false].each do |accel|
        got = SmarterJSON.process(json, acceleration: accel, decimal_precision: :float)
        expect(got).to(eq(value), "round-trip failed (accel=#{accel}) for #{value.inspect}\n json: #{json.inspect}\n got: #{got.inspect}\n seed=#{seed}")
      end
    end
  end
end
