# Spec 257: Date.now()

## Goal

The standard JS timing idiom works:

```ts
const t0: i64 = Date.now()
// ... work ...
const elapsed: i64 = Date.now() - t0
const f: f64 = Date.now()      // promotes (spec 256)
```

Previously `Date` was an undefined variable.

## Semantics

`Date.now()` returns milliseconds since the Unix epoch as `i64` (real epoch
milliseconds exceed 32 bits), sharing the `time.now()` runtime primitive.
The rest of the Date object (constructor, toISOString, ...) remains future
work and reports the usual unsupported diagnostic.

## Success Criteria

- **SC-001**: `Date.now()` compiles, returns a plausible epoch value, and
  differences are non-negative across work.
- **SC-002**: Assigning it to `f64` works via numeric promotion.
- **SC-003**: `zig build` and `zig build test` stay green.
