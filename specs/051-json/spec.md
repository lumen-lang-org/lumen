# Spec 051: JSON.stringify / JSON.parse<T>

## Goal

Ship `JSON.stringify(value)` and `JSON.parse<T>(text)`. Both were scoped
out early (spec 011's original stdlib roadmap) with an explicit reason:
`stringify` needs "reflection over records," `parse` needs "a tagged-
union/`any` result type" -- neither existed yet. Both prerequisites this
depended on have since shipped (generics in spec 016, discriminated unions
in spec 017), and nobody had gone back to re-check whether that unblocked
anything. It does, but not for the reason originally assumed -- see below.

## The actual unblock: not generics/unions, but Zig's own std.json

Re-checking this from scratch rather than assuming spec 011's original plan
("walk a record's fields, generate per-field (de)serialization code," using
generics to do it once per instantiated type) was still the right shape.
Verified directly, before committing to any design: does Zig's `std.json`
already support fully automatic reflection over an arbitrary struct, given
Lumen's record types already lower to real Zig structs with matching field
names?

```zig
const Person = struct { name: []const u8, age: i32, active: bool };
const out = try std.json.Stringify.valueAlloc(alloc, p, .{});
// {"name":"Ada","age":30,"active":true}
const parsed = try std.json.parseFromSlice(Person, alloc, text, .{});
// parsed.value.name == "Grace", etc.
```

Both directions work with zero custom code, confirmed with a real compiled
program. This means the "needs reflection over records" blocker was already
solved the moment Lumen started lowering record types to real Zig structs
(long before generics or unions existed) -- it just took actually checking
`std.json`'s API surface to notice, instead of assuming a from-scratch
field-walking codegen mechanism (spec 011's original, more complex plan)
was still necessary. `stringify`/`parse` become thin wrappers around
`std.json.Stringify.valueAlloc`/`std.json.parseFromSlice`, not a new
compiler subsystem.

## API

| Function | Type | Notes |
| --- | --- | --- |
| `JSON.stringify(value)` | `T -> string` | `T` inferred from the argument's static type, same as every other Lumen builtin. Empty string on an encode failure (Zig's own `std.json.Stringify` can fail on e.g. non-finite floats). |
| `JSON.parse<T>(text)` | `string -> T` | Explicit type argument required -- there's no value to infer `T` from, only a desired result shape. `std.mem.zeroes(T)` on a parse failure (malformed JSON, a field missing, a type mismatch), the same "fallback, don't crash" shape every other fs/http/process function already uses. |

## Design notes

- **`JSON.parse<T>` is the first explicit type argument on a namespace
  call.** Every other generic call site in Lumen so far is a *free*
  function/class (`identity<T>(x)`, `new Box<T>(v)`) -- `StaticCall` (the
  AST node backing `Namespace.method(...)`) had no `type_args` field and
  its one parse site (`lumen_parser_expr.zig`) never looked for a `<...>`
  before the `(`. Both needed a new, small addition, mirroring the
  existing free-function `<T>` parsing exactly (`isCmp("<") and
  looksLikeTypeArgs()` before consuming `(`).
- **`T` must be a type name the checker can resolve to a concrete Zig
  type** -- a named record (`type`/`interface`), or a primitive
  (`string`/`int`/`i64`/`number`/`bool`). Arrays of these work too, since
  Lumen's array types already lower to plain Zig slices, which
  `std.json`'s reflection handles the same way it handles struct fields.
  Not attempted: `Map<K,V>`/`Set<T>`/tuples as `T` -- those lower to
  Lumen-specific runtime types (`LumenMap`/`LumenSet`/positional structs)
  with a different shape than what `std.json`'s default struct/slice
  reflection expects; parsing/stringifying through them would need custom
  `jsonStringify`/`jsonParse` hooks Zig's `std.json` supports but this
  pass doesn't add.
- **No dynamic/`any` JSON value.** Node's `JSON.parse` (no type argument)
  returns a dynamically-shaped value your code narrows at runtime. Lumen
  has no such value and `JSON.parse<T>` doesn't try to fake one -- you
  declare the shape you expect via `T` and get exactly that shape back
  (or `T`'s zero value on any mismatch), never a shape-inspection API.
- **`std.mem.zeroes(T)` as the parse-failure fallback**: matches
  `fs.statSync`'s all-zero/false struct on a missing file, `fs.readvSync`'s
  empty-string trailing chunks, etc. -- consistent with how every other
  fallible builtin degrades in this codebase. For a `string` field this
  produces an empty slice (valid, not a null pointer dereference risk);
  confirmed directly rather than assumed, since a naive zeroed slice could
  plausibly have been unsafe.

## Not planned (this pass)

| Item | Why |
| --- | --- |
| `Map<K,V>`/`Set<T>`/tuple `T` in `JSON.parse<T>`/`stringify` | need custom `jsonStringify`/`jsonParse` hooks on those runtime types, not just automatic reflection -- see design notes above |
| `JSON.parse()` with no type argument (a dynamic/`any` result) | Lumen has no dynamic value type to return; would need one first |
| Pretty-printing / indentation options | `std.json.Stringify.valueAlloc`'s `Options` support this directly if wanted later -- not exposed as a Lumen-facing parameter this pass, matching how `chownSync`-style functions don't expose every underlying option either |
| Custom per-field naming (`@JsonProperty`-style renaming) | no decorator/annotation mechanism in the language (spec 018 explicitly excludes decorators) |
