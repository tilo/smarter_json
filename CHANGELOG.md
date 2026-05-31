
# FlexJSON Change Log



## 0.3.6 (2026-05-30 unreleased)
- more performance improvements

## 0.3.5 (2026-05-30 unreleased)
- more performance improvements

  - Added fj_try_decimal — scans the already-bounded token once, validating and accumulating mantissa/exponent in the same pass, then builds the value via the shared
  fj_int_from_parts / fj_float_from_parts helpers. Returns 0 (→ keep as string) when it isn't a valid number.
  - Collapsed 3+ passes into 1 on this path: the old fj_validate_decimal (validate) + fj_sig_digits (significant-digit count) + fj_decimal_value (mantissa extraction) are now one
  scan. The m10digits <= 16 shortcut skips the fj_sig_digits scan entirely for the common case (every canada coordinate).
  - #2 / #3 applied here too: fast digit loop with no per-byte _ check (slow step only on an actual underscore); bounds via the slice length, same as before but now traversed once.
  - Removed the now-dead fj_validate_decimal, fj_int_value, fj_decimal_value — fj_parse_number (strict path) and fj_try_decimal (quoteless path) both go straight through the shared
  …_from_parts helpers, so the two paths can't drift.


## 0.3.4 (2026-05-30 unreleased)
- performance improvements

   - Dropped the per-member key? rb_funcall (json_learnings #1) — the easy one. flex_json does a Ruby method dispatch per object member under the default :last_wins for nothing. twitter/github/citm pay it millions of times. A few lines, low risk.
   - C-array value stack + pre-sized hash + rb_hash_bulk_insert + size-based dup detection (json #2/#3, oj #2) — the real object-path push.
   - Local key cache before rb_enc_interned_str (json #4, oj #1) — repeated keys.

## 0.3.3 (2026-05-30 unreleased)
- adding Ryu for floating piont performance

## 0.3.3 (2026-05-29 unreleased)
- performance fixes

## 0.3.2 (2026-05-29 unreleased)
- performance fixes

## 0.3.1 (2026-05-29 unreleased)
- performance fixes

## 0.3.0 (2026-05-29 unreleased)
- iterative parser

## 0.2.0 (2026-05-29 unreleased)
- recursive parser

## 0.1.1 (2026-05-29 unreleased)
- MVP complete (Ruby + C)

## 0.1.0 (2026-05-28 unreleased)
- Initial Ruby version
