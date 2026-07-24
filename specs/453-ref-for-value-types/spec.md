# Feature Specification: Ref For Arrays And Strings

## Problem

`Ref<T>` marks a parameter the callee may write through, giving it a mutable
place in the caller's frame. It accepts scalars, records, interfaces, unions,
enums and tuples, and rejects everything else with `E_REF_TARGET`
(`src/lumen_check.zig:1264`, predicate at `src/lumen_types.zig:586`).

The rejection is justified in the source as follows
(`src/lumen_types.zig:583-585`, and again at `src/lumen_check.zig:1256-1258`):

```zig
/// Whether a type is a legal `Ref<T>` element: a value type the compiler can pass
/// by single pointer. Classes (already references), arrays, and strings (already
/// slices), maps/sets/promises (already heap pointers) are rejected for V1.
```

For maps, sets, promises and classes that reasoning holds: those are heap
pointers, and a callee's mutation is already visible to the caller. For **arrays
and strings it is false**. Both are value types in every way the language
exposes, so a callee cannot communicate a change through them at all, and `Ref`
— the one tool for exactly that — is refused.

Observed, with a build of `main`:

| what | result |
| --- | --- |
| `m.set(k, v)` on a `Map` parameter | visible to the caller |
| `a.push(x)` on an array parameter | not visible |
| `a[i] = x` | rejected: arrays and records are immutable |
| `a.sort()` / `a.reverse()` | return new arrays; the receiver is unchanged |
| `Ref<int[]>` | rejected: `E_REF_TARGET` |
| `Ref<string>` | rejected: `E_REF_TARGET` |

The array rows are consistent with each other: an array is an immutable value,
`push` rebinds the local parameter, and rebinding a parameter is invisible to the
caller for every type — a scalar behaves the same way. That is a coherent model
and this spec does not propose changing it. What is missing is the opt-in, which
scalars have and arrays do not.

### Why it matters

Accumulating into a caller-owned array is an ordinary shape, and today it has no
spelling. Writing the obvious thing compiles and silently does nothing:

```ts
function fill(out: int[]): void {
  out.push(1);
  out.push(2);
}
let a: int[] = [];
fill(a);          // a.length is 0
```

There is no diagnostic, because nothing is wrong with any single line — the
parameter really is rebound, in the callee's frame. The author's mental model is
what is wrong, and the compiler has no way to say so. This cost real time while
building the std-contrib `ai` package's text splitter, whose recursive descent
was written to fill a shared buffer and returned nothing at all; the workaround
was to return an array from every step and concatenate at each level, which
allocates once per node of the recursion.

The same gap applies to strings. A function that reports text back to its caller
must return it, so a function that already returns a status has nowhere to put
it, and callers end up with a record whose only purpose is to carry two values.

## Reproductions

### R1 — accumulate into a caller's array

```ts
function fill(out: Ref<int[]>): void {
  out = [...out, 1];
  out = [...out, 2];
}
let a: int[] = [];
fill(a);
console.log(a.length);
```

Today: `error: invalid Ref<T> target type [E_REF_TARGET]`.
Wanted: compiles, prints `2`.

### R2 — a string out-parameter

```ts
function readInto(path: string, text: Ref<string>): bool {
  if (!fs.existsSync(path)) { return false; }
  text = fs.readFileSync(path);
  return true;
}
let body: string = "";
if (readInto("notes.txt", body)) { console.log(body.length); }
```

Today: `error: invalid Ref<T> target type [E_REF_TARGET]`.
Wanted: compiles, and `body` holds the file's contents.

## Scope

In scope:

- `Ref<T>` accepts `T` = an array of any element type, and `T` = `string`.
- Reading such a parameter in the body sees the caller's current value.
- Assigning to it — including `a = [...a, x]` and `a.push(x)`, which is the same
  rebinding — is visible to the caller after the call returns.
- The `E_REF_TARGET` diagnostic and the doc comments that justify it stop
  claiming arrays and strings are reference-like.

Out of scope:

- Changing array value semantics. Arrays stay immutable values; `a[i] = x` stays
  rejected; `sort` and `reverse` keep returning new arrays. This spec adds an
  opt-in, it does not make arrays aliasable. Sharing a mutable array by default
  is what makes Go's `append` behave differently depending on spare capacity,
  and the current model rules that out by construction.
- `Ref<T>` for maps, sets, promises and classes. Their pointee is already
  shared, so only whole-value rebinding is missing, which is a smaller need and
  can follow once this lands.
- Rebinding a `Ref<record>` as a whole (`p = fresh`), which fails today with
  "cannot assign to constant". Field writes work and are the documented use; the
  gap is real but separate.
- A rest parameter `Ref<T>[]`, still rejected.

## Design

### D1 — widen the accepted target types

`types.isRefAllowed` (`src/lumen_types.zig:586`) gains the array and string
cases. Nothing else about `resolveParam` (`src/lumen_check.zig:1259`) changes:
the parameter still type-checks as its inner type and is still passed as a
single pointer, which is what `refZigName` already emits (`*[]const u8` for a
string, `*[]T` for an array).

### D2 — arrays and strings deref like scalars, not like records

`types.isRefScalar` (`src/lumen_types.zig:595`) decides whether the body needs an
explicit `.*` on reads and assignments. A record does not, because field access
auto-derefs through a pointer; a scalar does, because a bare read or assignment
would otherwise operate on the pointer.

An array or a string is the scalar case: the body assigns the whole value
(`a = [...a, x]`), and its methods take the value, not a pointer to it. So both
join `isRefScalar`, and the existing scalar deref path carries them without new
emission logic.

The one place to check is the length property: `a.length` on a `*[]T` needs to
reach the slice's own length, and the emitter must not read it off the pointer.

### D3 — correct the rationale

The comments at `src/lumen_types.zig:583-585` and `src/lumen_check.zig:1256-1258`
both assert that arrays and strings are "already reference-like" or "already
slices". A slice is a value; copying it copies the header. The comments should
say what is actually true — maps, sets, promises and classes are heap pointers
whose contents a callee can already change, so `Ref` adds only rebinding for
them — and stop grouping arrays and strings with that set.

## Success Criteria

1. R1 compiles and prints `2`.
2. R2 compiles and prints the file's length.
3. `a.push(x)` through a `Ref<int[]>` parameter is visible to the caller, since
   it is the same rebinding as an explicit assignment.
4. Reading `a.length` and indexing `a[i]` inside the callee see the caller's
   current value.
5. An array of records, and an array of arrays, both work as `Ref` targets.
6. Passing a `Ref<T[]>` parameter on to another `Ref<T[]>` parameter works.
7. A plain (non-`Ref`) array parameter is unchanged: `push` stays local, and no
   existing program changes behaviour.
8. `a[i] = x` remains rejected, with or without `Ref`.
9. `Ref<T>[]` as a rest parameter remains rejected.
10. `zig build test` passes; `zig build conformance` adds no new failures against
    the 186-passed / 50-failed baseline.

## Risks

- **`isRefScalar` is a behaviour switch, not a list.** Adding a type to it
  changes how every body referencing such a parameter is emitted. The existing
  scalar tests are the guide, and an array-of-records case should be added
  because field access through two levels is where a missing deref would show.
- **`.length` through a pointer.** A slice's length lives in the slice, not
  behind another indirection. If the emitter reads `param.len` where it needs
  `param.*.len`, the result is a plausible-looking wrong number rather than a
  compile error, so this needs a direct test rather than inspection.
- **Strings are `[]const u8`.** Assigning through a `*[]const u8` is fine, but
  the const-ness is on the bytes, not the slice header. A confusion here
  surfaces as a Zig-level error at build time, which is loud, not silent.
- **The silent-`push` trap stays.** This spec gives `Ref` as the fix but does not
  make the wrong version an error. A caller who forgets `Ref` still writes a
  `push` whose effect vanishes. Whether the compiler should reject or warn on a
  mutating method call against a non-`Ref` parameter is worth its own decision —
  it would be the first diagnostic in the language aimed at a mental model
  rather than a type error — and is deliberately not settled here.

## Notes

The narrow reading of this change is that two entries move in a switch. The
broader one is that `Ref<T>` becomes a single idea — a mutable place in the
caller's frame — instead of a facility gated on a claim about representation
that does not hold for the two types that most need it.

It also matches how the two languages with this exact model resolved it. Swift
pairs value semantics with `inout` and applies it to arrays and strings without
exception. Go shares a slice's backing store instead, which is why appending in
a callee sometimes reaches the caller and sometimes does not, depending on
capacity — the outcome this language already avoids and should keep avoiding.
