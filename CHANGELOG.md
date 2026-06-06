
# SmarterJSON Change Log

> 🚧 Getting ready for the 1.0.0 release - sorry for the interface changes - thank you for your patience! 🚧

## 0.9.8 (2026-06-06 unreleased)
- Faster parsing of string-heavy arrays — Parsed values are unchanged.

## 0.9.7 (2026-06-05 unreleased)
- **Breaking: `process` / `process_file` now always return an `Array` of documents** — `[]` for none, `[doc]` for one, `[d1, d2, …]` for several. (Previously polymorphic: `nil` / the value / an `Array`.) The document count is now unambiguous, and any result can be iterated uniformly.
- **New `SmarterJSON.process_one(input)`** — the single-document accessor for the common case: returns the one document's value (or `nil`), and *warns* (never raises) if the input held more than one. Takes a String or an IO; for an IO it is bounded-memory (parses just the first document). Reaching for `.first` / `[0]` on a `process` result silently drops extra documents — use `process_one` instead.
- The **block form now returns the document count** (was `nil`): `n = SmarterJSON.process(io) { |doc| ... }`.
- **The top level is stricter, which keeps the LLM-wrapper recovery working:** a top-level value must be a recognized JSON value (number / `true` / `false` / `null` / quoted string / object / array) or an implicit-root object (`host: localhost`). A bare top-level run — `localhost`, `1 2 3`, the typo `flase` — now raises `ParseError` instead of becoming a quoteless string. A space is never a document separator (`1 2 3` raises rather than splitting into three). In-container quoteless strings (`[red green blue]`, `host: localhost`) are unchanged.

## 0.9.6 (2026-06-04 unreleased)
- Faster `decimal_precision: :float` parsing of full-precision decimal numbers (around 17–18 significant digits — e.g. coordinate data and scientific output). Parsed values are unchanged: still correctly rounded, bit-for-bit identical to `JSON.parse`.

## 0.9.5 (2026-06-04 unreleased)
- Faster `decimal_precision: :float` parsing of very high-precision decimal numbers (more than ~17 significant digits). Parsed values are unchanged.
- Faster parsing of object-heavy and compact documents — less per-element overhead in the C parser. No behavior change.

## 0.9.4 (2026-06-04 unreleased)
- Internal performance experiments. No user-facing changes.

## 0.9.3 (2026-06-03)
- Renamed the `bigdecimal_load:` option to `decimal_precision:` (same values: `:auto`, `:float`, `:bigdecimal`).
- Invalid option *values* now raise `ArgumentError` with a clear message instead of being silently ignored. Unknown option keys are still ignored.
- Faster parsing of pretty-printed (indented) input.
- Removed the `duplicate_key: :raise` option — it conflicted with SmarterJSON's lenient design. `duplicate_key:` now accepts `:last_wins` (default) and `:first_wins`; repeated keys are still reported through `on_warning`.

## 0.9.2 (2026-06-03)
- Fixed a performance regression that slowed parsing of large documents.

## 0.9.1 (2026-06-03 unreleased)
- Fixed a major performance regression on real-world data that contained markdown fences or `<json>` markers inside ordinary string values.
- Streaming: a document is no longer cut off early when a comment / quote marker falls across a read-chunk boundary.

## 0.9.0 (2026-06-03 unreleased)
- Performance improvements and code cleanup.

## 0.8.0 (2026-06-03)
- **Robustness** against LLM-generated / wrapped JSON:
  - strips markdown code fences (```json / ```)
  - ignores leading / trailing prose around a JSON payload
  - unwraps `<json>...</json>` and `BEGIN_JSON ... END_JSON`
  - returns multiple recovered payloads as an `Array`
  - parses pretty-printed multi-line documents from IO / block input
  - reports each recovery through `on_warning` (`:code_fence_stripped`, `:prefix_text_ignored`, `:suffix_text_ignored`, `:wrapper_tag_stripped`)
- Truncated / unterminated input still raises `SmarterJSON::ParseError` — SmarterJSON does not guess at missing data.

## 0.7.0 (2026-06-03)
- **Breaking:** replaced the `warnings:` option (and its `[result, warnings]` return) with an `on_warning:` callable. Pass `on_warning: ->(w) { ... }` to be handed each `SmarterJSON::Warning` as a lenient fix is applied; `process` / `process_file` now always return just the value, including on the streaming block form. The default (no handler) records nothing and costs nothing.

## 0.6.0 (2026-06-02)
- Lenient comma handling: empty slots around / between commas are collapsed (`[1,,2]` → `[1,2]`, `[,1,]` → `[1]`, `{a:1,,b:2}` → `{a:1,b:2}`). No null is inserted for an empty slot.
- A key with a colon but no value reads as null: `{a:}` → `{"a"=>nil}`.
- New opt-in `warnings:` option recording the lenient fixes applied — `:empty_slot`, `:empty_value`, `:duplicate_key`. (Superseded by `on_warning:` in 0.7.0.)

## 0.5.2 (2026-06-01) yanked
- `generate` supports pretty-printing via the `indent:` option (spaces per nesting level; default compact). Combining `indent:` with `format: :ndjson` raises `ArgumentError`.
- `generate` adds `sort_keys:` (emit object keys in sorted order), `ascii_only:` (escape non-ASCII), and `script_safe:` (escape `</` and U+2028/U+2029 for safe embedding in an HTML `<script>` tag).
- `generate` adds opt-in `coerce:` — convert an otherwise-unsupported value (e.g. `Time`, `Date`, app objects) via its own `as_json` / `to_json`; strict-by-default still raises `GenerateError`.

## 0.5.1 (2026-06-01) yanked
- Unified the error classes under a single `SmarterJSON::Error` base: `ParseError`, `EncodingError`, and the new `GenerateError` all inherit from it, so `rescue SmarterJSON::Error` catches everything the gem raises.
- Added a CI test matrix (Ruby 2.6–4.0 + head, on Ubuntu and macOS); minimum Ruby is now 2.6.

## 0.5.0 (2026-05-31 unreleased)
- Added JSON generation, including NDJSON.
- Added test coverage.

## 0.4.0 (2026-05-31 unreleased)
- Renamed the gem `flex_json` → `smarter_json`.

## 0.3.10 (2026-05-31 unreleased)
- Changed the interface to `.process` and `.process_file`.

## 0.3.9 (2026-05-31 unreleased)
- `process` with no block now handles any input automatically: 0 documents (empty / whitespace / comment-only) → `nil`, 1 document → the value itself, 2+ documents (NDJSON / JSONL / concatenated) → an `Array`. It no longer raises on trailing content.
- The block form (`process(input) { |doc| … }`) streams documents with bounded memory; `process_file` forwards the block too, so each line of an NDJSON file can be processed individually.

## 0.3.8 (2026-05-30 unreleased)
- Performance improvements (quoteless / config-style input).

## 0.3.7 (2026-05-30 unreleased)
- Performance improvements (string-heavy input).

## 0.3.6 (2026-05-30 unreleased)
- Performance improvements (numbers inside objects / arrays).

## 0.3.5 (2026-05-30 unreleased)
- Performance improvements (number parsing).

## 0.3.4 (2026-05-30 unreleased)
- Performance improvements (object-heavy input).

## 0.3.3 (2026-05-30 unreleased)
- Faster, correctly-rounded float parsing.

## 0.3.3 (2026-05-29 unreleased)
- Performance fixes.

## 0.3.2 (2026-05-29 unreleased)
- Performance fixes.

## 0.3.1 (2026-05-29 unreleased)
- Performance fixes.

## 0.3.0 (2026-05-29 unreleased)
- Iterative parser.

## 0.2.0 (2026-05-29 unreleased)
- Recursive parser.

## 0.1.1 (2026-05-29 unreleased)
- MVP complete.

## 0.1.0 (2026-05-28 unreleased)
- Initial Ruby version.
