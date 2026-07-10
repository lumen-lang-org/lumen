# Spec 145: fix string-array indexing regressed by spec 144

## Goal

Fix a regression introduced by spec 144: indexing a `string[]` (e.g. the result
of `split`) produced invalid code and failed to build.

```ts
const parts = "a,b,c".split(",");
parts[1]     // "b"   (spec 144 made this fail to build)
```

## Root cause

Spec 144 detected string index access by checking whether the index's element
type was `string`. But that is also true for a `string[]` array, whose *element*
type is `string`. So `parts[1]` was wrongly lowered as a one-byte substring of
the array value, producing a Zig type error.

## Fix

Distinguish the two cases by the receiver, not the element type: the checker sets
a dedicated `string_char` flag on the index node only when the indexed object is
itself a string. The emitter emits the one-byte substring only when that flag is
set; a `string[]` index goes through normal array element access.

## Requirements

- **FR-001**: `s[i]` on a string yields a length-1 string (spec 144 behavior).
- **FR-002**: `a[i]` on a `string[]` yields the element string.
- **FR-003**: Chained `a[i][j]` (array element, then character) works.

## Success Criteria

- **SC-001**: `"a,b,c".split(",")[1]` -> `b`.
- **SC-002**: `"Hello"[0]` -> `H`.
- **SC-003**: `["x","y","z"][0][0]` -> `x`.
- **SC-004**: `zig build` and `zig build test` stay green.
