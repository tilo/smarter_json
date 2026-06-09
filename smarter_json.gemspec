# frozen_string_literal: true

require_relative "lib/smarter_json/version"

Gem::Specification.new do |spec|
  spec.name          = "smarter_json"
  spec.authors       = ["Tilo Sloboda"]
  spec.email         = ["tilo.sloboda@gmail.com"]
  spec.version       = SmarterJSON::VERSION
  spec.date          = Time.now.utc.strftime('%Y-%m-%d')
  spec.license       = 'MIT'
  spec.summary = 'A lenient, fast JSON processor for Ruby — reads strict JSON, NDJSON, JSON5, HJSON, and the messy JSON humans and LLMs actually write.'
  spec.description = <<~DESC
    A lenient, fast JSON processor for Ruby. It extracts strict JSON, NDJSON, JSON5, HJSON-style config, and the messy JSON-ish input humans and LLMs actually write — comments, trailing commas, single / unquoted / smart quotes, Python and JS keywords, a UTF-8 BOM, and more all parse to the same Ruby objects, with no modes or flags to set. Where a traditional parser stops at the first deviation and throws away the whole document, SmarterJSON keeps going — it optimizes for getting your data out, not for policing the JSON spec. It reads multi-document NDJSON / JSONL in one call (and streams it with a block), and in benchmarks its C extension matches or beats Oj on nearly every file. SmarterJSON is opinionated: we want your JSON processing to be successful.
  DESC

  spec.homepage = "https://github.com/tilo/smarter_json"

  spec.metadata["homepage_uri"]      = spec.homepage
  spec.metadata["source_code_uri"]   = "#{spec.homepage}/tree/main"
  spec.metadata["changelog_uri"]     = "https://github.com/tilo/smarter_json/blob/main/CHANGELOG.md"
  spec.metadata["documentation_uri"] = "https://github.com/tilo/smarter_json#readme"
  spec.metadata["bug_tracker_uri"]   = "https://github.com/tilo/smarter_json/issues"
  # spec.metadata["allowed_push_host"] = "TODO: Set to your gem server 'https://example.com'"
  spec.required_ruby_version = ">= 2.6.0"

  # Uncomment the line below to require MFA for gem pushes.
  # This helps protect your gem from supply chain attacks by ensuring
  # no one can publish a new version without multi-factor authentication.
  # See: https://guides.rubygems.org/mfa-requirement-opt-in/
  # spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .rspec spec/ .github/ .rubocop.yml])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]
  spec.extensions = ["ext/smarter_json/extconf.rb"]

  # bigdecimal is no longer a default gem on Ruby 3.4+; needed for
  # bigdecimal_load: :auto / :bigdecimal (Oj-compatible decimal loading).
  spec.add_dependency "bigdecimal"

  # For more information and examples about making a new gem, check out our
  # guide at: https://guides.rubygems.org/make-your-own-gem/
end
