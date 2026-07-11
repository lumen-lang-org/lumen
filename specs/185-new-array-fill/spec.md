# Spec 185: `new Array(n).fill(v)` sized-array initializer

## Goal

Support the standard fixed-size array initializer:

```ts
new Array(3).fill(0);    // [0, 0, 0]
Array(4).fill(7);        // [7, 7, 7, 7]
new Array(n).fill("x");  // n copies of "x"
```

Previously `new Array(n)` reported `E_TYPE_MISMATCH` and `Array(n)` reported
`unknown function`, so this whole idiom was unavailable.

## Why additive, not breaking

Only makes previously-rejected programs compile. `arr.fill(v)` on an existing
array and all other array constructors are unchanged.

## Semantics

`new Array(n).fill(v)` and `Array(n).fill(v)` are handled as one fused
construct: `new Array(n)` on its own has no representation (JS produces holes,
which the statically-typed language has no value for), but the immediate
`.fill(v)` supplies the element type (from `v`) and the length (from `n`),
yielding an `n`-length array with every element equal to `v`. The result chains
like any array (`new Array(3).fill(2).map(...)`).

Only the single-argument `.fill(v)` form is fused; a bare `new Array(n)` without
`.fill` is still rejected.

## Implementation

- Checker: a `.fill(v)` method call whose receiver is `new Array(n)` (no type
  arg) or `Array(n)` is detected before receiver typing; the element type comes
  from `v`, the result is `v[]`, and `sized_fill` is set.
- Emit: `sized_fill` allocates an `n`-length slice and `@memset`s it to `v`.

## Requirements

- **FR-001**: `new Array(n).fill(v)` / `Array(n).fill(v)` yield an `n`-length
  `v[]`.
- **FR-002**: `n` may be any integer expression; `v` fixes the element type.
- **FR-003**: The result chains (`.map`, `.join`, `.length`, …); `arr.fill(v)`
  on an existing array is unchanged.

## Success Criteria

- **SC-001**: `new Array(3).fill(0)` -> `[0,0,0]`; `Array(4).fill(7)` ->
  `[7,7,7,7]`.
- **SC-002**: `new Array(3).fill("x").join("-")` -> `x-x-x`.
- **SC-003**: `new Array(3).fill(2).map((x,i)=>x+i)` -> `[2,3,4]`.
- **SC-004**: `zig build` and `zig build test` stay green.
