# Spec 201: switch case fall-through

## Goal

Make an empty (fall-through) switch case actually fall through to the next
clause, for both value and statement forms:

```ts
switch (grade) {
  case 1: case 2: case 3: return "low";
  case 4: case 5:          return "high";
  default:                 return "?";
}
```

Previously an empty case value silently ran nothing (and, for a value-returning
switch, produced a function that returned nothing on that value).

## Root cause

The switch lowered each case to an independent `if (v == k) { body }`. An empty
case body became `if (v == 0) {}` — matching the value but running nothing and
then exiting the switch, so it did not fall through to the next clause.

## Fix

Consecutive empty-body cases now OR their match conditions onto the next
non-empty case (`if (v == 0 or v == 1) { body }`). Trailing empty cases with no
following non-empty case fall to the `else` (default) automatically, so they
need no branch.

With fall-through fixed, a function-terminating switch whose branches include
empty fall-through cases leading to returning bodies also satisfies the
return-path check (spec 200).

## Why additive, not breaking

Turns silently-wrong behavior correct. A switch with no empty cases is
unchanged.

## Requirements

- **FR-001**: An empty case runs the next non-empty case's body.
- **FR-002**: Grouped labels (`case a: case b: case c: body`) all run the body.
- **FR-003**: A trailing empty case falls to `default`; non-empty cases and
  `default` are unchanged.

## Success Criteria

- **SC-001**: `switch(n){case 0:case 1:return "small";default:return "big";}` —
  `n=0` and `n=1` both return `small`; `n=9` returns `big`.
- **SC-002**: `case 1:case 2:case 3:return "low"` returns `low` for 1, 2, and 3.
- **SC-003**: `case 9: default: return "d"` — `n=9` returns `d`.
- **SC-004**: A non-fall-through switch is unchanged.
- **SC-005**: `zig build` and `zig build test` stay green.
