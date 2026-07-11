# Spec 181: large / exponential float literals

## Goal

Compile float literals of any magnitude, including large exponentials:

```ts
const x = 1e308;   // previously failed to build
const y = 5e-324;
```

Previously a large exponential float literal failed to build the native binary
(only small-magnitude floats worked).

## Root cause

A float literal was emitted as `@as(f64, {d})`. Zig's `{d}` formats an f64 in
plain decimal, so `1e308` expanded to a 309-digit integer literal — a
`comptime_int` too large for Zig to coerce to `f64`, which it rejects.

## Fix

Emit the literal with `{e}` (shortest round-trip scientific) instead:
`@as(f64, 1e308)`. `{e}` always yields a valid float literal and round-trips to
the identical f64 bit pattern, so small-magnitude values are unchanged in value.

## Why additive, not breaking

Only makes previously-broken programs compile and preserves every existing
float's exact value (shortest round-trip is exact). No program that compiled
before changes behavior.

## Requirements

- **FR-001**: A float literal of any finite magnitude compiles.
- **FR-002**: Every float literal keeps its exact f64 value and JS-matching
  formatting.

## Success Criteria

- **SC-001**: `const x = 1e308; x > 1.0` compiles and is true.
- **SC-002**: `0.1 + 0.2` -> `0.30000000000000004`; `2.5e2` -> `250`;
  `1.5e-3` -> `0.0015`.
- **SC-003**: `10.0 / 3.0` -> `3.3333333333333335`; `3.141592653589793` prints
  in full.
- **SC-004**: `zig build` and `zig build test` stay green.
