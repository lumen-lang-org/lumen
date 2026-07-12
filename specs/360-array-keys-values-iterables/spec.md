# 360 — `arr.keys()` / `arr.values()` as for-of iterables

## Problem

`for (const [i, v] of arr.entries())` worked (spec-established for-of-only
iterable), but the sibling iterators did not:

```ts
for (const i of a.keys()) ...    // error: `array` has no method 'keys' — did you mean 'keys'?
for (const v of a.values()) ...  // same shape
```

(The self-referential "did you mean 'keys'" came from the suggestion list
already naming keys/values as known methods without an implementation.)

## Change

Same design as `.entries()` — these exist only as for-of iterables, not
standalone array methods:

- **Checker** (`lumen_check_stmt.zig`, for-of): a non-pair for-of over
  `arr.keys()` sets a new `ForOfStmt.is_array_keys` flag, rewrites the
  iterable to the receiver, and binds the loop variable as `i32`.
  `arr.values()` rewrites to the receiver and falls through to the normal
  array for-of path (it is the identity iterable). Map receivers are
  untouched — `map.keys()`/`map.values()` remain real methods.
- **Emitter** (`lumen_emit_stmt.zig`): `is_array_keys` emits an index-only
  while loop (`while (idx < seq.len)`) binding `@intCast(idx)`, mirroring the
  `.entries()` emission, with label support.

## Verified

`zig build` + `zig build test` green. Probes:

- `for (const i of a.keys())` prints `0 1 2`.
- `for (const v of a.values())` prints `10 20`.
- `outer: for (const i of a.keys()) { if (i == 1) break outer; ... }` — labeled
  break works (prints `0`).
- `map.keys()` and `arr.entries()` unchanged.
