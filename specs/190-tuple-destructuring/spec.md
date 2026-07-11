# Spec 190: destructuring a tuple value

## Goal

Allow array-pattern destructuring of a tuple value, the natural companion to
tuple-returning functions:

```ts
function pair(): [string, i32] { return ["age", 30]; }
const [k, v] = pair();   // k: string = "age", v: i32 = 30

const t: [i32, string] = [7, "hi"];
const [a, b] = t;        // a: i32 = 7, b: string = "hi"
```

Previously `const [a, b] = tupleValue` reported `E_TYPE_MISMATCH` — the
destructuring path only accepted an array source, so a tuple (which each binding
should read positionally, with its own element type) was rejected.

## Why additive, not breaking

Only makes previously-rejected programs compile. Array destructuring (`const
[a,b,c] = [1,2,3]`, rest bindings) is unchanged.

## Semantics

An array-pattern destructuring whose source has a tuple type binds each name to
the matching positional element, with that position's declared type (the types
may differ per position, unlike an array). The binding count must equal the
tuple's arity; a rest binding is not allowed on a fixed tuple. Each binding reads
the tuple's positional struct field (`.@"i"`).

## Implementation

- Checker: a non-object destructuring whose source types as `tuple_type` assigns
  each binding the corresponding element type, requires a matching count, and
  sets `is_tuple`.
- Emit: an `is_tuple` destructuring reads `src.@"i"` (positional struct field)
  rather than a slice index.

## Requirements

- **FR-001**: `const [a, b] = t` for a tuple `t` binds each element with its own
  type.
- **FR-002**: Works for a tuple variable and a tuple-returning call.
- **FR-003**: The binding count must equal the tuple arity; array destructuring
  is unchanged.

## Success Criteria

- **SC-001**: `const [x,y] = mk()` for `mk(): [i32,i32]` returning `[3,4]` binds
  `x=3, y=4`.
- **SC-002**: `const [k,v] = pair()` for `pair(): [string,i32]` binds `k="age",
  v=30`.
- **SC-003**: A mismatched binding count reports `E_TYPE_MISMATCH`; `const
  [a,b,c]=[1,2,3]` (array) still works.
- **SC-004**: `zig build` and `zig build test` stay green.
