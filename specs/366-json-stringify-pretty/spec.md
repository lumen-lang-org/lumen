# 366 — `JSON.stringify(value, null, indent)` pretty-printing

## Problem

Only the one-argument `JSON.stringify(value)` was accepted. The common
pretty-print form failed with `E_ARG_COUNT`:

```ts
JSON.stringify(obj, null, 2)
```

## Change

- **Checker** (`lumen_check_stdlib.zig`, `jsonCallType`): `stringify` accepts one
  or three arguments. In the three-arg form the replacer (2nd) must be `null`
  (replacers aren't supported — clear diagnostic otherwise) and the indent (3rd)
  must be an integer.
- **Runtime** (`lumen_runtime_net.zig`): `__jsonStringifyPretty(alloc, value,
  indent)` maps the runtime indent count to std.json's comptime `whitespace`
  option (`indent_1..4`, `indent_8` for larger, minified for 0).
- **Emitter** (`lumen_emit_static.zig`): the three-arg form emits
  `__jsonStringifyPretty(__alloc, <value>, <indent>)`.

## Verified

`zig build` + `zig build test` green. Bit-identical to Node 22:

- `JSON.stringify({x:1,y:2}, null, 2)` — two-space indented object.
- `JSON.stringify(p, null, 4)` — four-space indent.
- Nested record indents recursively.
- One-arg `JSON.stringify(p)` still minified.
- `JSON.stringify(p, (k,v)=>v, 2)` (a replacer function) is rejected with a
  clear message.

## Boundary

Replacer functions/arrays are not supported (must pass `null`). Indent widths
above 4 clamp to 8 spaces (std.json's largest fixed option); string indents
(`"\t"`) are not accepted — the third argument is an integer count.
