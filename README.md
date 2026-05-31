# FlexJSON

A lenient, fast JSON parser for Ruby. It parses strict JSON, JSON5, HJSON-style config, and the messy JSON-ish input humans actually write — and in benchmarks it matches or beats Oj on nearly every file. FlexJSON is opinionated: we want your JSON processing to be successful. Other parsers are strict - they stop at the first deviation - FlexJSON keeps going - it optimizes for getting your data out, not for policing the JSON spec.

## Why FlexJSON?

Most JSON parsers reject anything that isn't perfectly strict JSON. FlexJSON is built on the opposite principle: **you shouldn't have to care what flavor of JSON you were handed.** Give it strict JSON, JSON5, an HJSON-style config file, newline-delimited JSON, or a copy-pasted blob with comments and trailing commas — it just parses it.

Three things set it apart:

1. **One parser, no modes, no flags.** There is no `dialect:` option and no "strict mode" — `FlexJSON.parse(input)` accepts the whole superset, and strict JSON is simply the narrowest case. You don't configure the parser to match your input; it adapts to whatever you give it.

2. **It parses multi-document input automatically — a distinguishing feature.** `FlexJSON.parse` handles NDJSON / JSONL / concatenated JSON with **no block and no special method**: one document returns its value, several documents return an `Array`, empty input returns `nil`. **Only FlexJSON parses multi-document input via plain `parse` — Oj and the stdlib `json` library raise without a block.** For input larger than memory, pass a block to stream one document at a time.

3. **It's fast.** A C extension (with a pure-Ruby fallback that runs everywhere) puts it ahead of Oj on nearly every file we benchmark, and competitive with the stdlib `json` C parser — the fastest general-purpose Ruby JSON parser.

## What it accepts, beyond strict JSON

- `//`, `/* … */`, and `#` comments (a `#`/`//` only starts a comment when preceded by whitespace, so `url: http://x.com` parses as a string, not a truncated value)
- Trailing commas; unquoted keys (`{host: localhost}`); single-quoted, triple-quoted (`'''…'''`), and quoteless string values
- Implicit root object — a config file that starts with `key: value`, no outer `{}`
- `NaN`, `Infinity`, hex (`0xFF`), leading `+` / `.`, underscores in numbers (`1_000_000`)
- UTF-8 BOM, smart/curly quotes, Python literals (`True` / `False` / `None`), JavaScript `undefined`
- Mixed CR / LF / CRLF line endings, and any Ruby-supported input encoding (via `encoding:`)
- Duplicate keys (last value wins by default; configurable)

It raises only on genuinely unparseable input (unterminated string, mismatched bracket), with line and column in the message — never on valid-but-lenient input.

## Installation

```ruby
# Gemfile
gem "flex_json"
```

```bash
gem install flex_json
```

The C extension is built on install and used automatically. On platforms where it can't build, the pure-Ruby parser runs instead and produces identical results.

## Usage

```ruby
require "flex_json"

FlexJSON.parse('{"a": 1, "b": [2, 3]}')          # => {"a"=>1, "b"=>[2, 3]}
FlexJSON.parse("host: localhost\nport: 5432")     # => {"host"=>"localhost", "port"=>5432}  (no braces needed)
FlexJSON.parse_file("config.json5")               # read a file, then parse

# Multiple documents (NDJSON / JSONL / concatenated) — no block, no special method:
FlexJSON.parse(%({"id":1}\n{"id":2}\n{"id":3}))   # => [{"id"=>1}, {"id"=>2}, {"id"=>3}]
FlexJSON.parse('{"id":1}')                         # => {"id"=>1}   (one document → the value itself)
FlexJSON.parse("")                                 # => nil          (zero documents)

# For input larger than memory, stream one document at a time with a block
# (parse and parse_file both forward the block):
FlexJSON.parse_file("events.ndjson") { |event| EventJob.perform_async(event) }
```

### Options

| option            | default      | meaning                                                                 |
|-------------------|--------------|-------------------------------------------------------------------------|
| `symbolize_keys`  | `false`      | return object keys as Symbols instead of Strings                        |
| `duplicate_key`   | `:last_wins` | `:last_wins` / `:first_wins` / `:raise` for repeated keys in one object |
| `bigdecimal_load` | `:auto`      | `:auto` keeps high-precision decimals as `BigDecimal`; `:float` forces `Float`; `:bigdecimal` forces `BigDecimal` |
| `acceleration`    | `:auto`      | `:auto` uses the C extension when available; `false` forces pure Ruby   |
| `encoding`        | `"UTF-8"`    | labels the input's encoding (no transcoding pass; see below)            |

## Performance

Benchmarks: p10 of 40 runs, Apple M1 Max, Ruby 3.4.7, on the standard JSON corpus (canada, citm_catalog, twitter, github_events, …). The apples-to-apples comparisons are **FlexJSON/C** vs **Oj/strict** vs **stdlib `json`**, all producing `Float` (run `rake report` in `json_benchmarks/` for the full table — numbers vary run to run).

- **vs Oj:** FlexJSON/C matches or beats Oj on nearly every file — typically **1.1–1.7× faster** (e.g. deeply-nested ~1.7×, citm ~1.3×, twitter ~1.3×, usgs/weather ~1.2–1.3×).
- **vs stdlib `json` (C):** competitive with the fastest Ruby JSON parser — it matches `json` on number- and string-heavy files (e.g. big_decimals, string_array) and trails by ~1.2–1.6× on others.
- **Numbers:** floats are parsed with Ryū (correctly rounded, single-pass), so number-heavy data is fast and bit-exact.

**Two notes on fair comparison:**

- **NDJSON:** on multi-document files, **only FlexJSON parses the input via plain `parse`** — Oj and `json` raise without a block, so their cells are `N/A`. That `N/A` reflects real default behavior, not a measurement gap. Plain `parse` collects every document into an Array at ~270 MB/s; the streaming block form runs faster (~440 MB/s) because it doesn't hold all documents in memory at once — use it for input larger than RAM.
- **High-precision decimals (e.g. `canada.json`):** FlexJSON's default `:auto` mode preserves high-precision numbers as `BigDecimal` (matching Oj's default), which is intrinsically slower than `Float`. Against `Float`-producing parsers it looks slower on such files; pass `bigdecimal_load: :float` to compare like-for-like (it then runs much faster). Against the equivalent `BigDecimal`-producing Oj mode, FlexJSON is faster.

## Encoding

`encoding:` (default `"UTF-8"`) labels what the input is — it does **not** trigger a transcoding pass. The parser works on the bytes in their native encoding and emits string values with the same encoding tag, the same way `smarter_csv` handles encodings. Bytes that are invalid for the claimed encoding raise `FlexJSON::EncodingError` (a kind of `FlexJSON::ParseError`).

## Development

After checking out the repo, run `bin/setup` to install dependencies, then `rake compile` to build the C extension and `rake spec` to run the tests. The test suite runs every example against **both** the C and pure-Ruby paths, so the two stay behavior-identical.

## License

Available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
