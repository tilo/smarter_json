
### Contents

  * [Introduction](./_introduction.md)
  * [The Basic Read API](./basic_read_api.md)
  * [The Basic Write API](./basic_write_api.md)
  * [Configuration Options](./options.md)
  * [**Examples**](./examples.md)

--------------

# Examples

**Rescue from `SmarterJSON::Error` (recommended):** SmarterJSON raises only on genuinely unreadable input (an unterminated string, a mismatched bracket), with line and column in the message. Rescuing from `SmarterJSON::Error` lets your application handle bad input gracefully.

**`process` vs `process_one`:** `SmarterJSON.process` is the preferred call — it always returns an `Array` of documents, so the count is explicit and you never silently drop one. `SmarterJSON.process_one` is the convenience for the single-document case: it returns that one document's value directly, and *warns* (never raises) if the input turned out to hold more than one. Both appear below; reach for `process` unless you specifically want the single value.

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

SmarterJSON.process('{"a": 1, "b": [2, 3]}')       # => [{"a"=>1, "b"=>[2, 3]}]   (always an Array of documents)
SmarterJSON.process_one('{"a": 1, "b": [2, 3]}')   # => {"a"=>1, "b"=>[2, 3]}     (the one document's value)
```

### Example 2: Read a JSON File

```ruby
SmarterJSON.process_file("config.json")        # => an Array of documents (same return rules as process)
```

`process_file` opens the file, reads it with the labeled [`encoding:`](./options.md) (default `"UTF-8"`), and processes it.

### Example 3: Implicit Root Object (config-style, no braces)

A config file that starts with `key: value` and has no outer `{}` is read as an object:

```ruby
SmarterJSON.process_one("host: localhost\nport: 5432")   # => {"host"=>"localhost", "port"=>5432}
```

### Example 4: Multiple Documents (NDJSON) → Array

Plain `process` reads NDJSON / JSONL / concatenated documents with no block and no special method, and always returns an `Array` — `[]` for none, `[doc]` for one, `[d1, d2, …]` for several:

```ruby
SmarterJSON.process(%({"id":1}\n{"id":2}\n{"id":3}))   # => [{"id"=>1}, {"id"=>2}, {"id"=>3}]
SmarterJSON.process('{"id":1}')                          # => [{"id"=>1}]   (one document, still an Array)
SmarterJSON.process("")                                  # => []            (zero documents)
```

For the single-document case, `process_one` returns the one value directly — and *warns* (never raises) if there was more than one:

```ruby
SmarterJSON.process_one('{"id":1}')   # => {"id"=>1}
SmarterJSON.process_one("")           # => nil
```

### Example 5: Streaming a Large File with a Block

For input larger than memory, pass a block. Each recovered document is yielded one at a time, and the method returns the **document count** instead of building an `Array`:

```ruby
SmarterJSON.process_file("events.ndjson") { |event| EventJob.perform_async(event) }
```

**A JSONL file you already have:** Claude Code stores each session as a JSONL transcript — `~/.claude/projects/<project>/<session-id>.jsonl`, one JSON document per line (a message, a tool call, a result, …). It reads the same way, one record at a time:

```ruby
require "awesome_print" # optional — for readable nested output

SmarterJSON.process_file("#{Dir.home}/.claude/projects/<project>/<session-id>.jsonl") do |entry|
  ap entry              # each line is a full document
  puts "-" * 80
end
```

**Filter and rewrite as a stream — `SmarterJSON.foreach`:** `foreach(source)` is the composable sibling of `process_file`; `source` is a file path or any IO (a socket, a `StringIO`, an open `File`). Without a block it returns a plain `Enumerator` (like `CSV.foreach`) that reads one document at a time, so it chains with `.select` / `.map`; add `.lazy` to keep the whole pipeline bounded in memory. This filters a transcript down to its user/assistant turns and writes a smaller file, never loading all of it:

```ruby
File.open("filtered.jsonl", "w") do |out|
  SmarterJSON.foreach("session.jsonl", symbolize_keys: true)
             .lazy
             .select { |doc| %w[user assistant].include?(doc[:type]) }
             .each   { |doc| out.puts SmarterJSON.generate(doc) }
end
```

### Example 6: Symbolize Keys

```ruby
SmarterJSON.process_one('{"a": 1, "b": 2}', symbolize_keys: true)   # => {:a=>1, :b=>2}
```

### Example 7: Duplicate Keys

By default the last value wins. Pass `:first_wins` to keep the first instead (either way, the repeat is reported through [`on_warning`](./options.md)):

```ruby
SmarterJSON.process_one('{"a":1,"a":2}')                          # => {"a"=>2}   (:last_wins, the default)
SmarterJSON.process_one('{"a":1,"a":2}', duplicate_key: :first_wins)  # => {"a"=>1}
```

### Example 8: High-Precision Numbers: BigDecimal vs Float

The default `:auto` keeps high-precision decimals as `BigDecimal` (matching Oj). Force `Float` for raw speed when you don't need the precision:

```ruby
SmarterJSON.process_one("65.613616999999977")                        # => BigDecimal (:auto, the default)
SmarterJSON.process_one("65.613616999999977", decimal_precision: :float)  # => 65.613616999999977 (a Float)
```

### Example 9: Lenient Input: Comments, Trailing Commas, Unquoted Keys

```ruby
SmarterJSON.process_one(<<~JSON)
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

### Example 10: Leading-Zero IDs and SQL `NULL`

```ruby
SmarterJSON.process_one(<<~JSON)
  {
    user_id:    007,      # bare leading zero -> kept as a string
    zip:        02139,    # ditto: zip codes keep their leading zero
    balance:    -007.50,  # a sign / decimal point / exponent makes it a number
    deleted_at: NULL      # SQL / R / YAML null spelling -> nil
  }
JSON
# => {"user_id"=>"007", "zip"=>"02139", "balance"=>-7.5, "deleted_at"=>nil}
```

A bare leading-zero integer is kept as a string so identifiers, zip codes, and account numbers don't lose their zeros; a sign, decimal point, or exponent marks numeric intent (`-007.50` → `-7.5`). `Null` and `NULL` join `null` / `None` / `undefined` as spellings of `nil`; a quoted `"NULL"` stays a string.

### Example 11: Wrapper Noise Around a Payload

#### Fenced payload

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
````

#### Prose before / after the payload

```ruby
SmarterJSON.process_one(<<~TEXT)
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
SmarterJSON.process_one("<json>{\"a\":1}</json>")
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

### Example 12: Write JSON

```ruby
SmarterJSON.generate({ "a" => 1, "b" => [2, 3] })   # => '{"a":1,"b":[2,3]}'
SmarterJSON.generate([1, 2, 3])                       # => '[1,2,3]'
```

### Example 13: Write NDJSON

An Array writes one element per line:

```ruby
SmarterJSON.generate([{ "id" => 1 }, { "id" => 2 }], format: :ndjson)   # => "{\"id\":1}\n{\"id\":2}\n"
```

### Example 14: Round-Trip Read and Write

```ruby
obj = { "a" => 1, "b" => [2, "three", nil, true] }
SmarterJSON.process_one(SmarterJSON.generate(obj)) == obj   # => true
```

---------------

PREVIOUS: [Configuration Options](./options.md) | UP: [README](../README.md)
