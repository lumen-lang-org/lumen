# Spec 330 — Optional function-typed record fields

## Goal

Make an optional field whose type is a function behave like any other optional
field:

```ts
type Handlers = { onClick?: () => string };
const a: Handlers = {};                        // ok — onClick omitted
const b: Handlers = { onClick: () => "hi" };   // ok
console.log(b.onClick?.() ?? "none");          // "hi"
```

## Motivation

An optional member's `?` was applied by appending `?` to the annotation text.
For a scalar (`x?: i32` → `i32?`) this was fine, but for a function type
(`greet?: () => string`) it became `() => string?` — parsed as a function
*returning* `string | null`, not an *optional* function. The field was then
treated as required, so `{}` failed with "missing property 'greet'".

## Behavior

An optional field of any type is `T | null`: it may be omitted from an object
literal and read back through optional chaining. Function-typed optional fields
now work like scalar and record optional fields; scalar/string optional fields
are unchanged.

## Implementation

- `src/lumen_parser_decl.zig`: `parseOptionalMember` parenthesizes the annotation
  before appending the optional marker (`(T)?`), so the optionality applies to
  the whole type rather than binding to its tail.

## Verification

- `zig build` and `zig build test` green.
- An optional function field can be omitted or provided; `p.fn?.()` returns the
  result when present and short-circuits to `null` when absent; optional scalar,
  string, and record fields are unaffected.
