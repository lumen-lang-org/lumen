# Spec 171: comparing an optional against a value

## Goal

Allow `==`/`!=` (and their strict spellings) between an optional value and a
plain value of the inner type — the common `map.get(k) === v` pattern:

```ts
const m = new Map<string, i32>([["a", 1]]);
m.get("a") === 1;   // true
m.get("z") === 1;   // false (missing key)
m.get("a") !== 1;   // false
```

Previously an optional compared to a non-optional value reported
`E_TYPE_MISMATCH`, forcing a `?? default` unwrap first.

## Why additive, not breaking

Only makes previously-rejected programs compile. Optional-vs-null comparisons
(`x != null`) and value-vs-value comparisons are unchanged.

## Semantics

`opt === v` (where `opt: T | null` and `v: T`) is `true` when `opt` holds a
value equal to `v`, and `false` when `opt` is null. `opt !== v` is the negation
(`true` when null, matching JS's `undefined !== v`). The inner comparison uses
value equality for numbers and content equality for strings.

## Requirements

- **FR-001**: `optional === value` / `!==` (either operand order) type-checks
  when the value's type equals the optional's inner type.
- **FR-002**: A null optional compares unequal to any value.
- **FR-003**: Works for numeric and string inner types.

## Success Criteria

- **SC-001**: `new Map([["a",1]]).get("a") === 1` -> `true`; `=== 2` -> `false`;
  `get("z") === 1` -> `false`.
- **SC-002**: `get("a") !== 1` -> `false`; `get("z") !== 1` -> `true`.
- **SC-003**: For a `Map<string,string>`, `get("k") === "v"` compares by content.
- **SC-004**: `zig build` and `zig build test` stay green.
