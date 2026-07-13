# 393 — Object.values(record)

## Problem

`Object.keys(record)` was supported (static field-name list), but
`Object.values(record)` was rejected with "only Object.keys and Object.freeze
are supported". A common, idiomatic pattern — summing or mapping over a
record's values — had no direct form.

```ts
type Scores = { math: number; sci: number };
const s: Scores = { math: 80, sci: 90 };
Object.values(s); // error: only Object.keys and Object.freeze are supported
```

## Approach

Records have static, homogeneous-or-not shapes. `Object.values` only has a
well-typed result when every field shares one element type (JS would produce a
heterogeneous array otherwise, which Lumen's typed arrays can't represent).

- **Check** (`lumen_check_expr.zig`, `Object.<name>` static-call path): accept
  `values` alongside `keys`. Resolve the record's field types; require them all
  equal via `types.same`. The result type is `types.arrayOf(elem)`. Reuse the
  existing `object_keys` field to carry the field-name list to emit, and set a
  new `object_values` marker on the call node.
- **Emit** (`lumen_emit_static.zig`): bind the receiver once (`const __rec = …`)
  so a complex argument isn't re-evaluated, then emit a homogeneous array
  literal `&.{ __rec.f0, __rec.f1, … }` cast to `[]const <elem>`. Field names go
  through `emitFieldName` so reserved/`#private` names stay valid Zig.

## Diagnostics

- Mixed field types: "Object.values needs all fields to share one type — mixed
  field types have no single array element type".
- Empty record: "Object.values needs a record with at least one field".
- Non-record argument: "Object.values needs a record type, got `<t>`".

## Verification

- `Object.values({a:1,b:2,c:3})` → `[1,2,3]`.
- `Object.values({x:"hi",y:"bye"}).join("-")` → `hi-bye`.
- `int` fields: `Object.values(s).reduce((x,y)=>x+y,0)` → `170`.
- Mixed `{a:number;b:string}` rejected with the shared-type diagnostic.
- `Object.keys` unchanged; full `zig build` + test suite green.

## Notes

Heterogeneous `Object.values` (and `Object.entries`, which needs tuple
elements) remain out of scope — they require either a union element type or
tuple arrays. The f64-array `reduce`/`+=` with an integer literal seed
(`reduce(...,0)`) is a separate, pre-existing numeric-literal-widening gap,
not introduced here.
