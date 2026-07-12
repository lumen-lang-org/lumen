# 359 — Exhaustive `switch` over a union discriminant satisfies return analysis

## Problem

A `switch (u.kind)` covering every variant of a discriminated union still
tripped `E_MISSING_RETURN`:

```ts
type A = { kind: "a", x: i32 };
type B = { kind: "b", s: string };
type U = A | B;
function f(u: U): string {
  switch (u.kind) {
    case "a": return "x" + u.x;
    case "b": return u.s;      // all variants covered...
  }                            // ...but: not all code paths return [E_MISSING_RETURN]
}
```

Exhaustiveness was already computed for string-literal unions (spec 266) and
enums, but not for the union-discriminant form — the most common exhaustive
switch in discriminated-union code.

## Change

`lumen_check_stmt.zig`, switch checking: when the subject is a union
discriminant access (`discriminantAccess` non-null) and there is no `default`,
the switch is marked `exhaustive` if every variant's discriminant value appears
as a case. `stmtReturns` already honors the flag, and the emitter already
handles exhaustive switches (`unreachable` tail), so both downstream halves
were in place.

## Verified

`zig build` + `zig build test` green.

- Exhaustive two-variant switch with all-returning cases: compiles, runs,
  prints `x4`.
- Same switch missing the `"b"` case: still fails `E_MISSING_RETURN`.
