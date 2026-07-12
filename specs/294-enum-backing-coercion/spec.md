# Spec 294: enum members coerce to their backing type

## Goal

```ts
enum Color { Red = 1, Green = 2, Blue = 4 }
const c: i32 = Color.Green;        // numeric enum -> i32
console.log(c + Color.Blue);       // 6 (arithmetic)

enum Dir { N = "north", S = "south" }
const d: string = Dir.N;           // string enum -> string
console.log("going " + Dir.S);     // going south (concat)
```

Previously assigning or combining an enum member with its backing type was
a "type mismatch" / "operator cannot combine" error.

## Semantics

An enum member acts as its backing type — a numeric enum as `i32`, a string
enum as `string` — in assignment (`ensureAssignable`) and in binary
arithmetic/concatenation. The member already lowers to exactly that value at
emit (numeric enums emit their int, string enums their string), so no code
generation change is needed. An enum-typed value still checks distinctly
where a specific enum type is required (switch, function parameter of that
enum type).

## Success Criteria

- **SC-001**: A numeric enum member assigns to `i32` and participates in
  `+`; a string enum member assigns to `string` and concatenates.
- **SC-002**: Passing an enum member where its own enum type is expected
  still works; `zig build` and `zig build test` stay green.
