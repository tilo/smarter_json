
### Contents

  * [Introduction](./_introduction.md)
  * [The Basic Read API](./basic_read_api.md)
  * [The Basic Write API](./basic_write_api.md)
  * [**Configuration Options**](./options.md)
  * [Examples](./examples.md)

--------------

# Configuration Options

## Reading

These options are passed to [`SmarterJSON.process`](./basic_read_api.md) and `SmarterJSON.process_file` as the second argument; anything you set overrides the defaults below.

| Option            | Default      | Explanation                                                                                                            |
|-------------------|--------------|------------------------------------------------------------------------------------------------------------------------|
| `:symbolize_keys` | `false`      | Return object keys as Symbols instead of Strings.                                                                      |
| `:duplicate_key`  | `:last_wins` | How to handle a key that repeats within one object: `:last_wins`, `:first_wins`, or `:raise`.                          |
| `:bigdecimal_load`| `:auto`      | `:auto` keeps high-precision decimals as `BigDecimal` (matches Oj); `:float` forces every number to `Float`; `:bigdecimal` forces every decimal to `BigDecimal`. |
| `:acceleration`   | `true`       | Use the C extension when it is compiled and loadable; `false` forces the pure-Ruby parser. Both produce identical results. |
| `:encoding`       | `nil`        | Labels the input's encoding (e.g. `"UTF-8"`). It does **not** trigger a transcoding pass — see below.                  |

```ruby
SmarterJSON.process('{"a": 1}', symbolize_keys: true)               # => {:a=>1}
SmarterJSON.process('{"a":1,"a":2}', duplicate_key: :raise)         # raises SmarterJSON::ParseError
SmarterJSON.process(big_decimal_json, bigdecimal_load: :float)      # every number as Float (fastest)
```

### A note on `:encoding`

`:encoding` labels what the input *is* — it does not transcode. The parser works on the bytes in their native encoding and emits string values with the same encoding tag, the same way `smarter_csv` handles encodings. Bytes that are invalid for the claimed encoding raise `SmarterJSON::EncodingError` (a kind of `SmarterJSON::ParseError`). A UTF-8 BOM is handled automatically; UTF-16 / UTF-32 input is out of scope.

### A note on `:bigdecimal_load`

The default `:auto` preserves high-precision numbers as `BigDecimal`, matching Oj's default. That is intrinsically slower than producing `Float` on number-heavy files (e.g. `canada.json`). For raw speed when you don't need the extra precision, pass `bigdecimal_load: :float`.

## Writing

This option is passed to [`SmarterJSON.generate`](./basic_write_api.md) as the second argument.

| Option     | Default | Explanation                                                                                                                |
|------------|---------|-----------------------------------------------------------------------------------------------------------------------------|
| `:format`  | `:json` | `:json` writes standard JSON (Hash → object, Array → array, scalar → scalar). `:ndjson` writes newline-delimited JSON: an Array becomes one element per line, any other value becomes a single line. |

Any other `:format` value raises `ArgumentError`.

```ruby
SmarterJSON.generate([1, 2, 3])                          # => "[1,2,3]"   (default :json — a single JSON array)
SmarterJSON.generate([1, 2, 3], format: :ndjson)         # => "1\n2\n3\n" (one element per line)
SmarterJSON.generate({}, format: :bogus)                 # raises ArgumentError
```

---------------

PREVIOUS: [The Basic Write API](./basic_write_api.md) | NEXT: [Examples](./examples.md) | UP: [README](../README.md)
