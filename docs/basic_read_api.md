
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

SmarterJSON.process('{"a": 1, "b": [2, 3]}')          # => {"a"=>1, "b"=>[2, 3]}
SmarterJSON.process("host: localhost\nport: 5432")     # => {"host"=>"localhost", "port"=>5432}  (no braces needed)
```

`process` is polymorphic: its first argument is **either a String of JSON content or an IO to read from**. A String is always treated as content, never as a filename — use `process_file` for paths.

```ruby
SmarterJSON.process(io)         # an open IO (File, StringIO, socket, …) — reads it and parses
SmarterJSON.process(some_string) # JSON content
```

### Return value depends on how many documents the input holds

This is the distinguishing feature: `process` reads multi-document input (NDJSON / JSONL / concatenated / whitespace-separated) automatically, with no block and no special method.

```ruby
SmarterJSON.process("")                                 # => nil          (zero documents)
SmarterJSON.process('{"id":1}')                          # => {"id"=>1}    (one document → the value itself)
SmarterJSON.process(%({"id":1}\n{"id":2}\n{"id":3}))     # => [{"id"=>1}, {"id"=>2}, {"id"=>3}]  (two or more → an Array)
```

Documents are separated by whitespace, newlines, or simple concatenation — **not** by commas (a comma between top-level documents would be read as an implicit root array, which is not supported). Only SmarterJSON reads this via plain `process`: Oj and the stdlib `json` library raise without a block.

## `SmarterJSON.process_file` — read a file by path

```ruby
SmarterJSON.process_file("config.json5")     # read the file, then parse — same return-value rules as process
```

`process_file` opens the file, reads it with the labeled [`encoding:`](./options.md) (default `"UTF-8"`, no transcoding pass), and parses it.

## Streaming with a block (bounded memory)

For input larger than memory, pass a block. Each top-level document is yielded as it is read, and the method returns `nil` (it never collects the documents into an Array). Both `process` and `process_file` forward the block.

```ruby
# Stream straight from disk, one document at a time — the whole file is never loaded:
SmarterJSON.process_file("events.ndjson") { |event| EventJob.perform_async(event) }

# Same for an IO:
SmarterJSON.process(io) { |doc| handle(doc) }
```

The streaming path reads the input as newline-delimited documents (NDJSON / JSONL), one document per line. A single document that spans multiple lines is not supported by the streaming path — read it without a block instead.

## The C extension and the pure-Ruby fallback

By default (`acceleration: :auto`) the C extension is used when it is compiled and loadable (`SmarterJSON::HAS_ACCELERATION` is then `true`); otherwise the pure-Ruby parser runs and produces identical results. Pass `acceleration: false` to force the pure-Ruby path. See [Configuration Options](./options.md).

---------------

PREVIOUS: [Introduction](./_introduction.md) | NEXT: [The Basic Write API](./basic_write_api.md) | UP: [README](../README.md)
