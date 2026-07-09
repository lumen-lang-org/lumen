# Spec 063: string-method completion (padEnd, trim edges, replaceAll, fromCharCode)

## Goal

Spec 014 shipped the first tranche of string instance methods and explicitly
deferred a handful of common siblings ("Out of scope this cycle"). Their
absence forced downstream std-contrib packages to hand-roll `int`->char
conversion and alphabet-index lookups. This spec closes that gap by adding the
direct siblings of already-working methods, lowered through the same uniform
inline-block machinery.

## Why additive, not breaking

Pure additions. Every new method reuses an existing lowering pattern
(`padStart`, `trim`, `replace`, and the `String` static namespace); nothing
existing changes shape or behavior.

## API

Instance methods on a `string` value:

- `padEnd(len: int, pad: string): string` — right-pad to `len` using `pad`
  (repeated/truncated), no-op when already at least `len`. Sibling of `padStart`.
- `trimStart(): string` — strip leading ` \t\r\n`. Sibling of `trim`.
- `trimEnd(): string` — strip trailing ` \t\r\n`. Sibling of `trim`.
- `replaceAll(from: string, to: string): string` — replace every
  non-overlapping occurrence (empty `from` is a no-op, matching `replace`).

Static method on the `String` namespace:

- `String.fromCharCode(code: int): string` — single byte, `code & 0xFF`.

V1 strings stay byte slices; indices and code points are byte-oriented.

## Requirements

- **FR-001**: Each method is callable with TypeScript call shape and yields the
  documented result type (`string`).
- **FR-002**: `string`-typed arguments must be assignable to `string`; the
  `padEnd` length and `fromCharCode` code arguments must be integers. A
  mismatched argument type reports `E_TYPE_MISMATCH`.
- **FR-003**: A wrong argument count reports `E_ARG_COUNT`
  (`padEnd`/`replaceAll` take 2, `trimStart`/`trimEnd` take 0,
  `String.fromCharCode` takes 1).
- **FR-004**: `replaceAll` replaces all non-overlapping occurrences left to
  right; a zero-length `from` leaves the receiver unchanged, mirroring
  `replace`.
- **FR-005**: `String.fromCharCode` masks the code point to a single byte
  (`code & 0xFF`).

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: A program exercising each method compiles and the produced native
  binary prints the expected results (`"5".padEnd(3, "0")` -> `500`,
  `"a-b-c-d".replaceAll("-", "+")` -> `a+b+c+d`,
  `String.fromCharCode(322)` -> `B`).
- **SC-002**: A mismatched argument type and a wrong argument count each fail
  before native build.
- **SC-003**: `zig build` and `zig build test` stay green.
