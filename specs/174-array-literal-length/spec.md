# Spec 174: `.length` on an array literal

## Goal

Allow reading `.length` off a bare array literal, the companion to spec 173's
literal indexing:

```ts
[1, 2, 3].length;              // 3
["a", "b", "c", "d"].length;   // 4
```

Previously this passed type-checking but failed to build the native binary (the
literal lowered to a tuple, which has no runtime `.len`).

## Why additive, not breaking

Only makes previously-broken programs compile. `.length` on an array variable or
a chained result is unchanged.

## Semantics

A bare array literal with no spread element (the checker leaves `elem_type` null
in that case) has a statically known length, so `[<items>].length` emits the
item count directly as `@as(i32, N)`. `.length` on any non-literal receiver still
lowers to `@as(i32, @intCast(<obj>.len))`.

## Requirements

- **FR-001**: `[<items>].length` yields the item count for a spread-free literal.
- **FR-002**: `.length` on an array variable or expression result is unchanged.

## Success Criteria

- **SC-001**: `[1,2,3].length` -> `3`; `["a","b","c","d"].length` -> `4`.
- **SC-002**: `const n = [10,20,30,40,50].length` -> `5`.
- **SC-003**: `days.length` (array variable) is unchanged.
- **SC-004**: `zig build` and `zig build test` stay green.
