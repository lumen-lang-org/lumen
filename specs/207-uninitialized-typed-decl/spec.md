# Spec 207: uninitialized typed declaration (`let x: T;`)

## Goal

Allow a `let`/`var` declaration with a type annotation but no initializer, to be
assigned later:

```ts
let label: string;
if (n > 5) label = "big";
else label = "small";
console.log(label);
```

Previously `let x: T;` (no `= ...`) was a syntax error; an initializer was
required.

## Why additive, not breaking

Only makes previously-rejected programs compile. Initialized and type-inferred
declarations are unchanged.

## Semantics

`let x: T;` binds `x` with the annotated type `T` and no initial value; it is
mutable and must be assigned before it is read (as in TypeScript). A type
annotation is required — the type cannot be inferred from a missing initializer,
so `let x;` remains an error. The declaration lowers to `var x: T = undefined;`.

## Implementation

- Parser: a declarator with an annotation and no `=` sets `no_init` and fills
  `init` with a throwaway placeholder.
- Checker: binds the annotated type and skips the initializer assignability
  check for a `no_init` declaration.
- Emit: emits `var x: T = undefined;` (always `var`, since it must be assigned).

## Requirements

- **FR-001**: `let x: T;` declares `x: T` with no initializer; a later `x = e`
  assigns it.
- **FR-002**: An annotation is required; `let x;` (no annotation, no init) is a
  syntax error.
- **FR-003**: Initialized and inferred declarations are unchanged.

## Success Criteria

- **SC-001**: `let x: i32; x = 5;` yields `5`; multiple reassignments work.
- **SC-002**: `let label: string;` assigned in both branches of an if prints the
  chosen value.
- **SC-003**: `let x: i32 = 10;` and `let x = 5;` still work; `let x;` errors.
- **SC-004**: `zig build` and `zig build test` stay green.
