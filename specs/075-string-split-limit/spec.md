# Spec 075: string split limit

## Goal

`split` produced every segment; capping the result (e.g. "first field and the
rest") meant splitting fully and slicing after. This adds the optional `limit`
second argument (as in JavaScript), truncating the result to at most `limit`
segments.

## Why additive, not breaking

Pure extension of the existing `split` string method: the single-argument form
is unchanged; a second integer argument caps the produced array.

## API

Instance method on a `string` value:

- `split(sep: string, limit?: int): string[]` — the segments of the string
  around `sep`, at most `limit` of them. A negative `limit` is treated as no
  limit (matching JavaScript's unsigned coercion); `limit` `0` yields an empty
  array. With no `limit`, all segments are returned.

## Requirements

- **FR-001**: `split` accepts one string, optionally followed by one integer; a
  non-integer limit reports `E_TYPE_MISMATCH`, more than two arguments reports
  `E_ARG_COUNT`.
- **FR-002**: With a non-negative `limit`, the result contains at most `limit`
  segments (the leading ones); `0` yields `[]`.
- **FR-003**: A negative `limit` returns all segments; the single-argument form
  behaves exactly as before.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: `"a,b,c,d".split(",", 2)` -> `["a","b"]`,
  `"a,b,c,d".split(",", 0)` -> `[]`, `"a,b,c,d".split(",", 10)` -> all four,
  `"abc".split("", 2)` -> `["a","b"]`.
- **SC-002**: `zig build` and `zig build test` stay green.
