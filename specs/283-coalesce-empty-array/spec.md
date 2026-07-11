# Spec 283: `?? []` borrows the left side's array type

## Goal

The accumulate-into-a-map idiom works:

```ts
const cur: string[] = nested.get("fruits") ?? []
nested.set("fruits", cur.concat(["pear"]))
```

Previously the empty-array fallback couldn't self-infer ("cannot infer
array type").

## Semantics

When the right side of `??` is an empty array literal and the left's inner
(unwrapped) type is an array, the literal borrows that type and the
expression types as the array — the same contextual trick as
`cond ? [x] : []`.

## Success Criteria

- **SC-001**: The map-of-arrays read-extend-write probe runs.
- **SC-002**: `zig build` and `zig build test` stay green.
