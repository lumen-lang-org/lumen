# Spec 489: a method may share a name with a module-level function

## Goal

```ts
import { run } from "./run.ts";

export class ToolsRegistry {
  dispatch(tool: string): int {
    return run();      // the imported function; the method would be this.run()
  }
  run(): int { return 0; }
}
```

Today the call fails:

```text
error: ambiguous reference
    return run();
note: the native backend rejected this statement's generated code
```

The call site has only one reading. A bare `run()` is the module-level
function; the method would be written `this.run()`. Renaming the import does
not help either, because the ambiguity is in the generated code and not in the
import.

## Why it happened

A class lowers to a Zig struct, and its methods become declarations inside that
struct. The generated container therefore holds a declaration named `run` while
the file that encloses it holds another, and a bare `run` inside the container
names both. The backend refuses to guess, correctly, and the message surfaces
as a compiler bug because the user never wrote that container.

The language has two scopes here (a class member namespace and a module
namespace) and lowers them into one nesting where an inner declaration hides an
outer one. Nothing in the emitter said which scope a bare name meant.

## Semantics

A module-level name referenced from inside a class body that declares a method
of the same name is emitted through the module's own namespace, so the
reference names the module and nothing else. `this.run()` still selects the
method, exactly as written.

The alias is a single generated declaration, `const __lumen_mod = @This();`,
emitted only for a program that actually contains such a pair. Programs without
one emit the code they emitted before, byte for byte.

The rule covers every place a module-level name reaches the backend from inside
a class: a direct call, a function used as a value, a body nested in an arrow,
and a method inherited from an ancestor (the ancestor's methods are emitted
into the derived struct too). Members that cannot collide are left alone:
fields are struct fields and hold no declaration, accessors emit as
`__get_`/`__set_`, statics as `__static_`.

A name the program does not declare at module level is never routed through the
alias, so a builtin lowered to a generated helper is unaffected by a method
that happens to share its name.

## Success Criteria

- **SC-001**: A class with a `run` method whose other method calls an imported
  `run()` compiles, and each call reaches the declaration it names.
- **SC-002**: The same holds when the import is aliased, when the function is
  declared in the same file, and when the colliding method is inherited.
- **SC-003**: The free function may also be used as a value inside the class,
  and called from an arrow nested in a method body.
- **SC-004**: A method may share its name with a module-level binding or class,
  not only a function.
- **SC-005**: A file that both imports `run` and declares `run` itself is still
  rejected with `E_DUPLICATE_BINDING` (spec 476) -- that ambiguity is real.

## Implementation

`src/lumen_emit.zig` -- `moduleScopedName` decides the spelling; `g_cur_class`
carries the class whose body is being emitted; `needsModuleSelf` gates the
alias. `src/lumen_emit_class.zig` sets and clears `g_cur_class` around the
struct body, so the vtables emitted after it are top-level again.
