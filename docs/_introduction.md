
### Contents

  * [**Introduction**](./_introduction.md)
  * [The Basic Read API](./basic_read_api.md)
  * [The Basic Write API](./basic_write_api.md)
  * [Configuration Options](./options.md)
  * [Examples](./examples.md)

--------------

# SmarterJSON Introduction

`smarter_json` is a fast, lenient JSON processor for Ruby. It reads strict JSON, JSON5, HJSON-style config, newline-delimited JSON (NDJSON / JSONL), markdown-wrapped / chatty blobs around a JSON payload, and the messy JSON-ish input humans actually paste — and in benchmarks it matches or beats Oj on every file. It is opinionated: it optimizes for getting your data out, not for policing the JSON spec. Where other parsers stop at the first deviation, SmarterJSON keeps going.

## Why another JSON library?

Most JSON parsers reject anything that isn't perfectly strict JSON, and they make you tell them up front what shape the input is. SmarterJSON is built on the opposite principle: **you shouldn't have to care what flavor of JSON you were handed.** Give it strict JSON, JSON5, an HJSON-style config file, several concatenated documents, or a copy-pasted blob with comments and trailing commas — it just reads it.

## What sets it apart

* **One reader, no modes, no flags.** There is no `dialect:` option and no "strict mode" — `SmarterJSON.process(input)` accepts the whole superset, and strict JSON is simply the narrowest case. You don't configure the reader to match your input; it adapts to whatever you give it.

* **It reads multi-document input automatically — a distinguishing feature.** `SmarterJSON.process` handles NDJSON / JSONL / concatenated JSON with **no block and no special method**: it always returns an `Array` of the documents found (`[]` / `[doc]` / `[d1, d2, …]`). For the common single-document case, `SmarterJSON.process_one` returns the one value directly (and warns, never raises, if there was more than one). The same rule applies when wrapper noise is stripped and several payloads are recovered from one blob. **Only SmarterJSON reads multi-document input via plain `process` — Oj and the stdlib `json` library raise without a block.** For input larger than memory, pass a block to stream one document at a time. See [The Basic Read API](./basic_read_api.md).

* **It's fast.** The C extension (with a pure-Ruby fallback that runs everywhere) is **faster than Oj/strict on every file** in our benchmark suite — up to **~7× faster on float-heavy data** with `decimal_precision: :float` — **far faster than Yajl**, and **level-to-ahead of the stdlib `json` C parser**, which can't even parse deeply-nested input. Floats are decoded with the **Eisel-Lemire** algorithm (fast_float), correctly rounded and bit-for-bit identical to `JSON.parse`, so number-heavy data is fast and exact. Full per-file numbers (Apple M4 / M1, relative ratios) are in the [README Performance section](../README.md#performance).

* **It writes JSON too.** `SmarterJSON.generate` turns Ruby values into strict, interoperable JSON — or into NDJSON, one element per line, the exact inverse of reading NDJSON back into an Array. See [The Basic Write API](./basic_write_api.md).

## What it accepts, beyond strict JSON

Comments (`//`, `/* … */`, `#` — a `#`/`//` only starts a comment when preceded by whitespace, so `url: http://x.com` reads as a string, not a truncated value), markdown-wrapped / chatty blobs around the payload, trailing commas, unquoted / single- / triple-quoted / quoteless strings, full JSON5 / ECMAScript string escapes (`\xHH`, `\v`, `\0`, line continuation, and an unknown escape yields the character itself), an implicit root object (`key: value`, no braces), `NaN` / `Infinity` / hex / underscored numbers, leading-zero numbers (a signed / decimal / exponent token like `-007.5` is a number, a bare `007` is kept as a string so IDs keep their zeros), Python (`True` / `False` / `None`), JavaScript (`undefined`), and SQL / R / PHP / YAML (`Null` / `NULL`) literals, smart quotes, a UTF-8 BOM, mixed CR / LF / CRLF line endings, any Ruby-supported input encoding (via `encoding:`), and duplicate keys. The full list — with the human-JSON spec references it's drawn from — is kept in one place: [**What it accepts, beyond strict JSON**](../README.md#what-it-accepts-beyond-strict-json) in the README.

It raises only on genuinely unreadable input (unterminated string, mismatched bracket), with line and column in the message — never on valid-but-lenient input.

## Nesting & untrusted input

Both the C extension and the pure-Ruby engine are **iterative, not recursive** — they track nesting on an explicit, heap-allocated stack rather than the call stack. So deeply nested input **cannot overflow the call stack or segfault**: nesting is bounded only by available memory, the same posture as Oj (the stdlib `json` caps at 100). The trade-off: there is currently **no fixed nesting or input-size limit**, so size-limit untrusted input upstream.

---------------

NEXT: [The Basic Read API](./basic_read_api.md) | UP: [README](../README.md)
