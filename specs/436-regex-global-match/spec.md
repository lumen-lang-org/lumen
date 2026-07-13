# Spec 436 — `String.match` with the global (`g`) flag

## Problem

`str.match(/re/g)` should return every non-overlapping match in the string, but
`matchRegex` ignored the `g` flag: it called `__reFind` once and returned a
single-element array of the first match. So

```ts
"abc123def456ghi789".match(/[0-9]+/g)
```

returned one element instead of `["123", "456", "789"]`.

## Change

`matchRegex` (`regex_rt.zig`) now branches on the compiled pattern's `global`
flag:

- **global**: iterate `__reFind` across the string, collecting each
  non-overlapping full-match substring; a zero-width match advances one byte to
  guarantee progress. Returns `null` when there are no matches, matching JS.
- **non-global**: unchanged — a single-element `[fullMatch]` array.

Capture groups remain unpopulated (the Thompson-NFA engine tracks whole-match
spans, not per-group spans); that is a separate, larger effort.

## Verification

- `zig build` and `zig build test` clean.
- `"abc123def456ghi789".match(/[0-9]+/g)` → length `3`, `123|456|789`.
- `"the quick brown".match(/\w+/g)` → `the,quick,brown`.
- Non-global `"abc123".match(/[0-9]+/)` → `["123"]` (`[0]` = `123`).
- A global match with no hits (`"xyz".match(/[0-9]+/g)`) → `null`.
