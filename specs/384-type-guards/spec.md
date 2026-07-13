# 384 — User-defined type guards (`param is Type`)

## Problem

A predicate function returning `param is Type` — the idiomatic way to narrow a
discriminated union behind a named check — was a parse error:

```ts
function isA(u: U): u is A { return u.kind === "a"; }
function f(u: U): i32 { if (isA(u)) { return u.x; } return -1; }  // error at `is`
```

## Change

1. **AST / Parser** (`lumen_ast.zig`, `lumen_parser_decl.zig`): a function return
   annotation of the form `ident is Type` sets `predicate_param` /
   `predicate_type` on the `FunctionDecl` and types the function as returning
   `bool`. A plain identifier return type (not followed by `is`) parses as
   normal via restore.
2. **Checker** (`lumen_check.zig`): `declareFunction` records the guarded
   parameter's index and target type in `FunctionInfo` (validating the parameter
   name and target type). `predicateVariantNarrow(cond)` recognizes a call
   `isA(x)` whose argument is a union-typed variable and whose target is a
   variant of that union.
3. **Narrowing** (`lumen_check_stmt.zig`): a type-guard call used as an `if`
   condition narrows the guarded argument to the predicate's variant in the
   then-branch, reusing the discriminant-narrowing (`narrowed_variants`) path.

## Verified

`zig build` + `zig build test` green. Probes:

- `if (isA(u)) { return u.x; }` — `u` narrows to `A`; `f(a)=5`, `f(b)=-1`.
- `isB` guard over the other variant; `f(b)="hi"`, `f(a)="notb"`.
- A predicate used as a plain boolean (`console.log(isA(a))`) → `true`.
- `function bad(u): v is A` (unknown parameter) → clear diagnostic.
- Regular `: bool` functions unchanged.

## Boundary

The target must be a variant of the guarded argument's discriminated union, and
the argument must be a simple variable. Guards over non-union named types, and
guards whose argument is a field path or call result, are not narrowed.
