
### Contents

  * [Introduction](./_introduction.md)
  * [The Basic Read API](./basic_read_api.md)
  * [The Basic Write API](./basic_write_api.md)
  * [Configuration Options](./options.md)
  * [**Examples**](./examples.md)

--------------

# Examples

**Rescue from `SmarterJSON::Error` (recommended):** SmarterJSON raises only on genuinely unreadable input (an unterminated string, a mismatched bracket), with line and column in the message. Rescuing from `SmarterJSON::Error` lets your application handle bad input gracefully.

---

1. [Read a JSON String](#example-1-read-a-json-string)
2. [Read a JSON File](#example-2-read-a-json-file)
3. [Implicit Root Object (config-style, no braces)](#example-3-implicit-root-object-config-style-no-braces)
4. [Multiple Documents (NDJSON) → Array](#example-4-multiple-documents-ndjson--array)
5. [Streaming a Large File with a Block](#example-5-streaming-a-large-file-with-a-block)
6. [Symbolize Keys](#example-6-symbolize-keys)
7. [Duplicate Keys](#example-7-duplicate-keys)
8. [High-Precision Numbers: BigDecimal vs Float](#example-8-high-precision-numbers-bigdecimal-vs-float)
9. [Lenient Input: Comments, Trailing Commas, Unquoted Keys](#example-9-lenient-input-comments-trailing-commas-unquoted-keys)
10. [Wrapper Noise Around a Payload](#example-10-wrapper-noise-around-a-payload)
11. [Write JSON](#example-11-write-json)
12. [Write NDJSON](#example-12-write-ndjson)
13. [Round-Trip Read and Write](#example-13-round-trip-read-and-write)

---

### Example 1: Read a JSON String

```ruby
require "smarter_json"

SmarterJSON.process('{"a": 1, "b": [2, 3]}')   # => {"a"=>1, "b"=>[2, 3]}
```

### Example 2: Read a JSON File

```ruby
SmarterJSON.process_file("config.json")        # => the extracted data
```

`process_file` opens the file, reads it with the labeled [`encoding:`](./options.md) (default `"UTF-8"`), and processes it.

### Example 3: Implicit Root Object (config-style, no braces)

A config file that starts with `key: value` and has no outer `{}` is read as an object:

```ruby
SmarterJSON.process("host: localhost\nport: 5432")   # => {"host"=>"localhost", "port"=>5432}
```

### Example 4: Multiple Documents (NDJSON) → Array

Plain `process` reads NDJSON / JSONL / concatenated documents with no block and no special method. Zero documents → `nil`, one → its value, two or more → an `Array`:

```ruby
SmarterJSON.process(%({"id":1}\n{"id":2}\n{"id":3}))   # => [{"id"=>1}, {"id"=>2}, {"id"=>3}]
SmarterJSON.process('{"id":1}')                          # => {"id"=>1}
SmarterJSON.process("")                                  # => nil
```

### Example 5: Streaming a Large File with a Block

For input larger than memory, pass a block. Each recovered document is yielded one at a time:

```ruby
SmarterJSON.process_file("events.ndjson") { |event| EventJob.perform_async(event) }
```

### Example 6: Symbolize Keys

```ruby
SmarterJSON.process('{"a": 1, "b": 2}', symbolize_keys: true)   # => {:a=>1, :b=>2}
```

### Example 7: Duplicate Keys

By default the last value wins. Pass `:first_wins` to keep the first instead (either way, the repeat is reported through [`on_warning`](./options.md)):

```ruby
SmarterJSON.process('{"a":1,"a":2}')                          # => {"a"=>2}   (:last_wins, the default)
SmarterJSON.process('{"a":1,"a":2}', duplicate_key: :first_wins)  # => {"a"=>1}
```

### Example 8: High-Precision Numbers: BigDecimal vs Float

The default `:auto` keeps high-precision decimals as `BigDecimal` (matching Oj). Force `Float` for raw speed when you don't need the precision:

```ruby
SmarterJSON.process("65.613616999999977")                        # => BigDecimal (:auto, the default)
SmarterJSON.process("65.613616999999977", decimal_precision: :float)  # => 65.613616999999977 (a Float)
```

### Example 9: Lenient Input: Comments, Trailing Commas, Unquoted Keys

```ruby
SmarterJSON.process(<<~JSON)
  {
    host: localhost,   # unquoted key, quoteless value, and a trailing comma
    port: 5432,
    /* block comment */
    url: http://example.com
  }
JSON
# => {"host"=>"localhost", "port"=>5432, "url"=>"http://example.com"}
```

A `#`/`//` only starts a comment when preceded by whitespace, so `http://example.com` stays a string rather than being truncated.

### Example 10: Wrapper Noise Around a Payload

#### Fenced payload

````ruby
SmarterJSON.process(<<~TEXT)
  Here is the JSON:

  ```json
  {
    "a": 1
  }
  ```
TEXT
# => {"a"=>1}
````

#### Prose before / after the payload

```ruby
SmarterJSON.process(<<~TEXT)
  Here is the result:

  {
    "a": 1
  }

  Hope this helps.
TEXT
# => {"a"=>1}
```

#### Wrapper tags

```ruby
SmarterJSON.process("<json>{\"a\":1}</json>")
# => {"a"=>1}
```

#### Multiple recovered payloads from one noisy blob

```ruby
SmarterJSON.process(<<~TEXT)
  first attempt:
  {"a":1}

  corrected payload:
  {"b":2}
TEXT
# => [{"a"=>1}, {"b"=>2}]
```

### Example 11: Write JSON

```ruby
SmarterJSON.generate({ "a" => 1, "b" => [2, 3] })   # => '{"a":1,"b":[2,3]}'
SmarterJSON.generate([1, 2, 3])                       # => '[1,2,3]'
```

### Example 12: Write NDJSON

An Array writes one element per line:

```ruby
SmarterJSON.generate([{ "id" => 1 }, { "id" => 2 }], format: :ndjson)   # => "{\"id\":1}\n{\"id\":2}\n"
```

### Example 13: Round-Trip Read and Write

```ruby
obj = { "a" => 1, "b" => [2, "three", nil, true] }
SmarterJSON.process(SmarterJSON.generate(obj)) == obj   # => true
```

---------------

PREVIOUS: [Configuration Options](./options.md) | UP: [README](../README.md)
