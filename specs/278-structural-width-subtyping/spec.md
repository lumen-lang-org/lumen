# Spec 278: structural width subtyping for records

## Goal

TS's bread-and-butter structural pattern works:

```ts
interface Named { name: string }
type Person = { name: string, age: i32 }
function describe(n: Named): string { return "name=" + n.name }
describe(p)                 // p: Person — extra fields are fine
const n: Named = p          // assignment too
```

Previously: "type mismatch: expected `Named`, got `Person`".

## Semantics

A record value flows into a narrower record type when the target's every
field exists on the source with the same name and type. The coercion builds
the narrower record from field reads (records are values, so this matches
copy semantics); only cheap re-emittable sources (a variable or field path)
qualify. A source missing a field or with a differently-typed field still
mismatches; depth subtyping (nested narrowing) is not attempted.

## Success Criteria

- **SC-001**: Wide→Narrow works in declarations and call arguments;
  reads on the narrow view return the right values.
- **SC-002**: A structurally incompatible pair still errors with
  expected/got.
- **SC-003**: `zig build` and `zig build test` stay green.
