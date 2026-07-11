# Spec 212: value-returning block-body arrow functions

## Goal

Support an arrow function with a `{ ... }` body that returns a value:

```ts
const clamp = (n: i32): i32 => {
  if (n < 0) return 0;
  return n;
};

const b = [1, 2, 3].map((x: i32): i32 => {
  const y = x * 2;
  return y + 1;
});
```

Previously a block-body arrow was treated as a void body: `return;` was allowed
but `return <value>;` was rejected, so a value-returning block arrow failed with
"cannot infer variable type".

## Why additive, not breaking

Only makes previously-rejected programs compile. Expression-body arrows
(`=> expr`) and void block-body arrows (`(): void => { ... }`) are unchanged.

## Semantics

A block-body arrow with a return type annotation is a value-returning function
body: `return <value>` statements are checked against the annotated type, and
all paths must return (else `E_MISSING_RETURN`). A block-body arrow with no
return annotation remains a void body (as before). The value-returning form
requires the annotation because the return type is not inferred from the body in
V1.

## Requirements

- **FR-001**: `(args): T => { ...; return v; }` type-checks `v` against `T` and
  returns it.
- **FR-002**: All paths must return; a missing return is `E_MISSING_RETURN`.
- **FR-003**: Void block arrows and expression-body arrows are unchanged.

## Success Criteria

- **SC-001**: `(n: i32): i32 => { if (n<0) return -n; return n; }` — `f(-5)=5`,
  `f(3)=3`.
- **SC-002**: `map((x): i32 => { const y = x*2; return y+1; })` over `[1,2,3]`
  gives `[3,5,7]`.
- **SC-003**: A block arrow that misses a return reports `E_MISSING_RETURN`.
- **SC-004**: `(x): void => { console.log(x); }` and `(x): i32 => x*2` are
  unchanged.
- **SC-005**: `zig build` and `zig build test` stay green.
