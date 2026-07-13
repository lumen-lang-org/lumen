# 428 — interface polymorphism (dynamic dispatch)

## Problem

An interface-typed value couldn't hold different class implementations, and a
class instance couldn't be passed where its interface was expected — the single
biggest missing OOP capability:

```ts
interface Shape { area(): number; }
class Sq implements Shape { constructor(public s: number){} area(): number { return this.s*this.s; } }
class Circle implements Shape { constructor(public r: number){} area(): number { return 3*this.r*this.r; } }
function total(shapes: Shape[]): number { return shapes.reduce((t, s) => t + s.area(), 0); }
total([new Sq(2), new Circle(3)]); // error: expected `Shape`, got `Sq`
```

Interfaces were structural records; there was no runtime dispatch.

## Approach — fat pointers + per-class vtables

A method-bearing interface lowers to a fat pointer and a vtable:

```zig
const VT_Shape = struct { area: *const fn (*anyopaque) f64 };
const LumenIface_Shape = struct { __ptr: *anyopaque, __vt: *const VT_Shape };
```

Each class implementing the interface gets a static vtable whose entries are
wrappers that cast the erased pointer back and call the real method:

```zig
const __vt_Sq_Shape: VT_Shape = .{
    .area = &struct { fn __w(__p: *anyopaque) f64 {
        return @as(*Sq, @ptrCast(@alignCast(__p))).area();
    } }.__w,
};
```

- **New Type variant** `iface_type` (`lumen_types.zig`); `zigName` → `LumenIface_<Name>`.
- **Detection**: `interface` decls carry `is_interface` (parser); an interface
  with ≥1 method member resolves to `iface_type` (checker `typeFromAnnotation`);
  each method member's signature is resolved to a `func_type` in a checker pass.
- **Coercion** (`ensureAssignable`): a `class_type` implementing the interface
  (`classImplements`) is wrapped in an `iface_class` cast → the fat-pointer
  literal `LumenIface_Shape{ .__ptr = @ptrCast(inst), .__vt = &__vt_<Class>_Shape }`.
- **Dispatch**: a method call on an `iface_type` receiver checks against the
  interface's members and emits `rcv.__vt.<m>(rcv.__ptr, args…)`.
- **Emit**: interface struct + vtable type (`emitIfaceDecl`), per-class vtables
  after each class struct (`emitClassVtables`).

## Verification

- Mixed `[new Sq(2), new Circle(3)]` polymorphic array → dynamic dispatch (`31`).
- Interface param, var, return type, record field, and array `.map`/`.reduce`.
- Reassigning an interface var to a different implementer dispatches correctly
  (`meow` → `woof`).
- Methods with arguments, string/bool/number returns, multiple methods.
- `interface B extends A` — inherited members dispatch.
- Data-only interfaces still lower to structural records (backward compatible).
- Non-implementers and non-class values are rejected with a type error.
- A comprehensive 3-implementation program (`Rectangle`/`Circle`/`Triangle`) runs
  end-to-end; a class remains usable directly (non-polymorphically).
- Full `zig build` + test suite green.

## Known limitations

- Only method members dispatch; data members on a polymorphic interface are out
  of scope (a data-only interface stays a structural record).
- A throwing interface method (its vtable signature would need the error union)
  is not yet supported.
- A method named after a Zig keyword (`test`) is a separate pre-existing
  method-naming bug, unrelated to dispatch.
