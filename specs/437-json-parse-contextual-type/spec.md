# Spec 437 — `JSON.parse` infers its type from a variable annotation

## Problem

`JSON.parse` needs an explicit result type (it can't be inferred from the input
string), so only the `JSON.parse<T>(s)` spelling worked. The natural
TypeScript form, where the type comes from the variable annotation, failed:

```ts
const data: Person = JSON.parse('{"name":"Al","age":30}'); // error: type mismatch
```

Users had to duplicate the type as `JSON.parse<Person>(...)`.

## Change

In `checkVarDecl` (`lumen_check_stmt.zig`), when a variable has an annotation and
its initializer is a bare `JSON.parse(s)` call (namespace `JSON`, method `parse`,
no type arguments), the annotation string is threaded in as the call's `<T>`
before type-checking. `JSON.parse` then validates and returns that type exactly
as if it had been written explicitly.

The explicit `JSON.parse<T>(s)` form is unchanged (its non-empty `type_args`
skips the injection); an explicit `<T>` that disagrees with the annotation still
reconciles through the normal assignability check.

## Verification

- `zig build` and `zig build test` clean.
- `const data: Person = JSON.parse('{"name":"Al","age":30}')` → `Al is 30`.
- `const nums: number[] = JSON.parse('[1,2,3]')` → `1+2+3`.
- The explicit `JSON.parse<Person>(...)` / `JSON.parse<number[]>(...)` forms
  still work.
