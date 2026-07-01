# frozen_string_literal: true

require "mkmf"
require "rbconfig"
require_relative "cpu_flags"

# Ruby sometimes ships CFLAGS with "-g -O3"; drop the debug half so the
# extension is built optimized, not with debug info.
if RbConfig::MAKEFILE_CONFIG["CFLAGS"].include?("-g -O3")
  RbConfig::MAKEFILE_CONFIG["CFLAGS"] = RbConfig::MAKEFILE_CONFIG["CFLAGS"].sub("-g -O3", "-O3 $(cflags)")
end

# Probe whether the compiler accepts a flag by compiling a trivial program with
# it. Lets us skip flags the toolchain rejects (e.g. -march=native on Clang/ARM,
# or GCC-only flags on MSVC) instead of breaking the build. Replaces the old
# RUBY_PLATFORM string guesses: ask the actual compiler, don't infer from the OS.
def compiler_accepts?(flag)
  try_compile("int main(void){return 0;}", flag)
end

optflags = "-O3 -flto -fomit-frame-pointer -DNDEBUG".dup

# CPU optimization level, set via SMARTER_JSON_PERFORMANCE (default: portable).
# See cpu_flags.rb for the full description of each level.
#
#   portable (default) - no host-specific flags; runs on any CPU of the same arch.
#   tuned              - -mtune=native; host scheduling tuning, still portable.
#   max                - host instruction set (-march/-mcpu native); fastest, but
#                        NOT portable -- may crash on a CPU lacking those instructions.
cpu = SmarterJSON::CpuFlags.select(ENV["SMARTER_JSON_PERFORMANCE"], accepts: method(:compiler_accepts?))
warn(cpu[:warning]) if cpu[:warning]
cpu[:flags].each { |flag| optflags << " #{flag}" }
puts("SmarterJSON performance level: #{cpu[:level]} -- optflags: #{optflags}")

# -fno-semantic-interposition: GCC/Clang only (not MSVC). Allows intra-library
# calls to bypass the PLT on Linux and enables more aggressive LTO inlining.
optflags << " -fno-semantic-interposition" if compiler_accepts?("-fno-semantic-interposition")

CONFIG["optflags"]   = optflags
CONFIG["debugflags"] = ""

# rb_enc_interned_str (Ruby 3.0+) lets us intern object keys straight from the
# input bytes; on older Rubies the C code falls back to a plain new string.
have_func("rb_enc_interned_str", "ruby.h")

# Pre-sized hashes (3.2+) and bulk insert (2.6+) for object building; the C code
# falls back to rb_hash_new + per-pair aset when these are unavailable.
have_func("rb_hash_new_capa", "ruby.h")
have_func("rb_hash_bulk_insert", "ruby.h")

create_makefile("smarter_json/smarter_json")
