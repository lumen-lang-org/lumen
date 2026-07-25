# Feature Specification: Parameter Shadowing

## Problem

Every module is inlined into one flat namespace, and the generated code forbids
a parameter that shadows a top-level declaration. So a parameter in one package
collides with an exported function in a completely unrelated one:

```ts
// packages/plume/plume.ts
export function persist(db: Db, repo: DbRepository, json: string): DbResult { … }

// packages/rest/server.ts
export function json(status: int, body: string): Reply { … }
```

A program importing both is rejected:

```
plume.ts:767:1: error: the parameter 'json' of persist reuses a top-level name —
every module shares one namespace, so a parameter cannot shadow a declaration
[E_PARAM_SHADOWS]
```

A parameter is local scope. Two independent packages must not be able to break
each other by choosing ordinary words — `json`, `path`, `value`, `handler`,
`row`, `field`, `plan`, `files`, `target`. The only fix available to a library
author was to rename their own parameter, which cannot work: they cannot know
what a future package will export, and the collision only appears in the
program that imports both.

`E_PARAM_SHADOWS` was a better message for a rule that should not exist.

## Scope

In scope:

- A parameter may be spelled like any top-level declaration in the program:
  a function, an `extern function`, a class, a record/interface/union type.
- Every path that emits parameters: free functions, class methods and
  constructors, static methods, arrow functions, `extern` declarations,
  generic specializations, `Ref<T>` parameters, and the destination-passing
  `f__into` twins.
- Removing the `E_PARAM_SHADOWS` check, which now rejects valid programs.

Out of scope:

- The flat namespace itself.
- The sibling case, spec 457: a *prelude* parameter colliding with a user's
  top-level name (`function handler(…)` alongside `http.createServer`). That
  one renames from the other end — the prelude's parameters — and remains
  unfixed apart from the fixed list in `safeGlobalName`.

## Design

### D1 — the parameter is renamed in the generated code, never in the source

The generated code is an artifact, so a parameter's emitted identifier is not
anybody's API. A parameter whose name matches a top-level declaration is
emitted under a distinct name; the source keeps the name the author wrote.

### D2 — the rename rides the existing binding machinery

Every local binding already carries an `emit_name` assigned by the checker
(`freshEmitName`), and every reference to it — a read, an assignment, an
`++`, a capture into an arrow's environment, a `Ref<T>` deref — is emitted
through that name rather than the source name. Parameters were the one binding
kind that opted out, binding under their own spelling.

So the fix is to let a parameter take an emit name like anything else:

```zig
fn paramEmitName(self: *Checker, param: *ast.FunctionParam) …
```

It is stored on the AST node (`FunctionParam.emit_name`) so the signature can
be emitted under it, and put in scope so the body follows. Nothing walks the
body; nothing rewrites source text.

An earlier design bound the original name at the top of the body
(`const json = json__mp;`) so the body text could stay untouched. That does not
compile — the backend rejects a *local* shadowing a declaration for exactly the
same reason it rejects a parameter:

```
error: local constant shadows declaration of 'json'
```

The rename therefore has to reach the references, and the binding machinery is
where that already happens.

### D3 — rename only on collision

`paramEmitName` returns the parameter's own name unless the program declares
that name at the top level, so a program without a collision emits byte for
byte what it did before. The names are collected from the checker's own
registries (`funcs`, which includes `extern`s, `generic_funcs`, `classes`,
`generic_classes`, `type_decls`), and only once every declaration pass has run
— a name declared at the bottom of the file counts as much as one at the top.

### D4 — one binding per parameter

A parameter the body reassigns is already emitted as `<name>__mp` with a
mutable `var <name>` bound to it, since parameters are immutable in the
generated code. The two renames compose rather than stack: the reassignment
copy is built from the emitted name, so a shadowing parameter that is also
reassigned gets one binding, not two.

## Success Criteria

1. A program importing plume and rest, calling `persist` and `json`, compiles
   and runs.
2. A parameter may shadow a function, an `extern function`, a class or a record
   type, in a free function, a method, a constructor or an arrow, including a
   `Ref<T>` parameter that still writes through to the caller.
3. `E_PARAM_SHADOWS` is gone.
4. `zig build test` passes; the std-contrib plume and rest suites keep their
   counts.

## Notes

Found while building a service on both packages. Verified by renaming *every*
parameter in the program rather than only the colliding ones: the plume and
rest suites, the compiler tests, and the ref/decorator conformance manifests
all still passed, which is what says the reference paths are complete rather
than merely complete enough for the cases tried.
