# Spec 289: nested arrays (i32[][], string[][][], ...)

## Goal

Arrays of arrays — matrices, grids, grouped data — to any depth:

```ts
const grid: i32[][] = [[1, 2, 3], [4, 5, 6], [7, 8, 9]];
for (const row of grid) { for (const cell of row) { ... } }
grid[1][2];                       // indexing composes
const t: i32[][] = transpose([[1,2],[3,4]]);
const mapped: i32[][] = rows.map((r: Row): i32[] => r.cells);
const cube: i32[][][] = [[[1]], [[2],[3]]];
```

Previously `i32[][]` was a parse error ("found '['") &mdash; the annotation
parser and the enumerated array types only supported one level.

## Semantics

- A new `nested_array: *const Type` variant wraps any array element type and
  composes to arbitrary depth (`i32[][][]` = `nested_array(nested_array(i32[]))`).
- The `[]`-suffix parser accepts repeated suffixes; `typeFromAnnotation`
  builds the heap-allocated inner Type (arena-less `fromAnnotation` /
  `arrayOf` fall through for one-level cases, unchanged).
- Array literals of arrays (`[[1],[2]]`), empty `[]` against a nested
  annotation, indexing, `for...of`, and array methods returning arrays
  (`map` &rarr; `T[][]`, `.with`, `.concat`) all produce/consume it.
  `zigName`/`mangle`/`same`/`tsName`/`toAnnotation`/`isArray`/`arrayElem`
  handle the variant. Array-literal temporaries are seq-suffixed so a nested
  literal doesn't shadow the outer's local.

## Success Criteria

- **SC-001**: A 2D grid literal iterates (nested `for...of`), indexes
  (`grid[r][c]`), and reports `.length` at both levels.
- **SC-002**: A function taking/returning `i32[][]` (transpose) works;
  `map` producing `i32[][]` works; triple-nested `i32[][][]` works.
- **SC-003**: A class field `string[][]` updated with `.with()` works.
- **SC-004**: `zig build` and `zig build test` stay green.
