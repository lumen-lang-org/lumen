# Spec 348 — Static field initializers, and empty-ctor stack construction

## Goal

Honor a static field's initializer, and fix stack construction of a class whose
constructor writes no fields.

```ts
class Config {
  static VERSION: i32 = 42;      // was silently 0
  static NAME = "lumen";         // was silently ""
  static get(): i32 { return Config.VERSION; }
}
```

## Motivation

Two bugs surfaced together:

1. **Static initializers dropped.** A static field was always emitted with the
   type's zero value; its declared initializer was ignored (parsed then
   discarded for annotated fields), so `static VERSION = 42` read back `0` — a
   silent wrong value.
2. **Empty-ctor stack construction.** The value constructor `__initv` added in
   spec 344 emitted `var self = undefined; return self;`. For a class whose
   constructor writes no fields (a fieldless or static-only class), `self` is
   never mutated, which Zig rejects ("local variable is never mutated").

## Behavior

- A static field is initialized with its declared expression (a literal in the
  common case); a static field with no initializer keeps the type's zero value.
- `__initv` uses `const self` when the constructor never touches `this` (so an
  empty/fieldless ctor compiles) and `var self` when it writes fields.

## Implementation

- `src/lumen_parser_decl.zig`: a field always retains its initializer (`init`),
  not only when the type annotation is omitted.
- `src/lumen_emit_class.zig`: the static-field storage uses the field's
  initializer when present; `__initv` picks `const`/`var` for `self` based on
  whether the constructor body uses `this`.

## Verification

- `zig build` and `zig build test` green.
- Static `i32`/`string`/inferred initializers read back their real values; a
  static counter mutated across calls works; a static field with no initializer
  zero-inits then accepts writes; stack allocation of a fieldless class and of a
  field-writing class both compile and run.
