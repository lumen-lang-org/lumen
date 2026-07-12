# Spec 306 — Clearer diagnostics for common misuse

## Goal

Replace several bare or misleading diagnostics with specific, actionable
messages so that common beginner mistakes read clearly instead of surfacing an
internal error code or the wrong error entirely.

## Motivation

Four cases produced confusing output:

1. A generic method with its own type parameter (`class C { m<U>() {} }`)
   failed with an opaque parser error rather than explaining the limitation.
2. Using `this` at module scope reported `'return' outside a function`, which
   is simply the wrong message.
3. `new X()` where `X` is not a class (e.g. `new i32()`) reported a bare
   `type mismatch`.
4. `class D extends Base` where `Base` is unknown, and a class extending
   itself, both reported a bare `type mismatch`.

## Behavior

| Source                                | Diagnostic |
|---------------------------------------|------------|
| `class Box { map<U>() {} }`           | generic methods (with their own type parameter) are not supported yet — make the whole class generic (`class C<T>`), or use a generic free function |
| `const x = this;` (module scope)      | 'this' is only valid inside a class method |
| `new i32()`                           | 'new' needs a class, but `i32` is not a class |
| `class Dog extends Animal {}` (no `Animal`) | class `Dog` extends `Animal`, but `Animal` is not a known class |
| `class Node2 extends Node2 {}`        | class `Node2` cannot inherit from itself (inheritance cycle) |

Valid programs are unaffected: an existing class hierarchy with a real base
class still checks and the generic-free-function escape hatch continues to work.

## Implementation

- `src/lumen_parser_decl.zig`: on a method signature followed by `<`, emit the
  generic-method guidance instead of falling through to a generic parse error.
- `src/lumen_check_expr.zig`: `this_expr` outside a class now reports the
  `this`-specific message; `new_expr` on an unknown class name names the
  offending identifier.
- `src/lumen_check_stmt.zig`: `checkClass` names the unknown base class and
  distinguishes the self-inheritance cycle case.

## Verification

- `zig build` and `zig build test` green.
- Probes for each of the five rows above produce the listed message.
- A valid `class Dog extends Animal` program with a real base still checks.
