# frozen_string_literal: true

module SmarterJSON
  # All reader settings live in one options hash (smarter_csv style). This module
  # holds the defaults, merges the caller's overrides onto them, and validates the
  # result — mirroring SmarterCSV::Reader::Options.
  module Options
    DEFAULT_OPTIONS = {
      acceleration: true,        # use the C extension when available; false forces pure Ruby
      encoding: nil,             # label the input's encoding (no transcoding); nil keeps the input's own
      symbolize_keys: false,     # Symbol keys instead of String
      duplicate_key: :last_wins, # :last_wins | :first_wins  (repeats are also reported via on_warning)
      decimal_precision: :auto,  # :auto | :float | :bigdecimal  (Oj-compatible decimal handling)
      on_warning: nil,           # a callable invoked once per non-fatal lenient fix (a SmarterJSON::Warning)
    }.freeze

    module_function

    # Merge the caller's overrides onto the defaults, validate, and return the hash.
    def process_options(given_options = {})
      options = DEFAULT_OPTIONS.merge(given_options || {})
      validate_options!(options)
      options
    end

    # Raise ArgumentError (consistent with the generator's option checks) listing
    # every invalid setting at once. Unknown keys are ignored, matching the lenient
    # design — an option SmarterJSON doesn't recognize simply has no effect.
    def validate_options!(options)
      errors = []

      unless %i[auto float bigdecimal].include?(options[:decimal_precision])
        errors << "decimal_precision must be :auto, :float, or :bigdecimal (got #{options[:decimal_precision].inspect})"
      end
      unless %i[last_wins first_wins].include?(options[:duplicate_key])
        errors << "duplicate_key must be :last_wins or :first_wins (got #{options[:duplicate_key].inspect})"
      end
      on_warning = options[:on_warning]
      unless on_warning.nil? || on_warning.respond_to?(:call)
        errors << "on_warning must be nil or a callable (got #{on_warning.class})"
      end
      encoding = options[:encoding]
      unless encoding.nil? || encoding.is_a?(String)
        errors << "encoding must be nil or a String (got #{encoding.class})"
      end

      raise ArgumentError, "SmarterJSON: invalid options — #{errors.join('; ')}" if errors.any?

      options
    end
  end
end
