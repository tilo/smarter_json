# Ryū, by Ulf Adams

  - The algorithm is Ryū, by Ulf Adams (Copyright 2018), Apache-2.0 / Boost. Upstream: https://github.com/ulfjack/ryu
  - The actual file you have was vendored from the ruby/json gem, v2.19.7 — path ext/json/ext/vendor/ryu.h. Repo: https://github.com/ruby/json

## Update from ruby/json, not from upstream Ryū.

  The function flex_json calls — `ryu_s2d_from_parts(m10, m10digits, e10, signedM)` (line 754) — is not in stock upstream Ryū (upstream exposes `s2d/s2d_n`, which take a string). It's ruby/json's adaptation that takes a pre-extracted mantissa/exponent, which is exactly what our fj_decimal_value produces. Pull upstream and you won't have that entry point.

## To refresh it:

### from the raw file on GitHub (master, or pin to a json release tag):
  `curl -L https://raw.githubusercontent.com/ruby/json/master/ext/json/ext/vendor/ryu.h -o ext/flex_json/vendor/ryu.h`

### or from your local json gem:
  `cp "$(gem contents json | grep ext/json/ext/vendor/ryu.h)" ext/flex_json/vendor/ryu.h`

  It was vendored from `ruby/json`:
  - origin: Ryū (`ulfjack/ryu`), adapted by `ruby/json`
  - vendored from: json 2.19.7
  - update command above
  - license: Apache-2.0
