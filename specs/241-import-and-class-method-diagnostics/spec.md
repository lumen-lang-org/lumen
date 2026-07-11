# Spec 241: import failures and class-method typos explain themselves

## Goal

```text
main.ts:1:1: error: 'nope' is not exported by util.ts (exports: yep) [E_MISSING_EXPORT]
main.ts:1:1: error: cannot find module 'missing.ts' [E_IMPORT_NOT_FOUND]
main.ts:1:1: error: import cycle through 'a.ts' [E_IMPORT_CYCLE]
main.ts:7:1: error: `Dog` has no method 'brk' — did you mean 'bark'?
main.ts:7:1: error: 'Dog.bark' expects 0 arguments, got 1
```

Previously import-expansion failures printed the raw error code with no
detail (`error: E_MISSING_EXPORT`), and a misspelled class method or a class
method called with the wrong arity was a bare "type mismatch" / "wrong number
of arguments".

## Semantics

- Import expansion records what failed: the unresolved module path (after
  extensionless resolution), the missing export name plus the module's actual
  export list ("nothing is exported" when empty), the cycle participant, or
  the duplicated specifier. compileFile renders the detail with the code in
  brackets; paths are display-normalized (no `././`). A missing entry file
  still reports "cannot read file".
- An unknown method on a class value gets a did-you-mean over the class's
  (and ancestors') instance methods, like stdlib methods (spec 224).
- A class method called with the wrong argument count reports
  `'Class.method' expects N argument(s), got M`.

## Success Criteria

- **SC-001**: Missing export, missing module, and import cycle each name the
  module/name involved.
- **SC-002**: `d.brk()` on a class with `bark` suggests it; wrong arity on a
  class method reports both counts.
- **SC-003**: Valid imports and method calls unchanged; `zig build` and
  `zig build test` stay green.
