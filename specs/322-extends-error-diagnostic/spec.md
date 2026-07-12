# Spec 322 — Clear diagnostic for `class ... extends Error`

## Goal

Give a specific, actionable message when a program tries to subclass `Error`,
instead of the generic "Error is not a known class".

## Motivation

`class MyError extends Error {}` is a common TypeScript pattern, but Lumen models
`Error` as a built-in value type, not an extensible class. The spec 306 message
("… `Error` is not a known class") was technically true but misleading, since
`Error` clearly exists as a concept.

## Behavior

Subclassing `Error` reports:

> custom error subclasses (`class ... extends Error`) are not supported yet —
> throw `new Error("message")` with a distinguishing message, or return a
> discriminated result type (`type Result = Ok | Err`)

Subclassing any other unknown base still reports the spec 306 message.

## Implementation

- `src/lumen_check_stmt.zig`: `checkClass` special-cases a parent named `Error`
  before the generic unknown-base diagnostic.

## Verification

- `zig build` and `zig build test` green.
- `class MyErr extends Error` produces the guidance; `class Dog extends Animal`
  (unknown base) still reports the generic message.
