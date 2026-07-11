# Spec 282: record fields may use Zig-reserved names

## Goal

```ts
type Result = { ok: bool, value: i32, error: string }
r.error          // reads fine
{ ok: false, value: 0, error: "divide by zero" }
```

Previously a field named `error` (or `test`, `type`, `var`, ...) produced a
backend failure — the generated struct field collided with a Zig keyword.

## Semantics

Field names matching Zig keywords/primitives are emitted as `@"name"` in
struct declarations, object literals, and field reads (the shared
`emitFieldName` path). TS-visible behavior is unchanged.

## Success Criteria

- **SC-001**: The Result-record probe compiles and runs, reading `.error`.
- **SC-002**: Ordinary field names emit unquoted as before; `zig build` and
  `zig build test` stay green.
