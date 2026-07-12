# Spec 304: generic functions with rest params and defaults

## Goal

```ts
function collect<T>(...items: T[]): T[] { return items }
collect(1, 2, 3);          // infers T = i32
collect<string>("a", "b"); // explicit
function withDefault<T>(x: T, label: string = "item"): string { return label }
withDefault(5);            // default applies
```

Previously any of these reported `E_ARG_COUNT` or a bare type mismatch: the
generic-call path had its own strict 1:1 arg check that ignored rest,
default, and optional params, and rest-param type inference matched the
whole `T[]` pattern against a single argument.

## Semantics

- A generic call is routed through the shared `checkCallArgs` (like every
  non-generic call), so a specialized function honors rest params, defaults,
  and optional `x?` params.
- Rest-param inference unifies the element pattern (`T` from `...items: T[]`)
  against every trailing argument, so `collect(1, 2, 3)` infers `T = i32`.

## Success Criteria

- **SC-001**: `collect(1, 2, 3)` infers and returns `i32[]`; explicit
  `collect<string>(...)` works.
- **SC-002**: A generic function with a defaulted trailing parameter can
  omit it.
- **SC-003**: `zig build` and `zig build test` stay green.
