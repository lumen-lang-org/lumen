# 381 — Mapped types `{ [K in keyof P]: V }`

The general form of which the utility types (378) are special cases. Reachable
now that `keyof` (379) and indexed access exist.

## Problem

Mapped types were unsupported:

```ts
type Flags = { [K in keyof P]: boolean };   // one boolean per field of P
type Copy  = { [K in keyof P]: P[K] };       // structural copy
type Opt   = { [K in keyof P]?: P[K] };      // Partial, spelled out
```

## Change

1. **AST** (`lumen_ast.zig`): `TypeDecl` carries mapped-type fields —
   `mapped_keys` (the `keyof P` / literal-union source), `mapped_value` (the
   per-field value annotation), `mapped_key` (the bound key variable),
   `mapped_optional`, `mapped_readonly`.
2. **Parser** (`lumen_parser_decl.zig`): in a `type X = { … }` body, a
   `readonly?` then `[ ident in <keys> ]` marks a mapped type; parses the key
   source, an optional `?`, and the value annotation. Non-mapped bodies restore
   and parse normally. The `[…]` type suffix (`lumen_parser_expr.zig`) also
   accepts an identifier key (`P[K]`), kept verbatim for expansion.
3. **Checker** (`lumen_check.zig`, type-registration pass): a mapped type is
   expanded into concrete fields — one per key from `recordKeyLiterals` — with
   `P[K]` substituted to `P["<key>"]` in the value annotation, plus the `?` /
   `readonly` modifiers. The `TypeDecl` is rewritten to a plain record so
   checking and emission treat it uniformly.

## Verified

`zig build` + `zig build test` green. Probes:

- `{ [K in keyof P]: bool }` — every field becomes `bool`.
- `{ [K in keyof P]: P[K] }` — each field keeps its own type.
- `{ [K in keyof P]?: P[K] }` — all optional (unset reads `null`).
- `{ readonly [K in keyof P]: P[K] }` — reads work; a `Ref` write is rejected.
- `{ [K in "mon" | "tue"]: i32 }` — literal-union key source.
- Regular records and `readonly`-field records still parse unchanged.

## Boundary

Value type substitution handles `P[K]` (the homomorphic case) and key-independent
types; key remapping (`as`), and modifier removal (`-?`, `-readonly`) are not
supported. The key source must be a fixed set (`keyof T` or a literal union).
