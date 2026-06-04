
# SmarterJSON Change Log

> 🚧 Getting ready for the 1.0.0 release - sorry for the interface changes - thank you for your patience! 🚧

## 0.9.3 (2026-06-03)
- **Renamed the `bigdecimal_load:` option to `decimal_precision:`.** Same values (`:auto` / `:float` / `:bigdecimal`), clearer name. (Pre-release, no compatibility shim.)
- **Centralized option handling in `SmarterJSON::Options`** (`lib/smarter_json/options.rb`, mirroring `SmarterCSV::Reader::Options`): one home for `DEFAULT_OPTIONS`, the merge of caller overrides, and validation. Invalid option *values* now raise `ArgumentError` with a clear message (e.g. an unknown `decimal_precision`, or the now-removed `duplicate_key: :raise`) instead of being silently ignored; unknown option *keys* are still ignored, matching the lenient design.
- **Faster whitespace skipping on pretty-printed input (C extension).** Runs of indentation — spaces *or* tabs, the two common styles — are now skipped 8 bytes at a time with a single 64-bit compare, instead of byte-by-byte. Profiling `citm_catalog.json` (heavily-indented) showed whitespace skipping was the single largest slice of parse time; this lifts it ~10–15% locally (≈700 → ≈800 MB/s) with no behavior change. Compact JSON (little whitespace) is unaffected.
- **Removed the `duplicate_key: :raise` option.** Raising on a repeated key is strict-validation policing, which runs against SmarterJSON's "extract the data, don't police the spec" philosophy — for strict behavior, use the stdlib `json` gem. `duplicate_key:` now accepts only `:last_wins` (default) and `:first_wins`. Every repeated key is still reported through `on_warning` (`:duplicate_key`), so callers that need to detect duplicates (e.g. for the duplicate-key security concern) can observe and decide for themselves without rejecting the whole document.

## 0.9.2 (2026-06-03)
- **Fix a residual performance regression affecting every large document.** The "leading label" check (for `JSON: {…}`, which parses successfully but wrongly as an implicit-root object) now uses `String#start_with?(/…/)` instead of `match?(/\A…/)`. A `\A`-anchored `match?` is **not** anchor-optimized — it retries at every byte position and so scanned the entire input (~0.3 s on a 200 MB document) on every parse, which had quietly taxed every large file since the wrapper was introduced (deeply_nested.json and big_decimals.json sat well below their 0.6.0 throughput even after 0.9.1). `start_with?` inspects only the beginning, restoring — and slightly exceeding — 0.6.0 throughput across the board.

## 0.9.1 (2026-06-03 unreleased)
- **Fix a major performance regression on real-world data** (introduced with the 0.8.0 wrapper recovery). Wrapper recovery is now **reactive**: input is parsed first, and the markdown-fence / `<json>` / prose extraction runs only when that parse actually fails. Before, any input that merely *contained* ` ``` ` or `<json>` anywhere — including inside ordinary JSON string values, as GitHub-event payloads and other markdown-bearing data routinely do — was dragged through a full pure-Ruby recovery scan plus a double parse on every call (~30–45× slower on those files). A bare leading label like `JSON: {…}`, which parses successfully but wrongly, is still caught up front before parsing.
- **Streaming framer**: a multi-byte marker (`//`, `/*`, `'''`, `*/`) whose bytes straddle a read-chunk boundary is no longer mis-scanned — the framer waits for the rest of the marker before deciding, so a brace inside such a comment/string can no longer end a document early.
- Wrapper warnings (`code_fence_stripped` / `wrapper_tag_stripped`) now fire only when the marker is actually in the stripped text, not when it sits inside a recovered payload's own string value.
- Shared `SmarterJSON::Bytes` constants for the parser and the framer / recovery scanners (no raw hex byte literals).

## 0.9.0 (2026-06-03 unreleased)
- performance improvements
- code cleanup

## 0.8.0 (2026-06-03)
- **Robustness** against LLM-generated / wrapped JSON:
  - strips markdown code fences (```json / ```)
  - ignores obvious prefix / suffix prose around a payload
  - unwraps `<json>...</json>` and `BEGIN_JSON ... END_JSON`
  - preserves multiple recovered payloads as an `Array`
  - supports pretty-printed multi-line document framing on IO / block input
  - **Warnings** now cover wrapper recovery too (`:code_fence_stripped`, `:prefix_text_ignored`, `:suffix_text_ignored`, `:wrapper_tag_stripped`)
  - **No truncation recovery**: truncated / unterminated input still raises `SmarterJSON::ParseError`

## 0.7.0 (2026-06-03)
- **Breaking:** replaced the `warnings:` option (and its `[result, warnings]` tuple return) with an `on_warning:` callable. Pass `on_warning: ->(w) { ... }` to be handed each `SmarterJSON::Warning` as the parser applies a lenient fix; `process` / `process_file` now always return the bare value (nil / value / Array) on every path. Unlike the tuple, this also fires on the streaming block form. The default (no handler) records nothing and costs nothing.

## 0.6.0 (2026-06-02)
- Lenient comma handling: empty slots around / between commas are collapsed (`[1,,2]` → `[1,2]`, `[,1,]` → `[1]`, `{a:1,,b:2}` → `{a:1,b:2}`), on both the C and Ruby paths. No null is inserted for an empty slot.
- A key with a colon but no value reads as null: `{a:}` → `{"a"=>nil}` (both paths).
- New opt-in `warnings:` option. With `warnings: true`, `process` / `process_file` return `[result, warnings]`, where `warnings` is an Array of `SmarterJSON::Warning` (`type`, `message`, `line`, `col`) recording the lenient fixes applied — `:empty_slot`, `:empty_value`, `:duplicate_key`. Default off; works on both paths.
- Fixed a pure-Ruby bug where a mantissa-less exponent token (e.g. `-e695881`) was read as `0.0`; it is now a quoteless string, matching the C path.
- Fixed a pure-Ruby bug where a `\u` escape whose next bytes split a multibyte character leaked `ArgumentError`; it now raises `SmarterJSON::ParseError`.
- Added a property/fuzz test suite that checks C/Ruby parity and round-tripping on generated, mutated, and random input.

## 0.5.2 (2026-06-01) yanked
- `generate` now supports pretty-printing via the `indent:` option (spaces per nesting level; default `0` = compact). Empty objects/arrays stay inline; `indent:` combined with `format: :ndjson` raises `ArgumentError`.
- `generate` adds `sort_keys:` (emit object keys in sorted order), `ascii_only:` (escape non-ASCII as `\uXXXX`, astral chars as surrogate pairs), and `script_safe:` (escape `</` and U+2028/U+2029 for safe embedding in an HTML `<script>` tag).
- `generate` adds opt-in `coerce:` — when `true`, a value that isn't natively supported (e.g. `Time`, `Date`, app objects) is converted via its own `as_json` (result re-emitted) or `to_json` (spliced); strict-by-default still raises `GenerateError`.

## 0.5.1 (2026-06-01) yanked
- Unified the error classes under a single `SmarterJSON::Error` base: `ParseError` and `EncodingError` now inherit from it, and `generate` raises a new `GenerateError`. `rescue SmarterJSON::Error` now catches everything the gem raises.
- Added a CI test matrix (Ruby 2.6–4.0 + head, on Ubuntu and macOS).
- Fixed the C extension build on Ruby 2.6 (declare `rb_hash_bulk_insert`, which 2.6 exports but does not declare in its headers); set the minimum Ruby to 2.6.

## 0.5.0 (2026-05-31 unreleased)
- add JSON generation, incl. NDJSON generation
- add test coverage

## 0.4.0 (2026-05-31 unreleased)
- rename `flex_json` -> `smarter_json`

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
