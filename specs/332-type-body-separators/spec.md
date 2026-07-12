# Spec 332 — Semicolon and newline separators in `type` bodies

## Goal

Accept `;`, `,`, and newline separators between members of a `type` record body,
matching `interface`:

```ts
type Point = { x: i32; y: i32 };     // semicolons (the common TS style)
type Size  = { w: i32, h: i32 };     // commas
type Rect  = {                       // newlines
  x: i32
  y: i32
};
```

## Motivation

`type` record bodies only accepted commas, so the idiomatic semicolon style —
the most common in TypeScript — failed with `expected '}', found ';'`, and
newline-only separation failed too. `interface` bodies already accepted all
three, so the two diverged.

## Behavior

A `type` record member may be followed by `;`, `,`, or nothing (a newline), the
same as an `interface` body. Optional members and method-signature members work
with every separator, and mixed separators in one body are accepted.

## Implementation

- `src/lumen_parser_decl.zig`: the `type` record-body field loop consumes an
  optional `,`/`;` after each member (instead of requiring `,` and breaking
  otherwise), mirroring the interface parser.

## Verification

- `zig build` and `zig build test` green.
- Semicolon-, comma-, newline-, and mixed-separated `type` bodies parse and run;
  optional members with semicolons work.
