# SmarterJSON

![Gem Version](https://img.shields.io/gem/v/smarter_json) [![codecov](https://codecov.io/gh/tilo/smarter_json/branch/main/graph/badge.svg)](https://codecov.io/gh/tilo/smarter_json) <!-- [![Downloads](https://img.shields.io/gem/dt/smarter_json)](https://rubygems.org/gems/smarter_json) --> [![RubyGems](https://img.shields.io/badge/RubyGems-smarter__json-brightgreen?logo=rubygems&logoColor=white)](https://rubygems.org/gems/smarter_json) [![Ruby Toolbox](https://img.shields.io/badge/Ruby%20Toolbox-smarter__json-brightgreen)](https://www.ruby-toolbox.com/projects/smarter_json)

A lenient, fast JSON processor for Ruby. It extracts strict JSON, NDJSON, JSON5, HJSON-style config, and the messy JSON-ish input humans actually write — and in benchmarks it matches or beats Oj on nearly every file. SmarterJSON is opinionated: we want your JSON processing to be successful. Traditional JSON parsers are strict - they stop at the first deviation - SmarterJSON keeps going - it optimizes for getting your data out, not for policing the JSON spec.

> **SmarterJSON: one tool, no modes — want strict? Please use the stdlib `json` gem.**

## Why SmarterJSON?

**Are you tired of seeing errors like these?**

```
    ERROR running JSON.parse (stdlib) on deeply_nested.json: JSON::NestingError: nesting of 101 is too deep

    ERROR running Oj.load (default) on config.json5: Oj::ParseError: unexpected character (after [0]) at line 5, column 6 [parse.c:931]

    ERROR running Oj.load (strict, float) on config.json5: Oj::ParseError: unexpected character (after [0]) at line 5, column 6 [parse.c:931]

    ERROR running Oj.load (compat) on config.json5: EncodingError: unexpected character (after [0]) at line 5, column 6 [parse.c:931] in '// JSON5 config sample — leni…

    ERROR running JSON.parse (stdlib) on config.json5: JSON::ParserError: expected object key, got 'id:' at line 4 column 5

    ERROR running Yajl::Parser (yajl-ruby) on config.json5: Yajl::ParseError: lexical error: invalid char in json text. this. */ [ // record 0 { id: 0, name: 'alpha-0', mask: 0 (…

    ERROR running Oj.load (default) on github_events_100k.ndjson: Oj::ParseError: unexpected characters after the JSON document (after ) at line 2, column 1 [parse.c:870]

    ERROR running Oj.load (strict, float) on github_events_100k.ndjson: Oj::ParseError: unexpected characters after the JSON document (after ) at line 2, column 1 [parse.c:870]

    ERROR running Oj.load (compat) on github_events_100k.ndjson: EncodingError: unexpected characters after the JSON document (after ) at line 2, column 1 [parse.c:870] in '{"id":"…

    ERROR running JSON.parse (stdlib) on github_events_100k.ndjson: JSON::ParserError: unexpected token at end of stream '{"id":"34816047161","type":"Dele' at line 1 column 1

    ERROR running Yajl::Parser (yajl-ruby) on github_events_100k.ndjson: Yajl::ParseError: Found multiple JSON objects in the stream but no block or the on_parse_complete callback was
  assigne…
```

**Do you have no control of the input quality?**

Traditional JSON parsers reject anything that isn't perfectly strict JSON. That means your code breaks on malformed data.

SmarterJSON is built on the opposite principle: **you shouldn't have to care what flavor of JSON you were handed** and **you shouldn't lose the whole document because of formatting errors.**
Give it strict JSON, NDJSON, JSON5, an HJSON-style config file, LLM-generated JSON, or a copy-pasted blob with comments and trailing commas — it just extracts the data from it.
When it is lenient, `smarter_json` isn't dropping data that exists — it's just not raising an eyebrow at a suspicious gap (like an extra comma).

A strict parser would refuse the whole document and recover nothing; `smarter_json` returns everything except the formatting error.

> For an ingestion tool, "reject the whole document because of one stray comma" is the worst outcome: you throw away the 99% that's fine to avoid maybe-mishandling a gap that carries no data anyway.

Three things set it apart:

1. **One tool, no modes, no flags.** There is no `dialect:` option and no "strict mode" — `SmarterJSON.process(input)` accepts the whole superset, and strict JSON is simply the narrowest case. You don't configure it to match your input; it adapts to whatever you give it.

2. **It extracts every document from multi-document input automatically — a distinguishing feature.** `SmarterJSON.process` handles NDJSON / JSONL / concatenated JSON with **no block and no special method**: it always returns an `Array` of the documents found (`[]` / `[doc]` / `[d1, d2, …]`). For the common single-document case, `SmarterJSON.process_one` returns the one value directly (and warns, never raises, if there was more than one). The same rule applies when wrapper noise is stripped and several payloads are recovered from one blob. **Only SmarterJSON reads multi-document input via plain `process` — Oj and the stdlib `json` library raise without a block.** For input larger than memory, pass a block to stream one document at a time.

3. **It's fast.** A C extension (with a pure-Ruby fallback that runs everywhere) puts it ahead of Oj on nearly every file we benchmark, and competitive with the stdlib `json` C parser — among the fastest general-purpose JSON processors in Ruby.

## What it accepts, beyond strict JSON

- `//`, `/* … */`, and `#` comments (a `#`/`//` only starts a comment when preceded by whitespace, so `url: http://x.com` is read as a string, not a truncated value)
- Markdown-wrapped / chatty blobs around the payload: strips ```` ```json ```` / ```` ``` ```` fences, ignores obvious prose before/after the payload, unwraps `<json>...</json>` and `BEGIN_JSON ... END_JSON`, and preserves multiple recovered payloads as an Array
- Trailing commas; unquoted keys (`{host: localhost}`); single-quoted, triple-quoted (`'''…'''`), and quoteless string values
- Implicit root object — a config file that starts with `key: value`, no outer `{}`
- `NaN`, `Infinity`, hex (`0xFF`), leading `+` / `.`, underscores in numbers (`1_000_000`)
- UTF-8 BOM, smart/curly quotes, Python literals (`True` / `False` / `None`), JavaScript `undefined`
- Mixed CR / LF / CRLF line endings, and any Ruby-supported input encoding (via `encoding:`)
- Duplicate keys (last value wins by default; configurable)

It raises only on genuinely unreadable input (unterminated string, mismatched bracket), with line and column in the message — never on valid-but-lenient input.

### Format references

The lenient grammar is a superset of these human-JSON specs — listed once, here:

* [JSON5](https://json5.org/)
* [HJSON](https://hjson.github.io/)
* [JWCC / HuJSON](https://github.com/tailscale/hujson)
* [Nigel Tao](https://nigeltao.github.io/blog/2021/json-with-commas-comments.html)
* [JSONH](https://github.com/jsonh-org/Jsonh)
* [JSONC (VS Code)](https://jsonc.org/)
* [NDJSON / JSON Text Sequences (RFC 7464)](https://datatracker.ietf.org/doc/html/rfc7464).

## Installation

```ruby
# Gemfile
gem "smarter_json"
```

```bash
gem install smarter_json
```

The C extension is built on install and used automatically. On platforms where it can't build, the pure-Ruby implementation runs instead and produces identical results.

## Usage

Pass a String of JSON content or an IO; you get back the extracted data. The same call handles strict JSON, JSON5, and HJSON-style config — there are no modes or flags.

```ruby
require "smarter_json"

SmarterJSON.process('{"a": 1, "b": [2, 3]}')       # => [{"a"=>1, "b"=>[2, 3]}]   (always an Array of documents)
SmarterJSON.process_one('{"a": 1, "b": [2, 3]}')   # => {"a"=>1, "b"=>[2, 3]}     (the one document's value)
SmarterJSON.process_file("config.json5")            # read a file, then process
```

**Prefer `process`.** It always returns an `Array`, so the document count is explicit and you never silently drop one. Reach for `process_one` when you want just the single document's value — it *warns* (never raises) if the input turns out to hold more than one, so an unexpected extra document is surfaced, not dropped.

## Usage in APIs

At an API boundary the JSON comes from someone you don't control — a client POSTing a request body to *your* service, or an upstream service answering a call *you* made — and it isn't always clean: a stray trailing comma, a `NaN`, a payload wrapped in prose, or a quiet change to the format. A strict parser turns any of those into an exception (a request you reject, or a failed call chain). SmarterJSON extracts the data that's there instead, so one formatting quirk doesn't sink the whole request:

```ruby
# Inbound — JSON a caller sent to your endpoint:
data = SmarterJSON.process(request.body)

# Outbound — JSON from a service you called:
data = SmarterJSON.process(response.body)
```

What that buys you:

* fewer "random production crashes" from messy JSON on either side of the wire
* resilience when a caller or a provider changes its output
* the option to log and recover, instead of rejecting the request outright
* consistent handling of edge-case payloads

See [Examples](#examples) below for multi-document input, streaming, and recovering JSON from LLM / markdown noise.

## Stable interface & thread safety

The public interface is now considered stable: `SmarterJSON.process`, `SmarterJSON.process_one`, `SmarterJSON.process_file`, `SmarterJSON.generate`, and the documented options in this README/docs are the supported surface.

Concurrent calls are safe. The processor and generator keep per-call state local, and the C extension only caches Ruby IDs / constants at load time; it does not share mutable state across calls.

## Documentation

  * [Introduction](docs/_introduction.md)
  * [The Basic Read API](docs/basic_read_api.md)
  * [The Basic Write API](docs/basic_write_api.md)
  * [Configuration Options](docs/options.md)
  * [Examples](docs/examples.md)

### Warnings (`on_warning`)

When SmarterJSON quietly fixes something lenient — collapses an empty comma slot, reads a key with no value as `null`, drops a duplicate key, strips code fences, ignores wrapper prose, unwraps wrapper tags — it can tell you, without changing what `process` returns. Pass a callable as `on_warning:`; it is invoked once per fix with a `SmarterJSON::Warning` (`type`, `message`, `line`, `col`). It fires on every path, including the streaming block form. With no handler (the default) nothing is recorded and there is zero overhead.

```ruby
# Collect them all:
warns = []
data  = SmarterJSON.process(input, on_warning: ->(w) { warns << w })

# Or route them — log, count, raise:
SmarterJSON.process(input, on_warning: ->(w) { Rails.logger.warn(w) })
```


## Performance

Benchmarks: Apple M1 Max, Ruby 3.4.7, p10 of 40 runs, on the standard JSON corpus. Each cell is **SmarterJSON vs that parser** — "faster" means SmarterJSON wins (run `rake report` in `json_benchmarks/` for the full table; ratios vary run to run).

**SmarterJSON is..**


| File                      | vs Oj/strict    | vs `json`        | vs Yajl         |
| ------------------------- | --------------- | ---------------- | --------------- |
| big_decimals <sup>≠</sup> | **1.8× faster** | **1.1× faster**  | **1.3× faster** |
| canada <sup>≠</sup>       | **6.4× faster** | 1.6× slower      | **1.8× faster** |
| citm_catalog              | **1.6× faster** | 1.3× slower      | **4.8× faster** |
| citylots <sup>≠</sup>     | **4.1× faster** | **2.2× faster**  | **2.5× faster** |
| config.jsonc              | **1.3× faster** | 1.5× slower      | **3.9× faster** |
| deeply_nested             | **1.9× faster** | n/a <sup>‡</sup> | **5.4× faster** |
| github_events             | **1.2× faster** | ≈ tied           | **3.1× faster** |
| string_array              | 1.6× slower     | **1.1× faster**  | **1.8× faster** |
| twitter                   | **1.4× faster** | 1.3× slower      | **3.6× faster** |
| usgs_earthquakes          | **1.2× faster** | 1.5× slower      | **3.7× faster** |
| weather_berlin            | **1.7× faster** | ≈ tied           | **3.5× faster** |

<sup>≠</sup> Measured in `decimal_precision: :float` (Float, like-for-like). SmarterJSON's **default** `:auto` keeps these high-precision decimals as `BigDecimal` (no precision loss, like Oj's default) — intrinsically slower than `Float`, so comparing the default to `Float`-only parsers would be apples-to-oranges. Against Oj's matching `BigDecimal` default, SmarterJSON is faster there too.
<sup>‡</sup> **n/a** isn't a measurement gap — it's real default behavior: `json` **errors on these** by default (it raises on multi-document / NDJSON input without a block, and caps nesting at 100 levels). SmarterJSON has neither limit.

In short: **faster than Oj/strict nearly everywhere, far faster than Yajl, ahead of stdlib `json` on high-precision floats (`citylots` ~2×) and string_array, level on github/weather, and behind only on the strict-grammar files** — the cost of the leniency `json` doesn't carry. (`string_array` vs Oj/strict is the one loss — Oj's string-cache fast path; we're level with Oj/compat and `json` there.) Floats are decoded with the **Eisel-Lemire** algorithm (fast_float), correctly rounded and **bit-for-bit identical to `JSON.parse`** — fast *and* exact, even on full-double-precision decimals.

**Two notes on fair comparison:**

- **NDJSON:** on multi-document files, **only SmarterJSON reads the input via plain `process`** — Oj and `json` raise without a block (the `‡` above). Plain `process` collects every document into an Array at ~270 MB/s; the streaming block form runs faster (~440 MB/s) because it doesn't hold all documents in memory at once.
- **High-precision decimals (the `≠` files):** by default these load as `BigDecimal` (full precision, like Oj's default), which is intrinsically slower than `Float`. Pass `decimal_precision: :float` for a like-for-like `Float` comparison — where SmarterJSON **beats stdlib `json`** (e.g. `citylots` ~2×). Against Oj's matching `BigDecimal` default, SmarterJSON is faster either way.


### Options

| option            | default      | meaning                                                                 |
|-------------------|--------------|-------------------------------------------------------------------------|
| `symbolize_keys`  | `false`      | return object keys as Symbols instead of Strings                        |
| `duplicate_key`   | `:last_wins` | `:last_wins` / `:first_wins` for a key repeated in one object (every repeat is also reported via `on_warning`) |
| `decimal_precision` | `:auto`      | `:auto` keeps high-precision decimals as `BigDecimal`; `:float` forces `Float`; `:bigdecimal` forces `BigDecimal` |
| `acceleration`    | `true`       | `true` uses the C extension when compiled and loadable; `false` forces pure Ruby (identical results) |
| `encoding`        | `"UTF-8"`    | labels the input's encoding (no transcoding pass; see below)            |
| `on_warning`      | `nil`        | a callable invoked once per lenient fix applied (`:empty_slot`, `:empty_value`, `:duplicate_key`), passed a `SmarterJSON::Warning`; the return value is never changed. See below. |

## Examples

### Lenient, config-style input

No outer braces needed — a file or string that starts with `key: value` is read as an implicit root object (HJSON-style):

```ruby
SmarterJSON.process_one("host: localhost\nport: 5432")
# => {"host"=>"localhost", "port"=>5432}
```

### Multiple documents (NDJSON / JSONL / concatenated)

`process` always returns an **`Array` of the documents** it found — `[]` for none, `[doc]` for one, `[d1, d2, …]` for several — with **no block and no special method**. The document count is unambiguous, and any result iterates uniformly:

```ruby
SmarterJSON.process(%({"id":1}\n{"id":2}\n{"id":3}))   # => [{"id"=>1}, {"id"=>2}, {"id"=>3}]
SmarterJSON.process('{"id":1}')                         # => [{"id"=>1}]   (one document, still an Array)
SmarterJSON.process("")                                 # => []            (zero documents)
```

For the common single-document case, **`process_one`** returns the one value directly — and *warns* (never raises) if the input held more than one, so you never silently drop a document:

```ruby
SmarterJSON.process_one('{"id":1}')   # => {"id"=>1}
SmarterJSON.process_one("")           # => nil
```

> **Type-checking the result?** Use `result.is_a?(Array)`, not `result.class == Array` — it's the idiomatic Ruby test, and it stays correct if a future release returns a specialized `Array` subclass.

A **top-level** value must be recognized JSON — a number, `true` / `false` / `null`, a quoted string, an object, an array — or an implicit-root object (`host: localhost`). A bare top-level run such as `localhost` or `1 2 3` raises `ParseError`. Quoteless string values *inside* objects and arrays (`{host: localhost}`, `[red green blue]`) are unchanged.

### Streaming large input with a block

For input larger than memory, pass a block: each document is yielded as it is read and the method returns the **document count** instead of building an `Array`. Both `process` and `process_file` forward the block:

```ruby
SmarterJSON.process_file("events.ndjson") { |event| EventJob.perform_async(event) }
```

### Recovering JSON from LLM / markdown noise

When the payload is wrapped in markdown fences, surrounding prose, or tags, `process` (or `process_one` for a single payload) strips the wrapper and reads what's inside. (Clean JSON never pays for this — recovery only runs when a straight read fails.)

A fenced code block, as an LLM often returns:

````ruby
SmarterJSON.process_one(<<~TEXT)
  Here is the JSON:

  ```json
  { "a": 1 }
  ```
TEXT
# => {"a"=>1}
````

Explanatory prose before and/or after the payload is ignored:

```ruby
SmarterJSON.process_one(<<~TEXT)
  Here is the result:

  { "a": 1 }

  Hope this helps.
TEXT
# => {"a"=>1}
```

`<json>...</json>` / `BEGIN_JSON ... END_JSON` wrapper tags are unwrapped:

```ruby
SmarterJSON.process_one('<json>{"a":1}</json>')
# => {"a"=>1}
```

When one blob contains several recovered payloads, they come back as an `Array` (the same rule as multi-document input):

```ruby
SmarterJSON.process(<<~TEXT)
  first attempt:
  {"a":1}

  corrected payload:
  {"b":2}
TEXT
# => [{"a"=>1}, {"b"=>2}]
```

## Encoding

`encoding:` (default `"UTF-8"`) labels what the input is — it does **not** trigger a transcoding pass. SmarterJSON works on the bytes in their native encoding and emits string values with the same encoding tag, the same way `smarter_csv` handles encodings. Bytes that are invalid for the claimed encoding raise `SmarterJSON::EncodingError` (a kind of `SmarterJSON::ParseError`).

## Nesting & untrusted input

Both the C extension and the pure-Ruby engine are **iterative, not recursive** — they track nesting on an explicit, heap-allocated stack rather than the call stack. So deeply nested input **cannot overflow the call stack or segfault**: nesting is bounded only by available memory, the same posture as Oj (which also ships no nesting limit; the stdlib `json` caps at 100). The `deeply_nested.json` benchmark (212 MB of nesting) is handled without issue.

The trade-off: there is currently **no fixed nesting or input-size limit**, so extremely large or adversarially-nested untrusted input is bounded by memory (it can exhaust RAM), not by a crash. If you process untrusted input and want a hard cap, that's a planned opt-in guard — for now, size-limit upstream.


## Development

After checking out the repo, run `bin/setup` to install dependencies, then `rake compile` to build the C extension and `rake spec` to run the tests. The test suite runs every example against **both** the C and pure-Ruby paths, so the two stay behavior-identical.

## License

Available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
