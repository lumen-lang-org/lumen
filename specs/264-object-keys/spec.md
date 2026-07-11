# Spec 264: Object.keys on record types

## Goal

```ts
type Point = { x: i32, y: i32, label: string }
const ks: string[] = Object.keys(p)      // ["x", "y", "label"]
for (const k of Object.keys(p)) { ... }
```

Previously `Object` was undefined.

## Semantics

Record shapes are static, so `Object.keys(record)` is a compile-time
string-array literal of the type's declared field names (declaration
order). The receiver expression is still evaluated (an otherwise-unused
local counts as referenced). Other `Object.*` members and non-record
arguments report guidance (`only Object.keys is supported…`,
`Object.keys needs a record type, got `T``).

## Success Criteria

- **SC-001**: keys list, length, and for-of iteration all work.
- **SC-002**: `Object.values(...)` and `Object.keys(42)` report the
  tailored messages.
- **SC-003**: `zig build` and `zig build test` stay green.
