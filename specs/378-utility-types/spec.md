# 378 — TypeScript utility types (Partial / Required / Readonly / Pick / Omit)

First step into advanced type-level programming. Lumen's static-shape records
make the record-transforming utility types tractable at compile time.

## Problem

`Partial<P>`, `Required<P>`, `Readonly<P>`, `Pick<P, K>`, and `Omit<P, K>` were
all hard errors ("the `X<...>` utility type is not supported"). These are among
the most-used TS features in real code.

## Change

1. **Checker** (`lumen_check.zig`, new `synthUtilityRecord`): resolves the first
   argument to a named record, transforms its fields, registers the result as a
   synthetic named record, and queues a `type_decl` for emission (the same
   mechanism generic specialization uses). Transforms:
   - `Partial<P>` — every field made optional (`T` → `T?`).
   - `Required<P>` — strip optionality (`T?` → `T`).
   - `Readonly<P>` — every field `readonly` (enforced via the existing
     `E_READONLY_ASSIGNMENT` path).
   - `Pick<P, K>` / `Omit<P, K>` — keep / drop the fields named in the key set
     `K` (a `"a" | "b"` string-literal union, or a single literal).
   Results are cached and mangled by base + arguments, and nest
   (`Partial<Pick<P, "a" | "b">>`).
2. **Parser** (`lumen_parser_expr.zig`): a union of *string literals*
   (`"a" | "b"`) now parses as a joined annotation string instead of being
   rejected, so `Pick`/`Omit` key sets are accepted. General scalar unions
   (`i32 | string`) are still rejected.

## Verified

`zig build` + `zig build test` green. Probes:

- `Partial<P>` — omitted fields read `null` (`q.y ?? -1` → `-1`).
- `Readonly<P>` — reads work; a write through `Ref<Readonly<P>>` is rejected.
- `Pick<P, "x" | "z">` and `Omit<P, "y">` — only the intended fields exist.
- `Required<{ x?: i32 }>` — field becomes non-optional.
- `Partial<Pick<P, "a" | "b">>` — utilities nest.
- Regressions: `type X = i32 | string` still rejected; discriminated unions
  (`type U = A | B`) still work.

## Boundary

Utilities operate on named record types only (their first argument must resolve
to a record). `Record<K, V>`, `keyof`, indexed access (`P["x"]`), mapped types,
and conditional types remain unsupported — those need computed-type machinery
beyond field transformation.
