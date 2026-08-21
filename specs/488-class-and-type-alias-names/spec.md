# Spec 488: a class and a type alias may share a name across modules

## Goal

```ts
// session/types.ts
export type ApprovalGate = { check: (call: string) => boolean };

// approval/gate.ts -- does not import the file above, has no relation to it
export class ApprovalGate {
  mode: string;
  constructor(mode: string) { this.mode = mode; }
}
```

A program that reaches both files fails:

```text
error: duplicate struct member name 'ApprovalGate'
note: the native backend rejected this statement's generated code
```

Naming a concrete class after the interface type it satisfies is ordinary, and
the two declarations here live in different modules with no import between
them. The class author has not read the type author's file, and in TypeScript
would never need to.

## Why it happened

Imports are inlined into one flat program (`readSourceWithImports`,
`src/lumen.zig`). The expander keeps two namespaces, because the language does:
a `type Result` and a `const Result` do not collide. A value declaration
therefore asks `ownedByOther`, which consults **both** tables, while a type
declaration only ever looked at the type table.

That asymmetry is the bug. With the class scanned first, the later type alias
saw an empty type table, kept its own name, and the two declarations went into
the flat program under one spelling. The generated backend has a single
namespace, so it rejected the second struct.

Worse, the collision did not always reach the backend. When the type alias's
own module used its type in an annotation, the checker resolved that annotation
to the *other* module's class and reported a type mismatch on a line that is
correct as written -- the wrong symbol found silently, in a file whose author
cannot see why.

Spec 476 already established the rule for the mirror case: a name two modules
choose independently is the compiler's to absorb, and renaming a declaration is
invisible to importers because they resolve through the exporting module's
table.

## Semantics

When a type declaration's name is already claimed by a **value** declaration in
a different module (a class, an enum, a function, a binding), the compiler
renames the type declaration and rewrites that module's own references.
Importers are unaffected: a named import of the type resolves through the
exporting module's export table, which records the physical name.

"Different module" is by canonical key, as everywhere else in the expander, so
a module reached by two paths never clashes with itself.

Two modules declaring the same **type** name is unchanged: still an error
naming both module paths (spec 451 D3). That case is two type declarations
competing for one name with nothing else in play, and this slice does not
revisit it.

A file that declares a class and a type alias of the same name in **one**
module is also unchanged. It is one author contradicting themselves, the same
distinction spec 476 draws for values.

## Success Criteria

- **SC-001**: A class in one module and a type alias of the same name in
  another compile together, in either import order, and each resolves to its
  own declaration.
- **SC-002**: The renamed type is still importable by its source name and
  usable in an annotation in the importing file.
- **SC-003**: The type alias's own module resolves its own annotations to its
  own type, not to the other module's class.
- **SC-004**: Two modules declaring the same type name still fail with
  `E_DUPLICATE_TYPE` and both paths named.
- **SC-005**: The same absorption covers an enum, a plain function and a
  binding on the value side, not just a class.

## Implementation

`src/lumen.zig` -- the `.type_name` branch of the declaration loop in
`appendExpandedSource`. The type-versus-type conflict keeps its report; a name
held by another module's value now takes the same `freshName` + `renames` path
the value branch has used since spec 476.
