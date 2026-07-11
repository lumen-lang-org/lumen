# Spec 195: object destructuring with rename (`{ field: local }`)

## Goal

Support renaming a field while destructuring an object:

```ts
interface P { x: i32; y: i32; }
const p: P = { x: 1, y: 2 };
const { x: myX, y: why } = p;   // myX = 1, why = 2
```

Previously `{ field: local }` was a syntax error; only same-name bindings
(`{ x, y }`) parsed.

## Why additive, not breaking

Only makes previously-rejected programs compile. Same-name object destructuring
and array destructuring are unchanged.

## Semantics

`const { field: local } = obj` reads `obj.field` and binds it to `local` (with
`field`'s declared type). Renamed and same-name bindings may be mixed in one
pattern (`{ x, y: why }`).

## Implementation

- AST: a destructuring binding gains `field_name` — the source field when
  renamed (`name` remains the local binding).
- Parser: an object-pattern entry `ident : ident` records the first ident as
  `field_name` and the second as `name`.
- Checker/emit: the field looked up and read is `field_name orelse name`; the
  binding introduced is `name`.

## Requirements

- **FR-001**: `{ field: local }` reads `obj.field` and binds `local`.
- **FR-002**: Renamed and same-name bindings mix in one pattern.
- **FR-003**: Same-name object destructuring and array destructuring are
  unchanged.

## Success Criteria

- **SC-001**: `const { x: myX } = p` binds `myX = p.x`.
- **SC-002**: `const { a: num, b: str } = p` binds both renamed fields.
- **SC-003**: `const { x, y: why } = p` mixes same-name and renamed.
- **SC-004**: `zig build` and `zig build test` stay green.
