# Spec 170: array rest destructuring

## Goal

Support a rest element in array destructuring, binding the remaining elements as
an array:

```ts
const [first, ...rest] = [1, 2, 3, 4, 5];  // first = 1, rest = [2, 3, 4, 5]
const [head, ...tail] = "a,b,c".split(",");
```

Previously a `...` in a destructuring pattern was a syntax error.

## Why additive, not breaking

Only makes previously-rejected programs compile. Plain array/object
destructuring (spec-era) is unchanged.

## Semantics

In an array-destructuring pattern `[a, b, ...rest]`, the rest binding — which
must be the last element — binds an array (`T[]`) of the elements after the
fixed positions; the fixed bindings take their positional element. A rest
element that is not last reports `E_TYPE_MISMATCH`. An array-literal source is
wrapped in a real slice so the rest slice and runtime indexing work.

## Requirements

- **FR-001**: `[a, ...rest] = arr` binds `a` to `arr[0]` and `rest` to the
  remaining elements as `T[]`.
- **FR-002**: The rest binding must be the last element.
- **FR-003**: A rest over a source with no trailing elements binds an empty
  array.
- **FR-004**: Object destructuring and non-rest array destructuring are
  unchanged.

## Success Criteria

- **SC-001**: `const [first, ...rest] = [1,2,3,4,5]` gives `first == 1`,
  `rest == [2,3,4,5]`.
- **SC-002**: `const [x, y, ...others] = [1,2,3,4,5]` gives `others == [3,4,5]`.
- **SC-003**: `const [only, ...empty] = [42]` gives `empty.length == 0`;
  `const [head, ...tail] = "a,b,c".split(",")` gives `tail == ['b','c']`.
- **SC-004**: `zig build` and `zig build test` stay green.
