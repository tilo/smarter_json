
### Contents

  * [**Introduction**](./_introduction.md)
  * [The Basic Read API](./basic_read_api.md)
  * [The Basic Write API](./basic_write_api.md)
  * [Configuration Options](./options.md)
  * [Examples](./examples.md)

--------------

# SmarterJSON Introduction

`smarter_json` is a fast, lenient JSON processor for Ruby. It reads strict JSON, JSON5, HJSON-style config, newline-delimited JSON (NDJSON / JSONL), markdown-wrapped / chatty blobs around a JSON payload, and the messy JSON-ish input humans actually paste — and in benchmarks it matches or beats Oj on nearly every file. It is opinionated: it optimizes for getting your data out, not for policing the JSON spec. Where other parsers stop at the first deviation, SmarterJSON keeps going.

## Why another JSON library?

Most JSON parsers reject anything that isn't perfectly strict JSON, and they make you tell them up front what shape the input is. SmarterJSON is built on the opposite principle: **you shouldn't have to care what flavor of JSON you were handed.** Give it strict JSON, JSON5, an HJSON-style config file, several concatenated documents, or a copy-pasted blob with comments and trailing commas — it just reads it.

## What sets it apart

* **One reader, no modes, no flags.** There is no `dialect:` option and no "strict mode" — `SmarterJSON.process(input)` accepts the whole superset, and strict JSON is simply the narrowest case. You don't configure the reader to match your input; it adapts to whatever you give it.

* **It reads multi-document input automatically — a distinguishing feature.** `SmarterJSON.process` handles NDJSON / JSONL / concatenated JSON with **no block and no special method**: zero documents returns `nil`, one document returns its value, two or more return an `Array`. The same rule applies when wrapper noise is stripped and several payloads are recovered from one blob. **Only SmarterJSON reads multi-document input via plain `process` — Oj and the stdlib `json` library raise without a block.** For input larger than memory, pass a block to stream one document at a time. See [The Basic Read API](./basic_read_api.md).

* **It's fast.** A C extension (with a pure-Ruby fallback that runs everywhere) puts it ahead of Oj on nearly every file we benchmark, and competitive with the stdlib `json` C parser. Floats are decoded with Ryū (correctly rounded, single-pass), so number-heavy data is fast and bit-exact.

* **It writes JSON too.** `SmarterJSON.generate` turns Ruby values into strict, interoperable JSON — or into NDJSON, one element per line, the exact inverse of reading NDJSON back into an Array. See [The Basic Write API](./basic_write_api.md).

## What it accepts, beyond strict JSON

* `//`, `/* … */`, and `#` comments (a `#`/`//` only starts a comment when preceded by whitespace, so `url: http://x.com` reads as a string, not a truncated value)
* Trailing commas; unquoted keys (`{host: localhost}`); single-quoted, triple-quoted (`'''…'''`), and quoteless string values
* Implicit root object — a config file that starts with `key: value`, no outer `{}`
* `NaN`, `Infinity`, hex (`0xFF`), leading `+` / `.`, underscores in numbers (`1_000_000`)
* UTF-8 BOM, smart/curly quotes, Python literals (`True` / `False` / `None`), JavaScript `undefined`
* Mixed CR / LF / CRLF line endings, and any Ruby-supported input encoding (via `encoding:`)
* Duplicate keys (last value wins by default; configurable — see [Configuration Options](./options.md))

It raises only on genuinely unreadable input (unterminated string, mismatched bracket), with line and column in the message — never on valid-but-lenient input.

## Nesting & untrusted input

Both the C extension and the pure-Ruby engine are **iterative, not recursive** — they track nesting on an explicit, heap-allocated stack rather than the call stack. So deeply nested input **cannot overflow the call stack or segfault**: nesting is bounded only by available memory, the same posture as Oj (the stdlib `json` caps at 100). The trade-off: there is currently **no fixed nesting or input-size limit**, so size-limit untrusted input upstream.

---------------

NEXT: [The Basic Read API](./basic_read_api.md) | UP: [README](../README.md)
