
# SmarterJSON Change Log
## 0.5.0 (2026-05-31 unreleased)
- add JSON generation, incl. NDJSON generation
- add test coverage

## 0.4.0 (2026-05-31 unreleased)
- rename `smarter_json` -> `smarter_json`

## 0.3.10 (2026-05-31 unreleased)
- change interface to use `.process` and `.process_file`


## 0.3.9 (2026-05-31 unreleased)
- `parse` (no block) now handles any input automatically: 0 documents (empty / whitespace / comment-only) → `nil`, 1 document → the value itself, 2+ documents (NDJSON / JSONL / concatenated / whitespace-separated) → an Array of the values. It no longer raises on trailing content.
- Detection is free (the same trailing-content check that used to raise) and the single-document path allocates no Array, so single-value parsing is unchanged in speed.
- The block form (`parse(input) { |doc| … }`) is kept as the bounded-memory streaming path. `parse_file(path) { |doc| … }` now forwards the block too, so files stream the same way (previously the block was silently ignored). Bracketless comma lists (`1, 2, 3`) still raise — commas don't separate top-level documents (implicit-root array remains unsupported).
- The block form allows individual processing of each line in NDJSON files.
- Supersedes the earlier "raise on trailing content, match Oj" behavior.

## 0.3.8 (2026-05-30 unreleased)
- Reordered single-character checks so the more common byte is tested first (`-` before `+`).
- Quoteless-token boundary scan now uses a 256-byte class table: ordinary bytes are classified in one table lookup, and the lookahead byte is read only at a `#`/`/` instead of on every byte. Speeds up quoteless / config-style input (the lenient case the JSON benchmarks don't exercise).

## 0.3.7 (2026-05-30 unreleased)
- Escaped-string literal runs are bulk-copied with the NEON scanner instead of one byte at a time.
- Added branch hints (`__builtin_expect`) and prefetch to the hot string-scan loop. Sped up string-heavy files (string_array, github_events, twitter all 12–16% faster).

## 0.3.6 (2026-05-30 unreleased)
- Fast path for plain numbers inside objects/arrays (`fj_try_member_number`): one scan straight from the cursor, committing when the number meets a delimiter and falling back to the quoteless scanner otherwise. Skips the quoteless boundary scan + classify dispatch for the common case. Broad gains on number-in-container files (weather, canada, usgs, big_decimals).

## 0.3.5 (2026-05-30 unreleased)
- Rewrote `fj_parse_number` (top-level numbers) as a single pass: finds the token end and accumulates the mantissa/exponent at once, using the string's NUL terminator as a scan sentinel (no per-byte bounds check) and a digit loop that skips the underscore check until an underscore actually appears.
- Added `fj_try_decimal` for the quoteless path: validates and extracts the number in one scan, replacing the old three scans (validate + significant-digit count + mantissa extraction); skips the significant-digit scan when the number has ≤16 digits.
- Both number paths now build values through the shared `fj_int_from_parts` / `fj_float_from_parts` helpers so they can't drift; removed the now-dead `fj_validate_decimal` / `fj_int_value` / `fj_decimal_value`.

## 0.3.4 (2026-05-30 unreleased)
- Dropped a per-member Ruby method call (`key?`) that fired for every object member under the default duplicate-key mode — pure waste on object-heavy files (twitter, github_events, citm).
- Build objects and arrays from a C value stack with a pre-sized hash + bulk insert (and size-based duplicate detection), instead of inserting one member/element at a time.
- Added a per-parse key cache so repeated object keys are interned once instead of every occurrence.

## 0.3.3 (2026-05-30 unreleased)
- Vendored Ryū (Ulf Adams, Apache-2.0) for correctly-rounded string→double conversion: the mantissa is accumulated in one pass and converted with no `strtod`. Large win on float-heavy files (canada, big_decimals).

## 0.3.3 (2026-05-29 unreleased)
- performance fixes

## 0.3.2 (2026-05-29 unreleased)
- performance fixes

## 0.3.1 (2026-05-29 unreleased)
- performance fixes

## 0.3.0 (2026-05-29 unreleased)
- iterative parser

## 0.2.0 (2026-05-29 unreleased)
- recursive parser

## 0.1.1 (2026-05-29 unreleased)
- MVP complete

## 0.1.0 (2026-05-28 unreleased)
- Initial Ruby version
