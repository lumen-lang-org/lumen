# Feature Specification: A Declaration Beats an Undocumented Builtin

## Problem

A program declaring a function named `serve` compiles, and every call to it is
silently typed `void`:

```ts
export function serve(port: int, table: Route[], handlers: Map<string, Handler>): string {
  ...
  return "";
}

let problem = serve(8080, table, bound);
```

```
zz_srv.ts:8:7: error: a void expression cannot be used as a value [E_VOID_VALUE]
```

The error points at the call site and says nothing true about the cause. There
is no diagnostic naming `serve`, nothing saying the name is taken, and the
declaration itself compiles without complaint.

`serve` and `httpGet` are hardcoded as builtin call names in three places —
`isBuiltin` in `src/lumen_parser.zig`, the checker in
`src/lumen_check_expr.zig`, and the emitter in `src/lumen_emit.zig`. Neither
appears in `lumen.d.ts`; both are leftovers from the earlier runtime, and
`http.createServer` is the documented way to serve. So two ordinary words are
reserved, undocumented, and fail silently.

`serve` is not an exotic name. It is the first thing a web framework calls its
entry point.

## Scope

In scope:

- A program that declares `serve` or `httpGet` itself gets its own function.
- No change for a program that does not: the builtins keep working, so nothing
  that relies on them breaks.

Out of scope:

- Removing the builtins. They are undocumented and probably unused, but
  deleting them is a separate decision from stopping them from squatting.
- The other direction — a user name colliding with a *prelude* function's
  parameter — which is spec 457.

## Design

Each of the three sites checks whether the program declares the name before
treating a call as the builtin. The checker has `funcs` and `generic_funcs`;
the emitter has `g_program`. A user declaration wins.

Silence is the specific fault being fixed. A clash that reported itself would
be an annoyance; one that retypes a call to `void` and blames the call site is
an afternoon.

## Success Criteria

1. A program declaring `function serve(...): string` and calling it compiles,
   and the call has type `string`.
2. A program that does not declare `serve` still reaches the builtin.
3. The same for `httpGet`.
4. `zig build test` passes; `zig build conformance` adds no new failures.

## Notes

Found building the std-contrib `rest` package, whose `serve` is exactly the
name in the reproduction. It took renaming the function to discover the cause,
because nothing in the message pointed at it.
