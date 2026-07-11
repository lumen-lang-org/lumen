# Spec 188: empty array literal in a ternary branch

## Goal

Let an empty array literal `[]` borrow its element type from the other branch of
a ternary, enabling the common conditional-collect idiom:

```ts
const xs: i32[] = cond ? [1, 2] : [];
[1, 2, 3, 4].flatMap(x => x % 2 === 0 ? [x] : []);   // [2, 4]
```

Previously `cond ? [x] : []` failed (`[]` has no self-inferable element type),
which also blocked the `flatMap`-as-filter pattern (spec 187).

## Why additive, not breaking

Only makes previously-rejected programs compile. A ternary whose branches are
both typed, both scalar, or both empty is unchanged.

## Semantics

When exactly one branch of a ternary is an empty array literal, the other branch
is typed first; it must be an array, and the empty branch is assigned against
that array type (which also records the element type so it emits correctly). The
ternary's type is the non-empty branch's array type. Two empty branches remain
uninferable.

## Requirements

- **FR-001**: `cond ? [<items>] : []` and `cond ? [] : [<items>]` type-check as
  the non-empty branch's array type.
- **FR-002**: `flatMap(x => cond ? [x] : [])` (conditional collect) compiles.
- **FR-003**: Ternaries with two typed branches, two scalar branches, or two
  empty branches are unchanged.

## Success Criteria

- **SC-001**: `const a: i32[] = true ? [1,2] : []` -> `[1,2]`;
  `false ? [] : [3,4]` -> `[3,4]`.
- **SC-002**: `[1,2,3,4].flatMap(x=>x%2===0?[x]:[])` -> `[2,4]`.
- **SC-003**: `["a","","b"].flatMap(s=>s.length>0?[s]:[])` -> `["a","b"]`.
- **SC-004**: `true ? [1] : [2]` and `true ? 1 : 2` still work.
- **SC-005**: `zig build` and `zig build test` stay green.
