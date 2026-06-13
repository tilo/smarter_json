
# SmarterJSON Change Log

> ⚠️ SmarterJSON **always returns an `Array`** of documents.
> 
> `SmarterJSON.process` / `SmarterJSON.process_file`
> both return:
>   — `[]` for no doc
>   - `[doc]` for one doc
>   - `[d1, d2, …]` for several docs (NDJSON / JSONL / concatenated docs)

> ⚠️ We discourage the use of `process(input).first` / `process(input)[0]` because it silently drops potential additional documents
>    Please use `process_one` if you are expecting only one JSON doc, e.g. in API payloads, because it emits on_warning if it finds multiple docs.

## 1.2.0 (unreleased)

RSpec tests: 1,143

- A leading-zero token now reads as a number when it carries a sign, a decimal point, or an exponent (`+007` → `7`, `-000023.5` → `-23.5`, `00.0` → `0.0`, `007e2` → `700.0`) — previously these were kept as strings. A bare leading-zero integer (`000001`, `02`) still reads as a string, so IDs, zip codes, and account numbers keep their zeros.
- `Null` and `NULL` are now read as `nil` (joining `null` / `None` / `undefined`), for SQL / R / PHP / YAML / DB-derived input — in every position the existing spellings work. Quoted (`"NULL"`) or embedded (`NULL Island`) forms stay strings.

## 1.1.2 (2026-06-12)

RSpec tests: 1,097

- The C extension now correctly supports Ruby's GC heap compaction (`GC.compact` / auto-compaction) — its cached exception/warning classes are declared to the GC. Thanks [Jean Boussier](https://github.com/byroot) for PR [#7](https://github.com/tilo/smarter_json/pull/7).

## 1.1.1 (2026-06-11)

RSpec tests: 1,070 → 1,097

- The C extension now emits the same `on_warning` warnings as the pure-Ruby parser. `empty_value` and `duplicate_key` warnings name the offending key (and `duplicate_key` names the resolution strategy), and the warning text, line, and column are now identical whether or not the C extension is loaded.

## 1.1.0 (2026-06-09)

RSpec tests: 1,038 → 1,070

- New `SmarterJSON.foreach(source)` — the streaming, composable sibling of `process_file`. `source` is a file path or an IO (a socket, `StringIO`, open `File`). Without a block it returns a plain `Enumerator` (like `CSV.foreach`) that reads one document at a time, never loading the whole file, so a large NDJSON / JSONL stream can be filtered or transformed with `.select` / `.map` / `.lazy` / `.first`; with a block it streams and returns the document count, like `process_file`.

## 1.0.0 (2026-06-08)

RSpec tests: 1,038

- **The public interface is now stable** — `process`, `process_one`, `process_file`, `generate`, and the documented options; semantic versioning from here on.
- Unknown or wrongly-typed options now raise `ArgumentError` instead of being silently ignored, so a typo (e.g. `symbolize_names:` instead of `symbolize_keys:`) is caught immediately.
- Input tagged `ASCII-8BIT` whose bytes are valid UTF-8 (e.g. a `Net::HTTP` `response.body`) is now read as UTF-8, so its string values compare equal to UTF-8 literals; ASCII-8BIT input that is not valid UTF-8 raises `SmarterJSON::EncodingError` (pass an explicit `encoding:` for legacy encodings).
- Object keys may now use smart/curly quotes too (e.g. JSON pasted from a word processor), not just string values.
- `SmarterJSON.generate` accepts `allow_nan: true` to emit `NaN` / `Infinity` / `-Infinity` (JSON5-style) instead of raising, so non-finite numbers round-trip; the default still raises.
- A numeric literal that overflows `Float` range (e.g. `1e400`) now reports a `:number_overflow` warning via `on_warning` instead of silently becoming `Infinity`.
- `SmarterJSON.generate` is now iterative (like the parser), so serializing a deeply nested structure no longer risks `SystemStackError` — reading and writing are both depth-safe.

## 0.9.9 (2026-06-07)
- Much faster pure-Ruby parsing (the path used without the C extension) — roughly 3× on string-heavy data, ~2× on number-heavy, ~1.7× on object-heavy (on a YJIT-enabled Ruby). Parsed values are unchanged.

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
