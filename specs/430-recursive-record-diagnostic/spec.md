# 430 — clear diagnostic for a self-referential record type

## Context

Recursive/linked data structures (linked lists, trees) are already supported —
via **classes**, whose instances are heap pointers (`*Node`), so a field
`next: Node | null` is `?*Node` and self-reference is fine:

```ts
class ListNode { constructor(public val: int, public next: ListNode | null) {} }
class TreeNode { constructor(public val: int, public left: TreeNode | null, public right: TreeNode | null) {} }
```

Both traverse (iteratively and recursively) and run correctly.

## Problem

A recursive **record type** — a value struct that can't contain itself — failed
with a cryptic backend error:

```ts
type Node = { val: number; next: Node | null };
// backend: type '.lumen-p.Node' depends on itself for field declared here
```

## Approach

`lumen_check.zig`: after type registration, scan each non-interface record type
for a field whose base type (stripping `?`, `[]`, and `| null` / `| undefined`)
names the record itself, and report an actionable error pointing at `class`:

> record type `Node` references itself (`next: Node?`) — a value record can't
> contain itself; use a `class` for a recursive/linked structure (its instances
> are heap references)

## Verification

- `type Node = { …; next: Node | null }` and `type Tree = { …; children: Tree[] }`
  report the clear diagnostic instead of the backend error.
- Non-recursive records and records referencing *other* records are unaffected.
- Recursive **classes** (linked lists, trees) build and run — `sum`/`length`/
  `treeSum` verified (`10`, `4`, `15`).
- Full `zig build` + test suite green.

## Notes

Supporting recursive *value* records would require pointer indirection that
contradicts the value-record model; classes already provide the reference
semantics recursion needs, so the diagnostic redirects there.
