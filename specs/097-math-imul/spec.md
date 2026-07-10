# Spec 097: Math.imul

## Goal

`Math.imul` performs a 32-bit integer multiply with wraparound — the standard
primitive for hash functions and fixed-width integer arithmetic, where the
overflow behavior is intentional rather than a bug.

## Why additive, not breaking

Pure addition to `mathCallType` and the `Math.*` emit chain; nothing existing
changes.

## API

- `Math.imul(a: int, b: int): int` — the low 32 bits of `a * b`, interpreted as
  a signed 32-bit integer (wrapping on overflow).

## Requirements

- **FR-001**: Takes exactly two integer arguments and returns `int`; a
  non-integer argument reports `E_TYPE_MISMATCH`, a wrong argument count reports
  `E_ARG_COUNT`.
- **FR-002**: The result wraps modulo 2^32 into the signed 32-bit range, so
  large products match JavaScript's `Math.imul`.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: `Math.imul(3, 4)` -> `12`, `Math.imul(-5, 3)` -> `-15`,
  `Math.imul(100000, 100000)` -> `1410065408` (32-bit wrap).
- **SC-002**: `zig build` and `zig build test` stay green.
