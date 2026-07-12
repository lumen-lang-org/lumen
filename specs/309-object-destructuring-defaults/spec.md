# Spec 309 — Object destructuring defaults

## Goal

Support default values in object destructuring patterns:

```ts
type P = { x?: i32 };
const { x = 9 } = p;   // x = 9 when the property is absent
```

Renamed bindings take a default too: `const { y: v = 7 } = p;`.

## Motivation

Object patterns previously rejected `= default` with `expected '}', found '='`.
Defaults on optional properties are the idiomatic way to supply a fallback.

## Behavior

- When the property is optional (`x?: T`), the binding takes the non-optional
  type `T`; an absent property falls back to the default.
- When the property is required, it is always present, so the default is
  accepted but never used and the field value passes through.
- The default must be assignable to the (non-optional) property type.

```ts
type P = { x?: i32 };
const { x = 9 } = ({} as P);        // 9
const { x = 9 } = ({ x: 3 } as P);  // 3
```

## Implementation

- `src/lumen_ast.zig`: `DestructBinding` gains `default_unwraps` (the source
  field is optional, so lower to `orelse`).
- `src/lumen_parser.zig`: object shorthand and renamed bindings accept an
  optional `= <expr>` default.
- `src/lumen_check_stmt.zig`: the binding takes the unwrapped property type; the
  default is checked assignable to it; `default_unwraps` records optionality.
- `src/lumen_emit_stmt.zig`: an optional-property default lowers to
  `src.field orelse <default>`; a required property passes the field through.

## Verification

- `zig build` and `zig build test` green.
- Absent optional property yields the default; present property yields its
  value; required property passes through; renamed defaults work; array
  destructuring defaults (spec 308) are unchanged.
