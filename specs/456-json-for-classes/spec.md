# Feature Specification: JSON For Classes

## Problem

`JSON.stringify` and `JSON.parse<T>` work on records and refuse classes:

```ts
class Agent {
  id: string;
  constructor(id: string) { this.id = id; }
}
let a = new Agent("a1");
JSON.stringify(a);              // error: type mismatch
JSON.parse<Agent>("{...}");     // error: type mismatch
```

`jsonSerializable` (`src/lumen_check_stdlib.zig:849`) admits `.named` — a record
— along with scalars and their arrays, and falls through to `false` for
`.class_type`.

That is a gap on its own: a class is the language's way of pairing data with
behaviour, and a program that keeps its data in classes cannot send any of it
over a wire that every other part of the standard library speaks. `http.request`
takes a JSON body, `JSON.parse<T>` reads a provider's reply, and the std-contrib
`plume` package moves rows in both directions as JSON. A class is excluded from
all of it.

It is also a prerequisite. Spec 455 puts decorators on classes, following
TypeScript, so that `@entity` can generate a mapping from a declared shape. The
mapping it would generate moves data as JSON. Without this, that decorator can
only generate conversions between the class and a shadow record — the
boilerplate the decorator exists to remove.

## Scope

In scope:

- `JSON.stringify(instance)` on a class instance, serialising its fields.
- `JSON.parse<C>(text)` for a class type `C`, producing an instance.
- Inherited fields, since a subclass's data includes its parent's.
- Arrays of class instances, matching `named_array` for records.
- A diagnostic for the shapes that cannot round-trip, naming the field.

Out of scope:

- Methods, accessors and static members. A method is behaviour, not data;
  `JSON.stringify` of a class emits what a record of its fields would emit.
- `#private` fields. They are excluded from the document, as described below.
- Custom hooks — no `toJSON`, no `fromJSON`, no replacer or reviver. Records do
  not have them either, and adding them here would make the class and record
  paths disagree.
- Polymorphism. `JSON.parse<Animal>` produces an `Animal`, never a `Dog`, and
  writes no type discriminator. A document does not carry its class.

## Design

### D1 — which fields

Every declared instance field, in declaration order, parent's before child's.

`#private` fields are excluded. They are name-mangled in the generated code and
unreachable from outside the class by design; putting them in a document that
crosses a process boundary would export exactly what the marker exists to keep
in. A class whose state is entirely private serialises to `{}`, which is
honest — there is nothing public to say about it.

This is a deliberate difference from Java, where Jackson reaches private fields
by reflection. There is no reflection here, and the marker means something
stronger.

### D2 — stringify

`jsonSerializable` admits `.class_type` and `.class_type` arrays. Emission
walks the class's field list exactly as it walks a record's, dereferencing the
instance pointer first — a class is `*Name` in the generated code, a record is
`Name`, and that is the only difference at the point of serialisation.

Inherited fields are emitted before the class's own, so a document's key order
matches the declaration order a reader would expect.

### D3 — parse

`JSON.parse<C>` allocates an instance and fills its fields from the document.
**The constructor is not called.**

That is the significant decision. Calling it is impossible in general: a
constructor takes whatever arguments its author chose, in an order the document
knows nothing about, and may do work — open a file, start a timer — that
reading a value should not. Every mapper in this position makes the same
choice; Jackson allocates without construction unless told otherwise.

The cost is real and belongs in the diagnostic surface: an invariant a
constructor establishes is not established here. A class that must not exist in
an inconsistent state should not be parsed into directly; parse a record and
construct from it.

Missing and unknown fields behave exactly as they do for records — both are
errors — so a class and a record with the same shape parse identically. This
is what makes the two paths one feature rather than two.

### D4 — what cannot round-trip

A field whose own type is not serialisable — a function, a map, a set, a
promise, another class the checker has not admitted — fails at the
`JSON.stringify` or `JSON.parse` call, naming the class, the field and the
reason.

Today's failure for a class is a bare `E_TYPE_MISMATCH` at the call. That is
the wrong end of the problem: the fault is a field several lines away, and the
message does not say which.

## Success Criteria

1. `JSON.stringify` of a class instance produces the same document as a record
   with the same fields and values.
2. `JSON.parse<C>` of that document produces an instance whose fields compare
   equal to the original's.
3. A round trip through both is identity for every scalar type, string, and
   their arrays.
4. A subclass serialises its parent's fields, parent's first.
5. `#private` fields appear in no document, and a class of only private fields
   serialises to `{}`.
6. Methods and accessors appear in no document.
7. A class with an unserialisable field reports the class, the field and why.
8. A missing or unknown field in the document fails, as it does for a record.
9. An array of instances round-trips.
10. `JSON.parse<C>` does not call the constructor — proven by a constructor
    with an observable side effect that does not happen.
11. `zig build test` passes; `zig build conformance` adds no new failures
    against the 193-passed / 50-failed baseline.

## Risks

- **Bypassing the constructor is a real hole**, and the honest kind: it is
  visible in the type system's promises rather than hidden. A class that
  validates in its constructor gains nothing from that validation when parsed
  into. Criterion 10 exists to make the behaviour explicit rather than
  discovered.
- **`#private` exclusion will surprise someone** coming from Java, where the
  same code round-trips. The alternative surprises worse: private state
  crossing a wire because a mapper could reach it.
- **Field order across inheritance** must be stable, or a document's shape
  changes when an unrelated parent gains a field. Parent-first is the rule;
  the tests should pin it.
- **The class path must not fork from the record path.** Two implementations of
  the same format drift, and the drift shows up as a document one side writes
  and the other cannot read. The emission should reuse the record walk with the
  field list and a deref, not copy it.

## Notes

The prerequisite framing understates it. Spec 455 needs this, but the gap
stands alone: a language with classes whose instances cannot be serialised
pushes every program that touches a wire toward records, which makes classes an
ornament rather than a choice.
