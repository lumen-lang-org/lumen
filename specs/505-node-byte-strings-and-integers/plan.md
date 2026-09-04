# Plan: 505 byte strings and integers

## Where the type information is

- Binary ops carry `checked_operand_type` (`lumen_emit.zig:718`); the
  checker sets it in `exprType` (`lumen_check_expr.zig:96`).
- Division lowering for Zig picks `@divTrunc` by operand type (spec 137);
  mirror that decision point in `lumen_emit_js_expr.zig`.
- String literal bytes: `emitStrLit` (`lumen_emit.zig:108`) already walks
  the literal's bytes; the JS version emits `\xNN` for every byte ≥ 0x80
  and for control bytes.
- String methods: `emitStringMethod` (`lumen_emit_array_string.zig:455`)
  is the list of methods and their Zig lowering; each gets a JS arm — most
  are identity on binary strings.
- Numeric formatting: `printFormat` (`lumen_emit_analysis.zig:437`) and
  `wrapStringify` (`lumen_check_expr.zig:41`) define how values print; the
  runtime's `__lang.fmt(value, type)` must match for `f64`.

## Approach

1. Literals and `fromCodePoint`/`codePointAt`; corpus program `bytes.ts`.
2. Boundary conversions in the runtime package (503 FR-002): audit every
   `lib/*.mjs` function for text in/out; remove the `LUMEN_STRINGS` switch.
3. Integer division/modulo/compound; `W_I64_PRECISION`.
4. `JSON` and `Buffer` interplay in `lib/lang.mjs`.
5. Float formatting parity: run the numeric corpus (136, 181, 107, 110, 364,
   433), fix `__lang.fmt` until identical.
6. Run Joule's `text.test.ts`, `markdown.test.ts`, `websocket/frame.test.ts`
   under 506; fix what they find.

## Risks

- Hidden UTF-16 assumptions inside Node APIs the runtime calls with binary
  strings (`path.join` is byte-safe; `URL` is not — `url.parse` must decode
  first). Audit list in tasks.
- Float formatting is a long tail; the corpus is the boundary of what is
  promised.
