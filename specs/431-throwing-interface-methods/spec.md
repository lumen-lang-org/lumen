# Spec 431 — Throwing interface methods

## Problem

Interface polymorphism (spec 428) lowered an interface value to a fat pointer
`LumenIface_<Name>{ __ptr, __vt }` and dispatched method calls through a
per-class vtable. The vtable slot and its class wrapper were both typed with the
method's plain return type `R`. When any implementation of the method could
`throw`, the class method actually returned `error{LumenThrow}!R`, so the wrapper
failed to compile:

```
error: expected type 'f64', found 'error{LumenThrow}!f64'
```

The dispatch site also emitted a bare vtable call, so a throw could not route to
the enclosing `try`/`catch`.

## Change

- The throwing analysis is name-based (`analysis.methodThrows(name)`), so every
  like-named method shares the throwing signature. The vtable slot and each
  class wrapper now use `error{LumenThrow}!R` whenever any same-named method
  throws (`vtRetType` in `lumen_emit_class.zig`). A non-throwing implementation
  coerces its plain `R` into the error union automatically.
- The interface dispatch site (`lumen_emit.zig`, `.method_call` with
  `iface_name`) wraps the vtable call in `emitThrowingCallPrefix` /
  `emitThrowingCallSuffix` when the method throws, mirroring the direct
  class-method path — so the throw routes to the enclosing `try`'s catch slot,
  a `try`-forward, or a panic.
- `analysis.exprCanThrow` now recognizes an interface method call
  (`iface_name != null`) as throwing, so a `try` body containing one is emitted
  with its labeled block; without this the suffix broke to a `__lumen_try_*`
  label that was never defined.

## Verification

- `zig build` and `zig build test` clean.
- Throwing interface method caught locally:

  ```ts
  interface Validator { validate(n: number): number; }
  class Pos implements Validator {
    validate(n: number): number {
      if (n < 0) throw new Error("negative");
      return n;
    }
  }
  function check(v: Validator): number {
    try { return v.validate(-1); } catch (e) { return -99; }
  }
  console.log(check(new Pos())); // -99
  ```

- `void` throwing interface method caught locally → `-1`; a non-throwing
  interface (`Shape.area`) still returns its value → regression clean.
- Throw propagating out of a caller function through an interface call, caught
  at a higher `try` → `-42`; the same call with a valid argument → `5`.
