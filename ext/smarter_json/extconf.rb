# frozen_string_literal: true

require "mkmf"
require "rbconfig"

# Ruby sometimes ships CFLAGS with "-g -O3"; drop the debug half so the
# extension is built optimized, not with debug info.
if RbConfig::MAKEFILE_CONFIG["CFLAGS"].include?("-g -O3")
  RbConfig::MAKEFILE_CONFIG["CFLAGS"] = RbConfig::MAKEFILE_CONFIG["CFLAGS"].sub("-g -O3", "-O3 $(cflags)")
end

optflags = "-O3 -flto -fomit-frame-pointer -DNDEBUG".dup
# -march=native is skipped on arm64-darwin (Apple clang already targets the host).
optflags << " -march=native" unless RUBY_PLATFORM.start_with?("arm64-darwin")
# -fno-semantic-interposition: GCC/Clang only (not MSVC).
optflags << " -fno-semantic-interposition" unless RUBY_PLATFORM.include?("mswin")

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
