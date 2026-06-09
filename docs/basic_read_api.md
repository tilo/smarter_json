
### Contents

  * [Introduction](./_introduction.md)
  * [**The Basic Read API**](./basic_read_api.md)
  * [The Basic Write API](./basic_write_api.md)
  * [Configuration Options](./options.md)
  * [Examples](./examples.md)

--------------

# SmarterJSON Basic Read API

Reading JSON has one entry point for content and one for files. Both accept the same [options](./options.md), and both take an optional block for streaming.

## `SmarterJSON.process` — read a String or an IO

```ruby
require "smarter_json"

SmarterJSON.process('{"a": 1, "b": [2, 3]}')          # => [{"a"=>1, "b"=>[2, 3]}]   (always an Array of documents)
SmarterJSON.process_one('{"a": 1, "b": [2, 3]}')      # => {"a"=>1, "b"=>[2, 3]}     (the single document's value)
SmarterJSON.process_one("host: localhost\nport: 5432") # => {"host"=>"localhost", "port"=>5432}  (no braces needed)
```

`process` accepts **either a String of JSON content or an IO to read from** as its first argument. A String is always treated as content, never as a filename — use `process_file` for paths. When the input wraps the payload in obvious markdown / prose / tags, `process` strips that wrapper first and then reads the recovered payload(s).

````ruby
SmarterJSON.process_one(<<~TEXT)
  Here is the JSON:

  ```json
  {
    "a": 1
  }
  ```
TEXT
# => {"a"=>1}

SmarterJSON.process_one(<<~TEXT)
  Here is the result:

  {
    "a": 1
  }

  Hope this helps.
TEXT
# => {"a"=>1}

SmarterJSON.process(<<~TEXT)
  first attempt:
  {"a":1}

  corrected payload:
  {"b":2}
TEXT
# => [{"a"=>1}, {"b"=>2}]
````

```ruby
SmarterJSON.process(io)         # an open IO (File, StringIO, socket, …) — reads it and extracts the data
SmarterJSON.process(some_string) # JSON content
```

### `process` always returns an Array of documents

This is the distinguishing feature: `process` reads multi-document input (NDJSON / JSONL / concatenated) automatically, with no block and no special method, and **always returns an `Array` of the documents** it found:

```ruby
SmarterJSON.process("")                                 # => []            (zero documents)
SmarterJSON.process('{"id":1}')                          # => [{"id"=>1}]   (one document, still an Array)
SmarterJSON.process(%({"id":1}\n{"id":2}\n{"id":3}))     # => [{"id"=>1}, {"id"=>2}, {"id"=>3}]
```

For the common single-document case, **`process_one`** returns the one value directly — and *warns* (never raises) if there was more than one, so a stray extra document is never dropped silently:

```ruby
SmarterJSON.process_one('{"id":1}')   # => {"id"=>1}
SmarterJSON.process_one("")           # => nil
```

> Type-checking the result? Use `result.is_a?(Array)`, not `result.class == Array` — idiomatic, and future-proof if the return ever becomes a specialized `Array` subclass.

Documents are separated by **newlines, commas, RS (0x1E), or simple concatenation (self-delimiting values)** — **never by a space**. A top-level value must be a recognized JSON value (number / `true` / `false` / `null` / quoted string / object / array) or an implicit-root object (`host: localhost`); a bare top-level run such as `localhost` or `1 2 3` raises `ParseError`. (Quoteless string values *inside* objects and arrays are unchanged.) If wrapper noise is stripped and several payloads are recovered, they come back by the same rule — an `Array` of payloads (`process_one` returns the first). Only SmarterJSON reads multi-document input via plain `process`: Oj and the stdlib `json` library raise without a block.

## `SmarterJSON.process_file` — read a file by path

```ruby
SmarterJSON.process_file("config.json5")     # read the file, then process — same return-value rules as process
```

`process_file` opens the file, reads it with the labeled [`encoding:`](./options.md) (default `"UTF-8"`, no transcoding pass), and processes it.

## Streaming with a block (bounded memory)

For input larger than memory, pass a block. Each recovered top-level document is yielded as it is framed, and the method returns the **document count** instead of collecting the documents into an Array. Both `process` and `process_file` forward the block.

```ruby
SmarterJSON.process_file("events.ndjson") { |event| EventJob.perform_async(event) }
SmarterJSON.process(io) { |doc| handle(doc) }
```

The streaming path now frames whole top-level documents, not just one line at a time. That means NDJSON / JSONL still work, but pretty-printed multi-line objects and arrays work too, as do mixed `\n` / `\r\n` / `\r` line endings and comment-only separators between documents.

## `SmarterJSON.foreach` — stream a file or IO, composably

`foreach` is the composable sibling of `process_file`. Its argument is a **file path or any IO** (a socket, a `StringIO`, an open `File`); a String is always a path, never content.

With a block it behaves exactly like the block form above — streams each document, returns the **document count**. Without a block it returns a plain `Enumerator` (like `CSV.foreach` — **not** an `Enumerator::Lazy`), so `.map` / `.select` return Arrays the usual way, and you can chain over the stream:

```ruby
SmarterJSON.foreach("events.ndjson").each { |event| EventJob.perform_async(event) }   # like the block form
SmarterJSON.foreach("events.ndjson").select { |e| e["level"] == "error" }              # => an Array of the matches
```

It reads one document at a time, so `foreach(path).first(3)` only reads ~3 documents off disk, and `.next` pulls them one by one. `.map` / `.select` read the source lazily but still build an Array of their *result*; to keep a whole pipeline bounded end to end (a large filtered set off a fat file), add `.lazy` at the call site:

```ruby
SmarterJSON.foreach("session.jsonl", symbolize_keys: true)
           .lazy
           .select { |doc| %w[user assistant].include?(doc[:type]) }
           .each   { |doc| puts doc[:text] }
```

Options are validated eagerly — a bad option key or value raises immediately, before any iteration. An **IO source is single-pass** (an IO can only be read once), so iterating the returned Enumerator a second time over the same IO yields nothing; a path-backed `foreach` re-opens the file and is re-iterable.

## The C extension and the pure-Ruby fallback

By default (`acceleration: true`) the C extension is used when it is compiled and loadable (`SmarterJSON::HAS_ACCELERATION` is then `true`); otherwise the pure-Ruby implementation runs and produces identical results. Pass `acceleration: false` to force the pure-Ruby path. See [Configuration Options](./options.md).

## Seeing what was fixed: `on_warning:`

`process` and `process_file` are lenient — they salvage your data rather than reject a whole document over a stray comma. Pass an `on_warning:` callable to also get a record of what was adjusted, so the leniency is transparent instead of silent. It is invoked once per fix and never changes the return value:

```ruby
warns = []
result = SmarterJSON.process("[1,,2]", on_warning: ->(w) { warns << w })
result            # => [[1, 2]]   (one document: the array [1, 2] with the empty slot collapsed; process always returns an Array of documents)
warns.map(&:type) # => [:empty_slot]
warns.first.to_s  # => "extra comma, collapsed an empty slot at line 1, col 4"
```

Each warning is a `SmarterJSON::Warning` with `type`, `message`, `line`, and `col`. The types are `:empty_slot` (a collapsed empty comma slot), `:empty_value` (a key with no value, read as `null`), `:duplicate_key` (a repeated key that was dropped), plus wrapper-recovery warnings such as `:code_fence_stripped`, `:prefix_text_ignored`, `:suffix_text_ignored`, and `:wrapper_tag_stripped`. Clean input never invokes the handler. It fires on every path — including the streaming block form — and works the same on the C and pure-Ruby paths. See [Configuration Options](./options.md).

---------------

PREVIOUS: [Introduction](./_introduction.md) | NEXT: [The Basic Write API](./basic_write_api.md) | UP: [README](../README.md)
