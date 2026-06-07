
### Contents

  * [Introduction](./_introduction.md)
  * [The Basic Read API](./basic_read_api.md)
  * [The Basic Write API](./basic_write_api.md)
  * [**Configuration Options**](./options.md)
  * [Examples](./examples.md)

--------------

# Configuration Options

## Reading

These options are passed to [`SmarterJSON.process`](./basic_read_api.md), `SmarterJSON.process_one`, and `SmarterJSON.process_file` as the second argument; anything you set overrides the defaults below.

| Option            | Default      | Explanation                                                                                                            |
|-------------------|--------------|------------------------------------------------------------------------------------------------------------------------|
| `:acceleration`   | `true`       | Use the C extension when it is compiled and loadable; `false` forces the pure-Ruby implementation. Both produce identical results. |
| `:decimal_precision`| `:auto`      | `:auto` keeps high-precision decimals as `BigDecimal` (matches Oj); `:float` forces every number to `Float`; `:bigdecimal` forces every decimal to `BigDecimal`. |
| `:duplicate_key`  | `:last_wins` | How to handle a key that repeats within one object: `:last_wins` or `:first_wins`. (Every repeat is also reported through `:on_warning` — see below.)                          |
| `:encoding`       | `nil`        | Labels the input's encoding (e.g. `"UTF-8"`). It does **not** trigger a transcoding pass — see below.                  |
| `:on_warning`     | `nil`        | A callable invoked once per lenient fix applied, passed a `SmarterJSON::Warning`. Never changes the return value. See below. |
| `:symbolize_keys` | `false`      | Return object keys as Symbols instead of Strings.                                                                      |

```ruby
SmarterJSON.process_one('{"a": 1}', symbolize_keys: true)               # => {:a=>1}
SmarterJSON.process_one('{"a":1,"a":2}', duplicate_key: :first_wins)    # => {"a"=>1}  (default keeps the 2)
SmarterJSON.process_one(big_decimal_json, decimal_precision: :float)      # every number as Float (fastest)
SmarterJSON.process_one("[1,,2]", on_warning: ->(w) { puts w })         # => [1, 2], and prints the warning
```

### A note on `:on_warning`

`smarter_json` is lenient by design — it salvages your data instead of rejecting the whole document over a stray comma. `on_warning:` keeps that, but also hands you a record of what it had to fix, so leniency is transparent rather than silent. It takes a callable that SmarterJSON invokes once per fix, passing a `SmarterJSON::Warning` (with `type` (a Symbol), `message`, `line`, and `col`). It never changes the return value — `process` still returns its `Array` of documents (and `process_one` its single value) — and it fires on every path, including the streaming block form. With no handler (the default), nothing is recorded and there is zero overhead.

```ruby
warns = []
result = SmarterJSON.process("[1,,2]", on_warning: ->(w) { warns << w })
result                         # => [[1, 2]]   (one document: the array [1, 2], with the empty slot collapsed)
warns.map(&:type)              # => [:empty_slot]
warns.first.to_s               # => "extra comma, collapsed an empty slot at line 1, col 4"
```

The warning types are `:empty_slot` (a collapsed empty comma slot, e.g. `[1,,2]`), `:empty_value` (a key with no value, read as `null`, e.g. `{a:}`), and `:duplicate_key` (a repeated key that was dropped), plus wrapper-recovery warnings such as `:code_fence_stripped`, `:prefix_text_ignored`, `:suffix_text_ignored`, and `:wrapper_tag_stripped`. Clean input never invokes the handler. Warnings work on both the C and pure-Ruby paths, so `acceleration:` doesn't change them.

### A note on `:encoding`

`:encoding` labels what the input *is* — it does not transcode. With the default `nil`, SmarterJSON keeps the input's own encoding tag and emits string values with that tag, the same way `smarter_csv` handles encodings — **with one smart default:** input tagged `ASCII-8BIT` (BINARY) that is valid UTF-8 is treated as UTF-8. This is how `Net::HTTP` returns a `response.body`; without it, those string values would compare unequal to UTF-8 literals. `ASCII-8BIT` input that is *not* valid UTF-8 raises `SmarterJSON::EncodingError` — pass an explicit `:encoding` (e.g. `"ISO-8859-1"`) for genuinely-legacy bytes. Bytes invalid for an explicitly claimed encoding also raise `SmarterJSON::EncodingError` (a kind of `SmarterJSON::ParseError`). A UTF-8 BOM is handled automatically; UTF-16 / UTF-32 input is out of scope.

### A note on `:decimal_precision`

The default `:auto` preserves high-precision numbers as `BigDecimal`, matching Oj's default. That is intrinsically slower than producing `Float` on number-heavy files (e.g. `canada.json`). For raw speed when you don't need the extra precision, pass `decimal_precision: :float`.

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
