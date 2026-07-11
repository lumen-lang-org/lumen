# Spec 198: implicit `void` return type on functions

## Goal

Allow a function declaration to omit its return type, defaulting to `void`:

```ts
function greet(name: string) {
  console.log("hi " + name);
}
greet("A");
```

Previously a `function` without a `: ReturnType` was a syntax error — every
side-effecting function had to be written `: void` explicitly. (Class methods
already defaulted to `void`; this brings free functions in line.)

## Why additive, not breaking

Only makes previously-rejected programs compile. A function with an explicit
return type is unchanged, as are arrow functions (which already inferred).

## Semantics

A function declaration with no return type annotation is treated as returning
`void`. A value-returning function still needs an explicit `: T` annotation (the
return type is not inferred from the body in V1); returning a value from an
implicitly-void function is a type error, as before.

## Requirements

- **FR-001**: `function f(...) { ... }` with no return type is `void`.
- **FR-002**: An explicit return type and value-returning functions are
  unchanged.
- **FR-003**: Works with parameters, generics, and early `return;`.

## Success Criteria

- **SC-001**: `function greet(name: string) { console.log(...) }` compiles.
- **SC-002**: `function f(): void { ... }` and `function add(a,b): i32 { return
  a+b; }` still work.
- **SC-003**: `function p(n: i32) { if (n<0) return; console.log(n); }` and a
  generic `function log<T>(x: T) { ... }` compile.
- **SC-004**: `zig build` and `zig build test` stay green.
