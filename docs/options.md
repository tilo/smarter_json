
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
| `:warnings`       | `false`      | When `true`, return `[result, warnings]` instead of just `result` — `warnings` lists the lenient fixes that were applied. See below. |

```ruby
SmarterJSON.process('{"a": 1}', symbolize_keys: true)               # => {:a=>1}
SmarterJSON.process('{"a":1,"a":2}', duplicate_key: :raise)         # raises SmarterJSON::ParseError
SmarterJSON.process(big_decimal_json, bigdecimal_load: :float)      # every number as Float (fastest)
SmarterJSON.process("[1,,2]", warnings: true)                       # => [[1, 2], [#<SmarterJSON::Warning ...>]]
```

### A note on `:warnings`

`smarter_json` is lenient by design — it salvages your data instead of rejecting the whole document over a stray comma. `warnings: true` keeps that, but also hands back a record of what it had to fix, so leniency is transparent rather than silent. The call then returns a two-element `[result, warnings]`; `warnings` is an Array of `SmarterJSON::Warning`, each with `type` (a Symbol), `message`, `line`, and `col`:

```ruby
result, warnings = SmarterJSON.process("[1,,2]", warnings: true)
result                         # => [1, 2]
warnings.map(&:type)           # => [:empty_slot]
warnings.first.to_s            # => "extra comma, collapsed an empty slot at line 1, col 4"
```

The warning types are `:empty_slot` (a collapsed empty comma slot, e.g. `[1,,2]`), `:empty_value` (a key with no value, read as `null`, e.g. `{a:}`), and `:duplicate_key` (a repeated key that was dropped). Clean input returns an empty `warnings` array. Warnings work on both the C and pure-Ruby paths, so `acceleration:` doesn't change them.

### A note on `:encoding`

`:encoding` labels what the input *is* — it does not transcode. The parser works on the bytes in their native encoding and emits string values with the same encoding tag, the same way `smarter_csv` handles encodings. Bytes that are invalid for the claimed encoding raise `SmarterJSON::EncodingError` (a kind of `SmarterJSON::ParseError`). A UTF-8 BOM is handled automatically; UTF-16 / UTF-32 input is out of scope.

### A note on `:bigdecimal_load`

The default `:auto` preserves high-precision numbers as `BigDecimal`, matching Oj's default. That is intrinsically slower than producing `Float` on number-heavy files (e.g. `canada.json`). For raw speed when you don't need the extra precision, pass `bigdecimal_load: :float`.

## Writing

These options are passed to [`SmarterJSON.generate`](./basic_write_api.md) as the second argument.

| Option     | Default | Explanation                                                                                                                |
|------------|---------|-----------------------------------------------------------------------------------------------------------------------------|
| `:format`       | `:json` | `:json` writes standard JSON (Hash → object, Array → array, scalar → scalar). `:ndjson` writes newline-delimited JSON: an Array becomes one element per line, any other value becomes a single line. |
| `:indent`       | `0`     | Spaces per nesting level for pretty-printing. `0` (the default) is compact output. Empty objects/arrays stay inline. Not allowed with `:ndjson` (a record must be a single line). |
| `:sort_keys`    | `false` | Emit object keys in sorted order (Symbol keys sorted by their string form). Useful for canonical, diff-friendly output. |
| `:ascii_only`   | `false` | Escape every non-ASCII character as `\uXXXX` (astral characters as a UTF-16 surrogate pair). The default emits raw UTF-8. |
| `:script_safe`  | `false` | Escape the `/` in `</` and the JS line separators U+2028 / U+2029, so output is safe to embed in an HTML `<script>` tag. |
| `:coerce`       | `false` | When `true`, a value that isn't natively supported is converted by its own `as_json` (the result is re-emitted, so the other options still apply) or, failing that, `to_json` (spliced verbatim). When `false` (the default), such a value raises `SmarterJSON::GenerateError`. |

Any other `:format` value, a negative/non-Integer `:indent`, or combining `:indent` with `:ndjson`, raises `ArgumentError`.

```ruby
SmarterJSON.generate([1, 2, 3])                              # => "[1,2,3]"   (default :json — a single JSON array)
SmarterJSON.generate([1, 2, 3], format: :ndjson)            # => "1\n2\n3\n" (one element per line)
SmarterJSON.generate({ "a" => 1 }, indent: 2)               # => "{\n  \"a\": 1\n}"  (pretty-printed)
SmarterJSON.generate({ "b" => 2, "a" => 1 }, sort_keys: true) # => '{"a":1,"b":2}'
SmarterJSON.generate("café", ascii_only: true)              # => '"caf\u00e9"'
SmarterJSON.generate("</script>", script_safe: true)        # => '"<\/script>"'
SmarterJSON.generate(model, coerce: true)                   # => uses model.as_json (else model.to_json)
SmarterJSON.generate(model)                                 # raises SmarterJSON::GenerateError (coerce off)
SmarterJSON.generate({}, format: :bogus)                    # raises ArgumentError
```

---------------

PREVIOUS: [The Basic Write API](./basic_write_api.md) | NEXT: [Examples](./examples.md) | UP: [README](../README.md)
