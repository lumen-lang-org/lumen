# Spec 438 — `process` properties as property access

## Problem

Node exposes `process.argv`, `process.platform`, `process.pid`, `process.arch`,
and `process.version` as **properties** (no call). Lumen's underlying API only
accepted the call spelling (`process.argv()`), so the idiomatic TypeScript form
failed:

```ts
const args = process.argv;      // error: undefined variable 'process'
console.log(process.platform);  // error: undefined variable 'process'
```

## Change

In the field-access branch of `exprType` (`lumen_check_expr.zig`), a
`process.<name>` access — where `process` is not shadowed by a local binding and
`<name>` is one of the zero-argument property members (`argv`, `platform`, `pid`,
`arch`, `version`) — is rewritten to the equivalent zero-argument static call and
re-checked. Emission is identical to the existing call form.

Method members that take arguments or read like actions (`process.exit(code)`,
`process.cwd()`, `process.hrtime()`, …) are unaffected: they parse as calls, not
field accesses, and are not in the property whitelist.

## Verification

- `zig build` and `zig build test` clean.
- `process.argv`, `process.platform`, `process.pid`, `process.arch`,
  `process.version` all read as properties.
- The existing `process.argv()` / `process.platform()` call forms still work.
- `process.exit(0)` is unchanged.
