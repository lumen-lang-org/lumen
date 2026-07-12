# Spec 298: calling computed function values

## Goal

Call a function value that isn't a bare name:

```ts
adder(10)(5);                 // call the returned function
fns[0](7);                    // call an array element
h.run(10);                    // call a function-typed record field
const opt: ((x: i32) => i32) | null = ...;   // optional function type parses
```

Previously each was a parse error ("expected ')', found '('") or a type
mismatch — the postfix parser only allowed a call after a `.method`, and
function-typed record fields weren't callable.

## Semantics

- The postfix parser accepts a `(` directly on the expression built so far,
  producing a value call (the existing `optional_call` node with the chain
  flag off): `expr(args)`. The callee must have a `func_type`; args are
  checked against its signature and the call yields its return type.
- `obj.field(args)` where `field` has a function type on a record is
  rewritten to a value call on the field access.
- The parenthesized-type parser (spec 296/297) now also accepts a trailing
  `| null`, parenthesizing the element (`((i32)=>i32)?`) so an optional
  function type stays distinct from a function returning an optional.

## Success Criteria

- **SC-001**: Curried calls (`adder(10)(5)`), array-element calls
  (`fns[0](7)`), and function-field calls (`h.run(10)`) all evaluate.
- **SC-002**: Calling a non-function value reports the tailored error; wrong
  arity on a value call reports counts.
- **SC-003**: Normal calls, class methods, closures, `a?.()`, and map
  callbacks are unregressed; `zig build` and `zig build test` stay green.
