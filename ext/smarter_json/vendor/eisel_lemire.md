# Eisel-Lemire decimal→double, from fast_float

- The algorithm is **Eisel-Lemire**, named for **Michael Eisel** (who proposed/motivated the original approach) and **Daniel Lemire** (who formalized it, proved its bounds, and wrote the fast_float implementation). We use the later "without fallback" form proven by **Noble Mushtak & Daniel Lemire, _Fast Number Parsing Without Fallback_**. It converts a decimal mantissa+exponent to a correctly-rounded binary64 with no slow path, for any nonzero mantissa that fits exactly in a `uint64` (≤ 19 significant digits).
- Vendored from **fastfloat/fast_float** — https://github.com/fastfloat/fast_float — license Apache-2.0 / MIT / Boost-1.0 (your choice).

## What smarter_json uses it for

`fj_float_from_parts` (in `smarter_json.c`) routes `m10digits ≤ 18 → fj_eisel_lemire_s2d`, and `> 18 / overflow / extreme exponent → strtod` (round-to-odd). It replaced the previous Ryū `s2d_from_parts` fast path entirely: Eisel-Lemire is correct past 17 digits (the vendored ruby/json Ryū `s2d_from_parts` was a deliberate ≤17 fast path whose single `mulShift64` drops the round-to-even tie bits beyond that) **and** measurably faster on the ≤17 common case.

## These two files are DERIVED, not verbatim copies

- **`eisel_lemire_powers.h`** — the `power_of_five_128` table (1302 × `uint64`), extracted **verbatim** (the constants are byte-for-byte) from fast_float `include/fast_float/fast_table.h`, but **rewrapped**: a plain C `static const uint64_t fj_power_of_five_128[...]` array instead of fast_float's C++ `powers_template` struct. `FJ_EL_SMALLEST_POWER_OF_FIVE` / `FJ_EL_LARGEST_POWER_OF_FIVE` are the `-342` / `308` bounds.
- **`eisel_lemire.h`** — a C **port** of `compute_float<binary_format<double>>` + `compute_product_approximation` from fast_float `include/fast_float/decimal_to_binary.h`. Adapted to: (a) plain C (no templates), (b) take our already-extracted `(q, w)` = `(e10, m10)` instead of re-parsing a string, (c) the binary64 constants inlined as `FJ_EL_*` macros, (d) a portable `fj_el_mul128` (`__uint128_t` when available, else a 32×32 split). The control flow — `compute_product_approximation<55>`, the `0x1FF` precision mask, `upperbit`/`shift`, the subnormal branch, and the round-to-even "land exactly between two doubles → round down" check — mirrors the source.

Because they're derived (rewrapped table, ported algorithm), they're named after the **algorithm** (Eisel-Lemire), matching how `ryu.h` was named after Ryū rather than its source (ruby/json). The verification that they faithfully reproduce upstream is the bit-for-bit stress vs `JSON.parse` (8–10M random numbers incl. ties / subnormals / near-overflow, 0 mismatches).

## To refresh from upstream

Re-pull the two source files and re-derive:

- table: `curl -L https://raw.githubusercontent.com/fastfloat/fast_float/main/include/fast_float/fast_table.h` — copy the `power_of_five_128[...] = { ... };` body into `eisel_lemire_powers.h`'s array (constants only).
- algorithm: `curl -L https://raw.githubusercontent.com/fastfloat/fast_float/main/include/fast_float/decimal_to_binary.h` — re-check `compute_float` / `compute_product_approximation` against the port in `eisel_lemire.h`.

Then re-run the bit-exact stress (≥ several million random 1–19-digit numbers, with forced round-to-even ties and exponents spanning subnormal → overflow) vs `JSON.parse` before trusting it.

- origin: Eisel-Lemire (`fastfloat/fast_float`)
- vendored from: fast_float (upstream `main`)
- copyright: (c) 2021 The fast_float authors
- license: tri-licensed Apache-2.0 / MIT / BSL-1.0; vendored here under **MIT**, full text in `LICENSE-fast_float-MIT` (this directory)
