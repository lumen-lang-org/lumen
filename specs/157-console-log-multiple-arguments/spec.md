# Spec 157: console.log with multiple arguments

## Goal

Allow `console.log` (and `.info`/`.debug`/`.error`/`.warn`/`.trace`) to take
several comma-separated arguments, printed space-separated, as in JavaScript:

```ts
console.log("x", "y", "z");     // x y z
console.log("count:", 5);       // count: 5
console.log("result", 42, true, "done");
console.log("array:", [1, 2, 3]);  // array: [1, 2, 3]
```

Previously only a single argument was accepted; a comma reported a syntax error.

## Why additive, not breaking

Only makes previously-rejected programs compile. Single-argument `console.log`
(including array logging, spec 154) is unchanged.

## Semantics

The arguments are printed left-to-right joined by a single space, followed by a
newline — matching JavaScript's `console.log`. Each argument formats by its own
type: scalars with their normal spec, arrays JS-style (`[1, 2, 3]`, spec 154).
The stdout/stderr routing per method is unchanged.

## Requirements

- **FR-001**: `console.log(a, b, c)` prints the arguments space-separated with a
  trailing newline.
- **FR-002**: Mixed argument types (string, number, boolean, array) each format
  correctly.
- **FR-003**: Single-argument `console.log` is unchanged.

## Success Criteria

- **SC-001**: `console.log("x", "y", "z")` -> `x y z`;
  `console.log("count:", 5)` -> `count: 5`.
- **SC-002**: `console.log("result", 42, true, "done")` ->
  `result 42 true done`; `console.log("array:", [1,2,3])` -> `array: [1, 2, 3]`.
- **SC-003**: `console.log("single")` still works.
- **SC-004**: `zig build` and `zig build test` stay green.
