# Tasks: JSON For Classes

## Investigation

- [ ] Confirm every caller of `jsonSerializable`
      (`src/lumen_check_stdlib.zig:849`) and what each does with a `false`.
- [ ] Trace how a record is emitted for `JSON.stringify`: where the field walk
      lives, and what it needs to serve a `*Name` instead of a `Name`.
- [ ] Trace how `JSON.parse<T>` builds a record — allocation, field
      assignment, and the missing/unknown-field checks — and what changes for a
      heap instance.
- [ ] Determine how a class's inherited fields are ordered today
      (`ClassDecl.parent`, `src/lumen_ast.zig:131`) and whether a flattened
      list already exists in the checker.
- [ ] Confirm how `#private` fields are represented after parsing, so they can
      be excluded by a property rather than by a name prefix.

## D1 — which fields

- [ ] A flattened field list for a class: parent's fields first, then its own.
- [ ] `#private` fields excluded from that list.
- [ ] Methods, accessors and static members excluded.
- [ ] A class with no public fields yields an empty list, not an error.

## D2 — stringify

- [ ] `jsonSerializable` admits `.class_type`.
- [ ] `jsonSerializable` admits an array of class instances.
- [ ] Emission reuses the record field walk, dereferencing the instance —
      not a second implementation of the format.
- [ ] The pretty form (`stringify(v, null, 2)`) works for a class.

## D3 — parse

- [ ] `JSON.parse<C>` accepts a class type argument.
- [ ] It allocates an instance and fills fields without calling the
      constructor.
- [ ] Missing and unknown fields fail as they do for a record.
- [ ] An array of instances parses.

## D4 — diagnostics

- [ ] A class field whose type is not serialisable reports the class, the
      field and the reason, at the call.
- [ ] The same for a field inherited from a parent, naming the declaring
      class.

## Tests

- [ ] A class and a record with the same shape stringify identically.
- [ ] Round trip is identity for string, int, i64, number, bool and their
      arrays.
- [ ] A subclass emits its parent's fields first.
- [ ] A `#private` field appears in no document.
- [ ] A class of only private fields stringifies to `{}`.
- [ ] A method and an accessor appear in no document.
- [ ] A field typed as a Map reports the class and the field.
- [ ] A missing field in the document fails.
- [ ] An unknown field in the document fails.
- [ ] An array of instances round-trips.
- [ ] The constructor does not run on parse — a constructor writing a file
      leaves no file.
- [ ] A generic class specialisation round-trips, or is refused with a
      message saying so.

## Gates

- [ ] `zig build` and `zig build test` pass.
- [ ] One clean `zig build conformance` run: no new failures against the
      193 passed / 50 failed baseline.
- [ ] Records are unaffected: every existing JSON example and the std-contrib
      `ai` and `plume` suites behave unchanged.
- [ ] New examples land as conformance cases with a manifest wired into
      `build.zig`.

## Follow-up (not this slice)

- [ ] Spec 455 depends on this: `@entity` on a class can generate a `plume`
      mapping only once a class instance can cross the JSON bridge.
- [ ] Decide whether a class should be able to opt into construction on parse
      — a named static factory the parser calls — or whether parsing a record
      and constructing from it stays the answer.
- [ ] Polymorphic parsing, if a document ever needs to carry its class.
