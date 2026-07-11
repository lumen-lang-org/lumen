# Spec 186: array literals that escape (return / store) heap-allocate

## Goal

Fix a silent correctness bug: returning (or otherwise letting escape) a
spread-free array literal produced wrong values.

```ts
function pair(x: i32): i32[] { return [x, x * 10]; }
pair(3);   // was [0, 0]  ->  now [3, 30]
```

## Root cause

A spread-free array literal lowered to `&.{ ... }` — the address of an anonymous
tuple in the current stack frame. When the slice escaped the frame (a `return`,
a stored value), the pointer dangled and reads yielded garbage (typically
zeros). Only literals with a `...spread` element were heap-allocated (via
`std.mem.concat`), so they escaped safely; bare literals did not.

## Fix

A spread-free literal now records its element type (`heap_elem`, set by the
checker on every path that types an array literal — value position, contextual
assignment/return, and gathered rest arguments) and emits a heap allocation
(`__sa().alloc(T, n)` then element-wise assignment, allocate-and-leak, the same
strategy as the rest of the codebase) instead of a stack-tuple address. The
generic-clone path carries `heap_elem` too.

## Why additive, not breaking

Turns silently-wrong programs correct and leaves already-correct programs
unchanged in behavior (immediate uses — indexing, iteration, method receivers —
read the same values; they simply come from a heap slice now). The
`.length`/index static-literal fast paths (specs 173/174) still apply.

## Requirements

- **FR-001**: A spread-free array literal returned from a function yields the
  correct elements at the call site.
- **FR-002**: The same holds when the literal is assigned to a typed binding,
  gathered as rest arguments, or built inside a generic function.
- **FR-003**: Immediate uses (index, `.length`, iteration, method chains) are
  unchanged in value.

## Success Criteria

- **SC-001**: `function pair(x){ return [x, x*10]; } pair(3)` -> `[3, 30]`.
- **SC-002**: `function words(): string[] { return ["hi","bye"]; }` — the caller
  reads `["hi","bye"]`.
- **SC-003**: `[5,2,8,1].sort(...)`, `filter/map` chains, `concat` of two
  returned arrays all produce correct values.
- **SC-004**: `zig build`, `zig build test`, and the `regex_rt.zig` unit test
  stay green.
