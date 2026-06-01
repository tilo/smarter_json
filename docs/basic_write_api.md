
### Contents

  * [Introduction](./_introduction.md)
  * [The Basic Read API](./basic_read_api.md)
  * [**The Basic Write API**](./basic_write_api.md)
  * [Configuration Options](./options.md)
  * [Examples](./examples.md)

--------------

# SmarterJSON Basic Write API

Writing JSON has one entry point: `SmarterJSON.generate`. It turns a Ruby value into a JSON String — strict, interoperable output by default, or NDJSON when you ask for it.

## `SmarterJSON.generate` — write a Ruby value as JSON

```ruby
require "smarter_json"

SmarterJSON.generate({ "a" => 1, "b" => [2, 3] })   # => '{"a":1,"b":[2,3]}'
SmarterJSON.generate([1, 2, 3])                       # => '[1,2,3]'
SmarterJSON.generate("hi")                            # => '"hi"'
SmarterJSON.generate(42)                              # => '42'
SmarterJSON.generate(nil)                             # => 'null'
```

The output is always **valid, strict JSON** — there is no lenient write mode. (We are lenient about what we *read*, strict about what we *write*, so the output interoperates with every other JSON parser.)

## How Ruby values map to JSON

| Ruby                                   | JSON output                                             |
|----------------------------------------|---------------------------------------------------------|
| `Hash`                                 | object `{…}` — keys are stringified (Symbol keys too)   |
| `Array`                                | array `[…]`                                             |
| `String`                               | quoted string, escaped (see below)                      |
| `Symbol`                               | quoted string (`:sym` → `"sym"`)                        |
| `Integer`                              | number                                                  |
| `Float`                                | number (non-finite raises — see below)                  |
| `BigDecimal`                           | number, full precision (not a string)                   |
| `true` / `false` / `nil`               | `true` / `false` / `null`                               |

```ruby
SmarterJSON.generate({ a: 1, b: :sym })                       # => '{"a":1,"b":"sym"}'   (Symbol key and value → strings)
SmarterJSON.generate(BigDecimal("65.613616999999977"))         # => '65.613616999999977' (a number, full precision)
SmarterJSON.generate("café\tx")                                # => '"café\tx"'          (control chars escaped, UTF-8 raw)
```

Strings escape `"`, `\`, and the control characters `0x00–0x1F`; everything else — including multi-byte UTF-8 — is emitted raw, which is valid JSON.

## What raises

`generate` raises `SmarterJSON::Error` on input it cannot represent as strict JSON:

```ruby
SmarterJSON.generate(Time.now)          # raises SmarterJSON::GenerateError — unsupported type
SmarterJSON.generate(Float::INFINITY)   # raises SmarterJSON::GenerateError — non-finite Float
SmarterJSON.generate(Float::NAN)        # raises SmarterJSON::GenerateError — non-finite Float
```

(`GenerateError` is a kind of `SmarterJSON::Error`, so `rescue SmarterJSON::Error` catches it. `Infinity` and `NaN` are accepted on the *read* side as a leniency, but they are not valid JSON to *write*.)

## Pretty-printing

By default `generate` produces compact output (no spaces). Pass `indent:` (a number of spaces per nesting level) to pretty-print:

```ruby
SmarterJSON.generate({ "a" => 1, "b" => [2, 3] }, indent: 2)
# => "{\n  \"a\": 1,\n  \"b\": [\n    2,\n    3\n  ]\n}"
```

which prints as:

```json
{
  "a": 1,
  "b": [
    2,
    3
  ]
}
```

Empty objects and arrays stay inline (`{}` / `[]`) even when indenting. `indent: 0` (the default) is compact output. Pretty-printing is multi-line, so it can't be combined with `format: :ndjson` (where each record must be a single line) — doing so raises `ArgumentError`. See [Configuration Options](./options.md).

## Safe and canonical output

Three more options shape the output, and they compose with each other and with `indent:`:

- **`sort_keys: true`** — emit object keys in sorted order (Symbol keys sorted by their string form). Handy for canonical, diff-friendly JSON.
- **`ascii_only: true`** — escape every non-ASCII character as `\uXXXX` (characters above U+FFFF become a UTF-16 surrogate pair). The default emits raw UTF-8.
- **`script_safe: true`** — escape the `/` in `</` and the JavaScript line separators U+2028 / U+2029, so the output is safe to embed directly in an HTML `<script>` tag without breaking out of it.

```ruby
SmarterJSON.generate({ "b" => 2, "a" => 1 }, sort_keys: true)   # => '{"a":1,"b":2}'
SmarterJSON.generate("</script>", script_safe: true)            # => '"<\/script>"'
```

See [Configuration Options](./options.md) for the full table.

## Writing NDJSON

Pass `format: :ndjson` to write newline-delimited JSON. An `Array` writes **one element per line**; any other value writes as a single line. This is the exact inverse of [reading NDJSON](./basic_read_api.md) back into an Array.

```ruby
SmarterJSON.generate([{ "id" => 1 }, { "id" => 2 }], format: :ndjson)   # => "{\"id\":1}\n{\"id\":2}\n"
SmarterJSON.generate({ "id" => 1 }, format: :ndjson)                     # => "{\"id\":1}\n"   (single value → one line)
SmarterJSON.generate([], format: :ndjson)                               # => ""              (empty array → no lines)
```

Note the difference from the default `format: :json`, where a top-level Array is written as a single JSON array (`[…]`), not as NDJSON. See [Configuration Options](./options.md) for the full list of writer options.

## Round-tripping

`process` and `generate` are inverses:

```ruby
obj = { "a" => 1, "b" => [2, "three", nil, true] }
SmarterJSON.process(SmarterJSON.generate(obj)) == obj                                  # => true

arr = [{ "id" => 1 }, { "id" => 2 }, { "id" => 3 }]
SmarterJSON.process(SmarterJSON.generate(arr, format: :ndjson)) == arr                 # => true
```

Check out the [RSpec tests](../spec/generator_spec.rb) for more examples.

---------------

PREVIOUS: [The Basic Read API](./basic_read_api.md) | NEXT: [Configuration Options](./options.md) | UP: [README](../README.md)
