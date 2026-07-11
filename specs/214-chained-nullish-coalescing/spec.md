# Spec 214: chained nullish coalescing (`a ?? b ?? c`)

## Goal

Support `??` where the right operand is itself optional, i.e. a fallback chain:

```ts
const a: i32 | null = null;
const b: i32 | null = 7;
a ?? b ?? 0;   // 7

const c: string | null = null;
const d: string | null = "hi";
c ?? d ?? "none";   // "hi"
```

Previously `a ?? b` where `b` was also `T | null` reported `E_TYPE_MISMATCH` —
the right operand had to be the non-optional inner type — so a chain like
`a ?? b ?? 0` did not type-check.

## Why additive, not breaking

Only makes previously-rejected programs compile. `a ?? <value>` and `a ?? 5`
are unchanged.

## Semantics

`a ?? b` yields `a`'s value when non-null, otherwise `b`. When `b` is the
non-optional inner type the result is that type; when `b` is itself `T | null`
the result stays `T | null`, so a further `?? d` unwraps the chain. The result
type is recorded on the node and pinned in codegen so the emitted expression
keeps the correct optionality (Zig peer-type resolution alone would collapse it
to the non-optional type).

## Requirements

- **FR-001**: `a ?? b` type-checks when `b` is `T` or `T | null`.
- **FR-002**: `a ?? b` with an optional `b` stays optional; a further `?? d`
  resolves it.
- **FR-003**: `a ?? <value>` and single `??` are unchanged.

## Success Criteria

- **SC-001**: `a ?? b ?? 0` — `3, null → 3`; `null, 7 → 7`; `null, null → 0`.
- **SC-002**: `c ?? d ?? "none"` (strings) resolves the chain.
- **SC-003**: `map.get(k) ?? 0`, `(a ?? 10) * 2`, and optional-field `??` are
  unchanged.
- **SC-004**: `zig build` and `zig build test` stay green.
