# Spec 505: byte strings and integer arithmetic on the Node target

**Status**: Draft | **Parent**: 501, slice 3 (semantics) | **Depends on**: 504

## Problem

Two places where a Lumen program and the same text read as JavaScript
compute different values:

1. **Strings are bytes.** `"é".length` is 2 (specs 144, 472); `s[i]`,
   `charAt`, `charCodeAt`, `fromCharCode`, `slice`, `indexOf`, `padEnd` are
   all byte-indexed. JavaScript's are UTF-16 code units. Programs depend on
   it: Joule counts terminal columns by decoding UTF-8 from `charCodeAt`
   and frames WebSocket bytes with `fromCharCode`.
2. **Integers.** `int`/`i32`/`i64` division truncates (`7 / 2` is `3`,
   spec 137) and `%` follows; `number` division does not. `i32` widens to
   `i64` losslessly (258); `i64` covers 2^63 where JavaScript's `number`
   stops being exact at 2^53.

The emitter knows every operand's static type, so both are type-directed
lowerings, not runtime guesses.

## Decision 1: a Lumen string is a JavaScript string of bytes

A `string` value is represented as a JavaScript string whose code units are
all in 0..255, one per byte of the Lumen string (a "binary string", Node's
`latin1`). Consequences:

- `length`, `[i]`, `charAt`, `charCodeAt`, `slice`, `indexOf`, `includes`,
  `startsWith`, `split`, `+`, `==`, `<`, `Map` keys, template literals: the
  JavaScript operation *is* the Lumen operation. No helper calls in the hot
  path.
- String literals are emitted as their UTF-8 bytes escaped:
  `"é"` becomes `"\xC3\xA9"`.
- `String.fromCharCode(b)` is identity (byte semantics, 119).
  `String.fromCodePoint(cp)` becomes `__lang.fromCodePoint(cp)`, which
  UTF-8-encodes (472). `codePointAt` decodes UTF-8 at a byte index.
- `toUpperCase`/`toLowerCase`/`localeCompare`: the runtime applies the
  native rule on the bytes (case is ASCII-only, 063; compare is byte order,
  109; match that exactly, do not "improve" it). `trim` strips the four
  ASCII whitespace bytes the native one strips, `repeat` of a negative count
  is empty, and string-pattern `replace` takes its replacement literally;
  JavaScript's own methods differ on each and are not used. `normalize` is
  not in the language.
- **Boundaries** convert once: `console.log` and every runtime function
  that hands text to Node (`fs.writeFileSync`, `spawnSync` args,
  `http` bodies, `process.stdout().write`) does
  `Buffer.from(s, "latin1")`; every function that receives text from Node
  (`readFileSync`, `readdirSync`, `process.env`, `argv`, `spawnSync`
  output) does `buf.toString("latin1")`. The runtime package (503) owns
  this; FR-002 there is this decision.
- `JSON.stringify`/`JSON.parse` operate on the byte string: decode to text
  for `JSON.parse` input? No — JSON text is itself bytes; the runtime parses
  the latin1 string as if it were the UTF-8 bytes: `JSON.parse(Buffer.from(s,
  "latin1").toString("utf8"))` then re-encodes every string field with
  `__lang.bytes`. `stringify` is the inverse. Both are in `lib/lang.mjs`.
- `Buffer` (056) keeps a real `Uint8Array`; `Buffer.from(s)` copies the
  byte string's code units; `toString("utf8")` returns the byte string
  unchanged (it is already the bytes), matching 056's "raw passthrough".

Memory is 2 bytes per byte of text. Accepted: exactness beats footprint for
this target, and the alternative (`Uint8Array` everywhere) puts a helper
call on every string expression.

## Decision 2: integer ops are emitted by static type

| Expression (static types) | Emitted |
| --- | --- |
| `a / b`, both integer | `__lang.divInt(a, b)` = `Math.trunc(a / b)`; division by zero throws `RangeError` like Zig's safe mode panic (documented divergence: native panics) |
| `a % b`, both integer | `a % b` (JavaScript's `%` already truncates toward zero) |
| `a /= b` on an integer target | as above (137) |
| `+ - *` on `i32` | plain; overflow wraps neither here nor natively in a way a program may rely on (native panics in ReleaseSafe) — emit plain and document |
| `a /= b` on an integer field | `obj.f = __lang.divInt(obj.f, b)`; the checker records the field's type on the assignment (`MemberAssign.checked_type`) |
| `i64` values | `number`; the emitter warns `W_I64_PRECISION` once per program when an `i64` literal or `bigint` literal exceeds 2^53 (417) |
| `bigint`, `Nn` literals | `number` (417 maps them to `i64`) |
| bitwise `& \| ^ << >> >>> ~` | identity (both are 32-bit) |
| `Math.imul`, `clz32`, `fround` | identity |
| `parseInt`/`parseFloat`/`Number()`/`toFixed` | identity on the decoded text: `__lang.text(s)` first, since they take Lumen strings |
| numeric to string (`${n}`, `+ ""`, `toString`) | JavaScript's formatting matches Lumen's for integers; for floats Lumen prints via Zig's `{d}` — pin the corpus and fix the runtime's `__lang.fmt` where they differ (136, 181). `fmt` writes every digit where JavaScript would print `1e+21` or `1e-7`, and `nan`/`inf`/`-inf`; the emitter applies it to a `number` at `String(x)`, `${x}` and `x.toString()`, the console to a top-level `number` argument. `Math.PI` and the other namespace constants are read through their call so the value is a number. Documented divergence: `toFixed` where the native rounding differs from JavaScript's (`(1.005).toFixed(2)` is `1.01` natively, `1.00` on Node) |

## Requirements

- **FR-001**: every string method the checker accepts
  (`lumen_check_methods.zig:1137 stringMethod`) has a Node lowering that
  returns the byte result the native runtime returns; pinned by a corpus
  program per method family.
- **FR-002**: `"é".length` prints `2`; Joule's `visualWidth("héllo")`
  prints `5` under Node.
- **FR-003**: `7 / 2` on ints prints `3`; on numbers prints `3.5`;
  `i64` arithmetic within 2^53 is exact.
- **FR-004**: boundary conversions are complete: a program that reads a
  UTF-8 file, uppercases ASCII, and writes it back produces identical bytes
  natively and under Node (`examples/valid/roundtrip.ts`).
- **FR-005**: `JSON.parse<T>`/`stringify` round-trip non-ASCII text
  identically on both targets.

## Success criteria

- **SC-001**: the whole eligible corpus (504 `corpus.txt`) still passes
  `node-run`; the 505 manifest passes on both targets.
- **SC-002**: Joule's `terminal/text.test.ts` passes under Node.
  (Measured with `lumen test --target node` (506) against joule-sh/code at
  59e7acb: `terminal/text.test.ts` 8 of 8, `terminal/markdown.test.ts` 26
  of 26, `protocol/frames.test.ts` 32 of 32 -- the same sets as native.
  The frame tests needed `JSON.parse<T>` to refuse an undeclared or a
  missing field on Node as it does natively; the emitter now hands the
  runtime T's shape.)
- **SC-003**: no string helper call is emitted for `+`, `==`, `length`,
  `[i]`, `slice`, `indexOf` (inspect emitted JS for the corpus; a test
  greps for `__lang.` in the output of `examples/valid/hot_path.ts` and
  expects none).
