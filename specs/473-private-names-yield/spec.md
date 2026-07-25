# Feature Specification: Private Names Yield

## Problem

Two modules each declared a file-local helper:

```ts
// agents/scan.ts          // rest/router.ts
function hexDigit(...)     function hexDigit(...)
```

Neither is exported. Importing both packages into one program was
`E_DUPLICATE_BINDING` against a function the second author has never seen and
could not have avoided naming.

This is the spec 463 fault — one flat namespace — in its most clearly wrong
form: a *private* declaration cannot be named from outside its module, so
there is no observer for whom the collision exists. The compiler invented it.

## Design

One branch in the physical-name assignment in `appendExpandedSource`
(`src/lumen.zig`). The mechanism — `freshName` plus a rename applied to the
module's own text — already existed for importer-forced renames; only the
default changes:

> A value declaration that is not exported and not a default export, whose
> name is already claimed, silently takes a fresh physical name.

Exported declarations, default exports and type names keep today's rules.

## What this fixes, and what it does not

Fixed — verified by running each:

1. Two modules' private helpers sharing a name; both keep working.
2. The entry module's private helper against an imported module's private one.
3. An *exported* `helper` imported first, a private `helper` in a module
   loaded later.

Not fixed:

4. The mirror of (3): a private `helper` in a module loaded *first*, and a
   later module exporting `helper`. The private declaration claimed the plain
   name, and by the time the exported one arrives, the earlier module's text
   is already emitted — the rename cannot be retroactive in this design.

Case 4 is import-order-dependent, which is exactly why it is not worth a
mechanism of its own: the honest fix is spec 463's module-derived physical
names for every declaration, which makes claiming — and therefore order —
meaningless. This spec is the increment that removes the commonest collision
class without prejudging 463's diagnostics question.

## Success Criteria

1. Cases 1–3 above compile and run.
2. `zig build test` passes; the conformance failure set is unchanged.
3. std-contrib: agents (with `scan.ts`) and rest (with `router.ts`) compile
   into one program — the collision that motivated this.

## Notes

A step toward spec 463, not a substitute. 463 remains open, and case 4 is its
acceptance test now.
