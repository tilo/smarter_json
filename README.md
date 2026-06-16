# SmarterJSON

![Gem Version](https://img.shields.io/gem/v/smarter_json) [![codecov](https://codecov.io/gh/tilo/smarter_json/branch/main/graph/badge.svg)](https://codecov.io/gh/tilo/smarter_json) <!-- [![Downloads](https://img.shields.io/gem/dt/smarter_json)](https://rubygems.org/gems/smarter_json) --> [![RubyGems](https://img.shields.io/badge/RubyGems-smarter__json-brightgreen?logo=rubygems&logoColor=white)](https://rubygems.org/gems/smarter_json) [![Ruby Toolbox](https://img.shields.io/badge/Ruby%20Toolbox-smarter__json-brightgreen)](https://www.ruby-toolbox.com/projects/smarter_json)

A lenient, fast JSON processor for Ruby. It extracts strict JSON, NDJSON, JSONL, JSON5, HJSON-style config, and the messy JSON-ish input humans actually write — and in benchmarks it matches or beats Oj on every file. SmarterJSON is opinionated: we want your JSON processing to be successful. Traditional JSON parsers are strict - they stop at the first deviation - SmarterJSON keeps going - it optimizes for getting your data out, not for policing the JSON spec.

> **SmarterJSON: one tool, no modes — want strict? Please use the stdlib `json` gem.**

## Features at a glance

- **Reads the whole human-JSON superset, no modes or flags** — strict JSON, NDJSON, JSONL, JSON5, HJSON, JSONC, plus comments, trailing commas, unquoted / single / triple / smart quotes, an implicit root object, `NaN` / `Infinity` / hex / underscores, Python / JavaScript / SQL literals, a UTF-8 BOM, mixed line endings, and any Ruby encoding (see [What it accepts](#what-it-accepts-beyond-strict-json) for the full list).
- **Every document from multi-document input, in one call** — `process` returns an `Array` of all of them; `process_one` returns the single value and warns if there was more than one (never raises; routed to `on_warning`, else `Rails.logger`, else `Kernel.warn`).
- **Streaming in bounded memory** — pass a block, or use `foreach(path_or_io)` for a composable `Enumerator` you can `.select` / `.map` / `.lazy` over.
- **Recovers JSON from LLM / markdown noise** — strips markdown code fences, surrounding prose, and `<json>` tags, and pulls every payload out of one messy blob.
- **Writes JSON too** — `generate` with pretty-printing, NDJSON, `sort_keys`, `ascii_only`, `script_safe`, `allow_nan`, and `coerce` (via `as_json`); iterative, so deeply nested data is depth-safe.
- **Keeps number precision** — `BigDecimal` by default (Oj-compatible), or `:float` / `:auto`.
- **Transparent leniency** — pass an optional `on_warning` callback to be handed every lenient fix (an empty slot collapsed, a duplicate key dropped, a code fence stripped, …); with no handler the parser stays silent and adds zero overhead.
- **Fast, and runs everywhere** — a C extension that matches or beats Oj, with a pure-Ruby fallback for platforms that can't build it. Stable, semantically versioned, thread-safe, Ruby 2.6+.

## Why SmarterJSON?

> 📖 **The thinking behind it:** [*Strict by Accident: Your JSON parser isn't broken, it's answering the wrong question*](https://dev.to/tilo_sloboda/strict-by-accident-your-json-parser-isnt-broken-its-answering-the-wrong-question-54f0) — why a data pipeline wants a lenient, recovery-first parser rather than a spec-policing one.

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
Give it strict JSON, NDJSON, JSONL, JSON5, an HJSON-style config file, LLM-generated JSON, or a copy-pasted blob with comments and trailing commas — it just extracts the data from it.
When it is lenient, `smarter_json` isn't dropping data that exists — it's just not raising an eyebrow at a suspicious gap (like an extra comma).

A strict parser would refuse the whole document and recover nothing; `smarter_json` returns everything except the formatting error.

> For an ingestion tool, "reject the whole document because of one stray comma" is the worst outcome: you throw away the 99% that's fine to avoid maybe-mishandling a gap that carries no data anyway.

Three things set it apart:

1. **One tool, no modes, no flags.** There is no `dialect:` option and no "strict mode" — `SmarterJSON.process(input)` accepts the whole superset, and strict JSON is simply the narrowest case. You don't configure it to match your input; it adapts to whatever you give it.

2. **It extracts every document from multi-document input automatically — a distinguishing feature.** `SmarterJSON.process` handles NDJSON / JSONL / concatenated JSON with **no block and no special method**: it always returns an `Array` of the documents found (`[]` / `[doc]` / `[d1, d2, …]`). For the common single-document case, `SmarterJSON.process_one` returns the one value directly (and warns, never raises, if there was more than one). The same rule applies when wrapper noise is stripped and several payloads are recovered from one blob. **Only SmarterJSON reads multi-document input via plain `process` — Oj and the stdlib `json` library raise without a block.** For input larger than memory, pass a block to stream one document at a time.

3. **It's fast.** A C extension (with a pure-Ruby fallback that runs everywhere) matches or beats Oj on every file we benchmark, and is competitive with the stdlib `json` C parser — among the fastest general-purpose JSON processors in Ruby.

## What it accepts, beyond strict JSON

- `//`, `/* … */`, and `#` comments (a `#`/`//` only starts a comment when preceded by whitespace, so `url: http://x.com` is read as a string, not a truncated value)
- Markdown-wrapped / chatty blobs around the payload: strips ```` ```json ```` / ```` ``` ```` fences, ignores obvious prose before/after the payload, unwraps `<json>...</json>` and `BEGIN_JSON ... END_JSON`, and preserves multiple recovered payloads as an Array
- Trailing commas; unquoted keys (`{host: localhost}`); single-quoted, triple-quoted (`'''…'''`), and quoteless string values
- Full JSON5 / ECMAScript string escapes — `\uXXXX` (with surrogate pairs), `\xHH` (`"\x41"` → `"A"`), `\v`, `\0`, line continuation; an unrecognized escape yields the character itself (`"\q"` → `"q"`)
- Implicit root object — a config file that starts with `key: value`, no outer `{}`
- `NaN`, `Infinity`, hex (`0xFF`), leading `+` / `.`, underscores in numbers (`1_000_000`)
- Leading-zero numbers (which strict JSON rejects): a token with a sign, decimal point, or exponent reads as a number (`-007.5` → `-7.5`, `007e2` → `700.0`), but a bare leading-zero integer is kept as a string (`007`, `02`) so IDs, zip codes, and account numbers don't lose their zeros
- UTF-8 BOM, smart/curly quotes (in keys and values), Python literals (`True` / `False` / `None`), JavaScript `undefined`, case-variant null (`Null` / `NULL`, as SQL / R / PHP / YAML emit it)
- Mixed CR / LF / CRLF line endings, and any Ruby-supported input encoding (via `encoding:`)
- Duplicate keys (last value wins by default; configurable)

It raises only on genuinely unreadable input (unterminated string, mismatched bracket), with line and column in the message — never on valid-but-lenient input.

### Format references

The lenient grammar is a superset of these human-JSON specs — listed once, here:

* [JSON5](https://json5.org/)
* [HJSON](https://hjson.github.io/) <sup>†</sup>
* [JWCC / HuJSON](https://github.com/tailscale/hujson)
* [Nigel Tao](https://nigeltao.github.io/blog/2021/json-with-commas-comments.html)
* [JSONH](https://github.com/jsonh-org/Jsonh) <sup>‡</sup>
* [JSONC (VS Code)](https://jsonc.org/)
* [NDJSON / JSON Text Sequences (RFC 7464)](https://datatracker.ietf.org/doc/html/rfc7464).

HJSON and JSONH are deliberate subsets. SmarterJSON is one deterministic, no-modes superset of the JSON-family dialects (JSON5 / HJSON / JSONC / …), so it adopts a feature only where it does not conflict with the others.

<sup>†</sup>From **HJSON** we leave out unquoted *multi-line* strings — its quoteless string values are single-line (use a quoted or triple-quoted `'''…'''` string for multiline), because a newline-spanning unquoted string collides with newline-as-a-document-separator (NDJSON, implicit-root config).

<sup>‡</sup>From **JSONH** we take the mainstream features (quoteless keys / values, optional commas between newline-separated members, comments, hex numbers) but **not** the idiosyncratic extensions: binary (`0b`) / octal (`0o`) number literals, verbatim strings (`@"…"`), nestable block comments (`/=* *=/`), or its `\e` / `\a` escapes — the last conflict with the JSON5 / ECMAScript rule that an unrecognized escape is the character itself (`"\e"` → `"e"`). Tip: you can use quoteless strings instead of verbatim strings. Want binary or octal literals? Open an issue.

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

The public interface is: `SmarterJSON.process`, `SmarterJSON.process_one`, `SmarterJSON.process_file`, `SmarterJSON.foreach`, `SmarterJSON.generate`, and the documented options in this README/docs are the supported surface. `SmarterJSON.process` and `SmarterJSON.process_file` always return an `Array` of documents; `process_one` returns the single document's value (or `nil`), and emits a warning if there is more than one doc.

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

SmarterJSON is a C extension (with a pure-Ruby fallback that runs everywhere). Before the speed table, the part that isn't a "× faster" — **things the other parsers can't do at all:**

- **stdlib `json` can't parse deeply nested data.** It caps nesting at 100 levels and raises; SmarterJSON has no depth limit (iterative parser, bounded only by memory).
- **None of the others read NDJSON / JSONL / concatenated input in a single call.** Oj, `json`, and Yajl each raise on the second document. Only SmarterJSON's `process` returns every document as an `Array`.
- **None of the others parse JSON5, HJSON-style config, or LLM-wrapped output.** Comments, trailing commas, unquoted keys, quoteless values, `'single quotes'`, markdown code fences, prose wrappers — all raise in Oj / `json` / Yajl; SmarterJSON parses them.
- **`json` and Yajl produce `Float` only — lossy on high-precision numbers.** On coordinate / scientific data (>16 significant digits) they silently round to `Float`, so they aren't a like-for-like comparison there. SmarterJSON (and Oj) keep full precision as `BigDecimal` by default.

Where a like-for-like comparison exists, here is SmarterJSON's C path against each parser. **Apple M4, Ruby 3.4.7, p10 of 40 runs (2026-06-07); the same picture holds on an Apple M1 Max.** Each cell is **SmarterJSON vs that parser** — "faster" means SmarterJSON wins. Ratios shift with hardware; run `rake report` in `json_benchmarks/` to reproduce.

| File                          | vs Oj/strict    | vs `json`                    | vs Yajl         |
| ----------------------------- | --------------- | ---------------------------- | --------------- |
| big_decimals <sup>≠</sup>     | **1.7× faster** | ≈ tied                       | **1.2× faster** |
| canada <sup>≠</sup>           | **7× faster**   | ≈ tied                       | **2.1× faster** |
| citm_catalog                  | **1.3× faster** | 1.2× slower                  | **3.2× faster** |
| citylots <sup>≠</sup>         | **3.7× faster** | **2.0× faster**              | **2.3× faster** |
| config.jsonc                  | **1.1× faster** | 1.2× slower                  | **3.6× faster** |
| deeply_nested                 | **1.2× faster** | **can't parse** <sup>‡</sup> | **4.1× faster** |
| github_events                 | ≈ tied          | 1.1× slower                  | **2.7× faster** |
| string_array                  | ≈ tied          | ≈ tied                       | **1.6× faster** |
| twitter                       | **1.3× faster** | 1.2× slower                  | **3.2× faster** |
| usgs_earthquakes <sup>≠</sup> | **1.4× faster** | 1.1× slower                  | **3.4× faster** |
| weather_berlin                | **1.8× faster** | **1.1× faster**              | **3.2× faster** |

<sup>≠</sup> High-precision file. The row uses `decimal_precision: :float` (Float, like-for-like) for `canada` / `citylots` / `big_decimals` / `usgs`. SmarterJSON's **default** `:auto` keeps these decimals as `BigDecimal` (no precision loss, like Oj's default) — intrinsically slower than `Float`, so default-vs-`Float` would be apples-to-oranges. Against Oj's matching `BigDecimal` default, SmarterJSON is faster there too.
<sup>‡</sup> Not a measurement gap — `json` raises by default: it errors on multi-document / NDJSON input without a block, and caps nesting at 100 levels. SmarterJSON has neither limit.

In short: **SmarterJSON's C path matches or beats Oj/strict on every file** (apples-to-apples — for the high-precision <sup>≠</sup> files that means `decimal_precision: :float`, where Oj/strict also produces `Float`; with `:float`, float-heavy data like `canada` is **~7× faster**). It is **far faster than Yajl everywhere**, and **level-to-ahead of stdlib `json`** — `json` edges ahead only on a few object-heavy files (`citm`, `twitter`, `config.jsonc`, `github_events`, all within ~1.25×) and **can't parse `deeply_nested` at all**. Floats are decoded with the **Eisel-Lemire** algorithm (fast_float), correctly rounded and **bit-for-bit identical to `JSON.parse`** — fast *and* exact, even at full double precision.

**Two notes on fair comparison:**

- **NDJSON / multi-document:** only SmarterJSON reads it via plain `process` — Oj, `json`, and Yajl raise without a block. `process` collects every document into an `Array`; the block form streams one document at a time in bounded memory (use it for input larger than RAM).
- **High-precision decimals (the <sup>≠</sup> files):** by default these load as `BigDecimal` (full precision, like Oj's default), intrinsically slower than `Float`. Pass `decimal_precision: :float` for a like-for-like `Float` comparison — where SmarterJSON **beats stdlib `json`** (e.g. `citylots` ~2×) — at 3–6× the speed of the `:auto` default on coordinate/scientific data, when you don't need `BigDecimal` precision.


### Options

| option            | default      | meaning                                                                 |
|-------------------|--------------|-------------------------------------------------------------------------|
| `symbolize_keys`  | `false`      | return object keys as Symbols instead of Strings                        |
| `duplicate_key`   | `:last_wins` | `:last_wins` / `:first_wins` for a key repeated in one object (every repeat is also reported via `on_warning`) |
| `decimal_precision` | `:auto`      | `:auto` keeps high-precision decimals as `BigDecimal`; `:float` forces `Float`; `:bigdecimal` forces `BigDecimal` |
| `acceleration`    | `true`       | `true` uses the C extension when compiled and loadable; `false` forces pure Ruby (identical results) |
| `encoding`        | `nil`        | labels the input's encoding; `nil` keeps the input's own (no transcoding pass; see below) |
| `on_warning`      | `nil`        | a callable invoked once per lenient fix applied (`:empty_slot`, `:empty_value`, `:duplicate_key`, `:number_overflow`), passed a `SmarterJSON::Warning`; the return value is never changed. See below. |

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

**Try it on a file you already have.** SmarterJSON reads **NDJSON / JSONL natively** — and Claude Code stores every session as a JSONL transcript (`~/.claude/projects/<project>/<session-id>.jsonl`, one JSON document per line). Walk yours, one record at a time:

```ruby
require "awesome_print" # optional — readable nested output

SmarterJSON.process_file("#{Dir.home}/.claude/projects/<project>/<session-id>.jsonl") do |entry|
  ap entry              # each line is a full document — a message, a tool call, a result, …
  puts "-" * 80
end
```

### Filtering and rewriting a large file (`foreach`)

`SmarterJSON.foreach(source)` is the composable sibling of `process_file`. `source` is a file path or any IO (a socket, a `StringIO`, an open `File`). With no block it returns a plain `Enumerator` (like `CSV.foreach`) that reads one document at a time, so you can chain `.select` / `.map` and friends. Add `.lazy` to keep the whole chain bounded in memory, even when the filtered set is large:

```ruby
# Keep only the user/assistant turns of a transcript — one document in memory at a time
SmarterJSON.foreach("session.jsonl", symbolize_keys: true)
           .lazy
           .select { |doc| %w[user assistant].include?(doc[:type]) }
           .each   { |doc| puts doc[:text] }
```

Because it streams both ends, you can **filter a big file down and rewrite it** without ever loading the whole thing:

```ruby
File.open("filtered.jsonl", "w") do |out|
  SmarterJSON.foreach("session.jsonl", symbolize_keys: true)
             .lazy
             .select { |doc| %w[user assistant].include?(doc[:type]) }
             .each   { |doc| out.puts SmarterJSON.generate(doc) }
end
```

Pass an IO instead of a path to stream straight from a socket or an HTTP response body — anything `IO`-like works (an IO is single-pass, read once):

```ruby
SmarterJSON.foreach(response_io).each { |event| handle(event) }
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

`encoding:` (default `nil`) labels what the input is — it does **not** transcode. With `nil`, SmarterJSON keeps the input's own encoding tag and emits string values with that same tag, the way `smarter_csv` does — **with one smart default:** input tagged `ASCII-8BIT` (BINARY) whose bytes are valid UTF-8 is treated as UTF-8. That is exactly how `Net::HTTP` and many HTTP libraries hand you a `response.body` (correct UTF-8 bytes, BINARY tag); without this, string values would come back tagged `ASCII-8BIT` and compare unequal to UTF-8 literals. If such `ASCII-8BIT` input is *not* valid UTF-8, it raises `SmarterJSON::EncodingError` rather than guess a legacy encoding — pass an explicit `encoding:` (e.g. `"ISO-8859-1"`) for that. Bytes invalid for an explicitly claimed encoding also raise `SmarterJSON::EncodingError` (a kind of `SmarterJSON::ParseError`).

## Nesting & untrusted input

Both the C extension and the pure-Ruby engine are **iterative, not recursive** — they track nesting on an explicit, heap-allocated stack rather than the call stack. So deeply nested input **cannot overflow the call stack or segfault**: nesting is bounded only by available memory, the same posture as Oj (which also ships no nesting limit; the stdlib `json` caps at 100). The `deeply_nested.json` benchmark (212 MB of nesting) is handled without issue. **`generate` is iterative too**, so serializing a deeply nested Ruby structure can't overflow the stack either — reading *and* writing are both depth-safe.

The trade-off: there is currently **no fixed nesting or input-size limit**, so extremely large or adversarially-nested untrusted input is bounded by memory (it can exhaust RAM), not by a crash. If you process untrusted input and want a hard cap, that's a planned opt-in guard — for now, size-limit upstream.


# [A Special Thanks to all Contributors!](CONTRIBUTORS.md) 🎉🎉🎉

## Development

After checking out the repo, run `bin/setup` to install dependencies, then `rake compile` to build the C extension and `rake spec` to run the tests. The test suite runs every example against **both** the C and pure-Ruby paths, so the two stay behavior-identical.

## License

Available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
