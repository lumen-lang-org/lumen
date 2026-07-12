# Spec 295: enum backing coercion in comparisons and templates

## Goal

Completes spec 294 for the remaining contexts:

```ts
enum E { A = 1, B = 2 }
x == E.A;            // compare against backing i32
E.B == 2;
`level ${E.B}`;      // interpolate as backing

enum D { N = "north" }
`heading ${D.N}`;    // string enum interpolates
```

## Semantics

- A comparison between an enum member and its backing scalar (`i32` for a
  numeric enum, `string` for a string enum) checks and lowers as the backing
  type.
- Template interpolation of an enum member uses its backing type for
  formatting.

Both build on spec 294's rule that an enum member *is* its backing value at
runtime.

## Success Criteria

- **SC-001**: `x == E.A`, `E.B == 2`, and enum-vs-enum comparisons work.
- **SC-002**: `${E.B}` and `${D.N}` interpolate correctly.
- **SC-003**: `zig build` and `zig build test` stay green.
