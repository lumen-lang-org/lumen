# Spec 439 — `process.env` dot and bracket access

## Problem

Reading an environment variable in Lumen required the call spelling
`process.env("HOME")`. The idiomatic Node/TypeScript forms failed:

```ts
process.env.HOME        // error: undefined variable 'process'
process.env["HOME"]     // error
process.env[key]        // error
```

## Change

Two rewrites in `exprType` (`lumen_check_expr.zig`), both gated on `process`
not being shadowed by a local binding:

- **Dot form** (`.field`): `process.env.NAME` — an outer field whose object is
  the field `process.env` — is rewritten to `process.env("NAME")`, using the
  accessed field name as the string key.
- **Bracket form** (`.index`): `process.env[keyExpr]` is rewritten to
  `process.env(keyExpr)`, so both a string literal and a variable key work.

Both lower to the existing `process.env(key)` lookup, which returns
`string | null` (so `?? fallback` handles a missing variable).

## Verification

- `zig build` and `zig build test` clean.
- `process.env.HOME`, `process.env["HOME"]`, and `process.env[key]` (variable
  key) all read the variable.
- A missing variable yields `null` → `process.env.MISSING ?? "fallback"` returns
  the fallback.
- The existing `process.env("HOME")` call form still works.
