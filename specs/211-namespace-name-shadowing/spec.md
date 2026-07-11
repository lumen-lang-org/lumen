# Spec 211: a local variable shadows a std namespace name

## Goal

Let a local variable named like a standard-library namespace (`fs`, `path`,
`os`, `process`, …) be used normally, including method calls:

```ts
const fs = ["a.ts", "b.js", "c.ts"];
fs.filter(f => f.endsWith(".ts")).length;   // 2

const path = ["x", "y"];
path.join("/");   // "x/y"
```

Previously `fs.filter(...)` (with `fs` a local array) reported
`E_UNSUPPORTED_STD` — the parser eagerly treated `fs.method(...)` as a call on
the `fs` module namespace, ignoring the local binding.

## Root cause

The parser rewrites `name.method(...)` into a namespace static call whenever
`name` is a known std namespace, because it has no binding information. A local
variable of that name was therefore mis-parsed as a namespace access.

## Fix

The checker re-routes a namespace static call to an instance method call on the
variable when a local binding of that name exists (and no explicit type
arguments are present). A genuine namespace call — no shadowing binding — is
unchanged.

## Why additive, not breaking

Only makes previously-rejected programs compile. `fs.readFileSync(...)`,
`path.join(...)`, `Math.max(...)`, etc. with no shadowing binding are unchanged.

## Requirements

- **FR-001**: A local variable named like a std namespace supports its own
  methods (`fs.filter`, `path.join`, `os.map`, …).
- **FR-002**: A genuine namespace call (no local binding of that name) is
  unchanged.

## Success Criteria

- **SC-001**: `const fs = [...]; fs.filter(f => f.endsWith(".ts"))` compiles and
  runs.
- **SC-002**: `const path = ["x","y"]; path.join("/")` -> `x/y`; `const os =
  [...]; os.map(...)` works.
- **SC-003**: `path.join("a","b","c")`, `Math.max(...)`, `JSON.stringify(...)`
  (no shadowing) still work.
- **SC-004**: `zig build` and `zig build test` stay green.
