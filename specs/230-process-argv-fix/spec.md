# Spec 230: fix `process.argv()` prelude collision

## Goal

Make command-line arguments actually usable:

```ts
const args = process.argv()
console.log("count:", args.length)
for (const a of args) console.log(a)
```

```sh
lumen run app.ts one two   # argv = ["./app", "one", "two"]
```

Previously any program calling `process.argv()` failed to build with
`function parameter shadows declaration of '__args'`.

## Root cause

The argv support emitted a program-level `var __args` global, and the
`__consoleOut` helper (added later) declared a parameter also named `__args` —
Zig rejects the shadowing, so argv and console output could never coexist.
Same prelude-collision class as the earlier `__a`/`__afn` fixes.

## Fix

The global is renamed to the reserved `__lumen_argv` (all three codegen
sites). `process.argv()` composes with `console.log` and `lumen run`'s
argument forwarding.

## Success Criteria

- **SC-001**: `process.argv()` + `console.log` compiles; `lumen run app.ts
  one two` yields a 3-element argv.
- **SC-002**: `zig build` and `zig build test` stay green.
