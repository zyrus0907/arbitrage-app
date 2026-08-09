# `src/lib/money/`

The only place currency arithmetic exists. Created in T12.

## Rules

- A `Money` value is `{ amountMinor, currency }`. A bare integer crossing a service boundary is a bug (§1.2 rule 8).
- Adding two different currencies throws `CURRENCY_MISMATCH`.
- The minor-unit exponent comes from currency configuration — never an assumed ×100 (JPY has 0 decimals).
- Rounding: round half away from zero, at the final step only.
