# Spec 132: reduce / reduceRight without an initial value

## Goal

Allow `reduce` and `reduceRight` to be called with just a callback, no initial
value, as JavaScript permits:

```ts
[1,2,3,4].reduce((x, y) => x + y)       // 10
[1,2,3,4].reduceRight((x, y) => x - y)  // -2
```

When the initial value is omitted, the first element (last, for `reduceRight`)
seeds the accumulator and the fold starts from the next element.

## Why additive, not breaking

Purely additive. The two-argument seeded form is unchanged; only the
previously-rejected one-argument form now compiles. The accumulator type in the
seedless form is the array's element type.

## API

- `reduce((acc: T, cur: T) => T): T` and
  `reduce((acc: T, cur: T, i: int) => T): T`
- `reduceRight((acc: T, cur: T) => T): T` and the indexed form.

For the seedless form the callback's accumulator, current, and return types are
all the element type `T`. The optional index parameter counts from `1` for
`reduce` (matching JS: the first call receives index 1) and from `len - 2` down
for `reduceRight`.

## Requirements

- **FR-001**: One or two arguments are accepted; any other count reports
  `E_ARG_COUNT`.
- **FR-002**: With one argument the accumulator type is the element type; the
  callback must be `(T, T) => T` or `(T, T, int) => T`.
- **FR-003**: The two-argument seeded form is unchanged.
- **FR-004**: A single-element array returns that element without calling the
  callback.

### Diagnostics
Reuses `E_ARG_COUNT`, `E_TYPE_MISMATCH`.

## Success Criteria

- **SC-001**: `[1,2,3,4].reduce((x, y) => x + y)` -> `10`;
  `[1,2,3,4].reduce((x, y) => x + y, 100)` -> `110`;
  `[1,2,3,4].reduceRight((x, y) => x - y)` -> `-2`;
  `[10].reduce((x, y) => x + y)` -> `10`;
  `["a","b","c"].reduce((x, y) => x + y)` -> `abc`;
  `[1,2,3,4].reduce((x, y, i) => x + y + i)` -> `16`.
- **SC-002**: `zig build` and `zig build test` stay green.
