# Spec 296: arrays of optionals + unified array-annotation resolution

## Goal

Arrays whose elements are nullable, in both spellings:

```ts
const xs: (string | null)[] = ["a", null, "b"];
const ys: Array<i32 | null> = [1, null, 3];
const results: (string | null)[] = ids.map((n: i32): string | null => lookup(n));
for (const r of results) { if (r != null) found++; }
```

Previously `(T | null)[]` was a parse error (the `(` was always read as a
function type) and `Array<T | null>` resolved to a bogus named type that
failed on any real use.

## Semantics

- `arrayOfAlloc` now wraps any element type that lacks an enumerated array
  form — arrays (289), tuples (291), and now optionals — in a heap-allocated
  `nested_array`. Only `void`/`none` have no array form.
- `typeFromAnnotation` resolves a trailing `[]` uniformly: strip one `[]`,
  resolve the element, wrap via `arrayOfAlloc`. It runs after the
  function-type check so `(i32) => i32[]` (a function returning an array)
  is not misread. This also fixes alias arrays (`Row[]` where
  `type Row = i32[]`).
- The type-annotation parser disambiguates `(` : it tries the function-type
  form and, on failure, parses a parenthesized type with an optional `[]`
  suffix — so `(T | null)[]` parses.

## Success Criteria

- **SC-001**: `(string | null)[]` and `Array<i32 | null>` compile, hold
  null elements, iterate, and narrow per element.
- **SC-002**: `map` returning `T | null` yields a `(T | null)[]`.
- **SC-003**: Function-type parameters, tuples, nested arrays, and tuple
  arrays are unregressed; `zig build` and `zig build test` stay green.
