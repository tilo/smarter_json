
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

`process` is polymorphic: its first argument is **either a String of JSON content or an IO to read from**. A String is always treated as content, never as a filename — use `process_file` for paths. When the input wraps the payload in obvious markdown / prose / tags, `process` strips that wrapper first and then parses the recovered payload(s).

```ruby
SmarterJSON.process(<<~TEXT)
  Here is the JSON:

  ```json
  {
    "a": 1
  }
  ```
TEXT
# => {"a"=>1}

SmarterJSON.process(<<~TEXT)
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
```

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

Documents are separated by whitespace, newlines, or simple concatenation — **not** by commas (a comma between top-level documents would be read as an implicit root array, which is not supported). If wrapper noise is stripped and several payloads are recovered, they are returned by the same rule: one payload → its value, several → an `Array`. Only SmarterJSON reads this via plain `process`: Oj and the stdlib `json` library raise without a block.

## `SmarterJSON.process_file` — read a file by path

```ruby
SmarterJSON.process_file("config.json5")     # read the file, then parse — same return-value rules as process
```

`process_file` opens the file, reads it with the labeled [`encoding:`](./options.md) (default `"UTF-8"`, no transcoding pass), and parses it.

## Streaming with a block (bounded memory)

For input larger than memory, pass a block. Each recovered top-level document is yielded as it is framed, and the method returns `nil` instead of collecting the documents into an Array. Both `process` and `process_file` forward the block.

```ruby
SmarterJSON.process_file("events.ndjson") { |event| EventJob.perform_async(event) }
SmarterJSON.process(io) { |doc| handle(doc) }
```

The streaming path now frames whole top-level documents, not just one line at a time. That means NDJSON / JSONL still work, but pretty-printed multi-line objects and arrays work too, as do mixed `\n` / `\r\n` / `\r` line endings and comment-only separators between documents.

## The C extension and the pure-Ruby fallback

By default (`acceleration: true`) the C extension is used when it is compiled and loadable (`SmarterJSON::HAS_ACCELERATION` is then `true`); otherwise the pure-Ruby parser runs and produces identical results. Pass `acceleration: false` to force the pure-Ruby path. See [Configuration Options](./options.md).

## Seeing what was fixed: `on_warning:`

`process` and `process_file` are lenient — they salvage your data rather than reject a whole document over a stray comma. Pass an `on_warning:` callable to also get a record of what was adjusted, so the leniency is transparent instead of silent. It is invoked once per fix and never changes the return value:

```ruby
warns = []
result = SmarterJSON.process("[1,,2]", on_warning: ->(w) { warns << w })
result            # => [1, 2]
warns.map(&:type) # => [:empty_slot]
warns.first.to_s  # => "extra comma, collapsed an empty slot at line 1, col 4"
```

Each warning is a `SmarterJSON::Warning` with `type`, `message`, `line`, and `col`. The types are `:empty_slot` (a collapsed empty comma slot), `:empty_value` (a key with no value, read as `null`), `:duplicate_key` (a repeated key that was dropped), plus wrapper-recovery warnings such as `:code_fence_stripped`, `:prefix_text_ignored`, `:suffix_text_ignored`, and `:wrapper_tag_stripped`. Clean input never invokes the handler. It fires on every path — including the streaming block form — and works the same on the C and pure-Ruby paths. See [Configuration Options](./options.md).

---------------

PREVIOUS: [Introduction](./_introduction.md) | NEXT: [The Basic Write API](./basic_write_api.md) | UP: [README](../README.md)
