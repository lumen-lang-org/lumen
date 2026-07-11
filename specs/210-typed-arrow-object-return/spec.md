# Spec 210: object-literal / empty-array body of a typed-return arrow

## Goal

Let an arrow with an explicit return type return an object literal (or empty
array) whose type comes from that annotation:

```ts
interface P { x: i32; }
const make = (n: i32): P => ({ x: n });
make(5).x;   // 5

const f = (n: i32): i32[] => n > 0 ? [n] : [];
```

Previously a typed arrow returning an object literal reported "cannot infer
variable type" — the object literal has no self-inferable type, and the return
annotation was not used as its expected type.

## Why additive, not breaking

Only makes previously-rejected programs compile. Scalar-returning arrows and
untyped arrows are unchanged.

## Semantics

When an expression-body arrow has a return type annotation, its body is checked
against that annotated type (via structural assignability) rather than typed on
its own. This lets an object literal, an empty array, or a mixed empty/typed
ternary body take its shape from the annotation. Without a return annotation the
body is typed as before.

## Requirements

- **FR-001**: `(args): T => ({...})` types the object literal as `T`.
- **FR-002**: `(args): T[] => ...` accepts an empty-array or conditional body.
- **FR-003**: Scalar-returning and untyped arrows are unchanged.

## Success Criteria

- **SC-001**: `const make = (n: i32): P => ({ x: n })` — `make(5).x` is `5`.
- **SC-002**: `(a, b): Pt => ({ x: a, y: b })` builds a two-field record.
- **SC-003**: `(n): i32[] => n > 0 ? [n] : []` compiles and returns the right
  arrays.
- **SC-004**: `(x): i32 => x * 2` and `x => x * 2` are unchanged.
- **SC-005**: `zig build` and `zig build test` stay green.
